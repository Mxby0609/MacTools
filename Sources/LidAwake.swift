import AppKit
import os

private let log = Log.lidAwake

/// 合盖运行：根据总开关、电源和合盖状态，决定是否禁止睡眠，以及是否把屏幕亮度和键盘背光调到 0。
final class LidAwake {
    private enum Key {
        static let enabled = "lidAwake.enabled"
        static let allowOnBattery = "lidAwake.allowOnBattery"
        static let batteryThreshold = "lidAwake.batteryThreshold"
    }

    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private let powerMonitor = PowerMonitor()
    private let keyboard = KeyboardBacklight()
    private var power = PowerState.current()
    private var appliedSleepDisabled: Bool?
    private var isDimmed = false
    /// 调暗前的屏幕亮度，一直保留到恢复成功。开盖后内置屏还没上线就又合盖时，
    /// 读到的亮度已经是 0，所以不能重新读取。
    private var savedBrightness: Float?
    private var savedKeyboard: KeyboardBacklight.Snapshot?
    private(set) var lastError: String?

    init() {
        defaults.register(defaults: [Key.batteryThreshold: 30])
    }

    var enabled: Bool { defaults.bool(forKey: Key.enabled) }

    var allowOnBattery: Bool {
        get { defaults.bool(forKey: Key.allowOnBattery) }
        set { defaults.set(newValue, forKey: Key.allowOnBattery); reconcile() }
    }

    var batteryThreshold: Int {
        get { defaults.integer(forKey: Key.batteryThreshold) }
        set { defaults.set(newValue, forKey: Key.batteryThreshold); reconcile() }
    }

    private var keepsAwake: Bool {
        guard enabled else { return false }
        if power.onAC { return true }
        return allowOnBattery && (power.batteryPercent ?? 0) >= batteryThreshold
    }

    var statusText: String {
        if let lastError { return "出错：\(lastError)" }
        guard enabled else { return "已关闭" }
        let source = power.onAC ? "插电中" : "电池 \(power.batteryPercent ?? 0)%"
        return keepsAwake ? "\(source)，合盖继续运行" : "\(source)，合盖会睡眠"
    }

    func start() {
        lid.start { [weak self] in self?.reconcile() }
        powerMonitor.start { [weak self] in self?.refreshPower() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPower()
        }
        reconcile()
    }

    private func refreshPower() {
        power = PowerState.current()
        reconcile()
    }

    func setEnabled(_ on: Bool) throws {
        if on {
            if !SleepSetting.isAuthorized {
                // 在密码框点取消不算出错，开关保持关闭。
                do { try SleepSetting.authorize() } catch is SleepSetting.AuthorizationCancelled { return }
            }
            defaults.set(true, forKey: Key.enabled)
            reconcile()
        } else {
            defaults.set(false, forKey: Key.enabled)
            restoreSystemState()
        }
    }

    /// 软件退出时调用：允许系统睡眠，但保留总开关，下次启动继续生效。
    func shutdown() {
        guard enabled else { return }
        restoreSystemState()
    }

    /// 固定设回允许睡眠，不恢复开启前的值：那个值可能是别的软件临时设的禁止睡眠。
    private func restoreSystemState() {
        restoreLights()
        defer { onChange?() }
        do {
            try SleepSetting.setDisabled(false)
            appliedSleepDisabled = nil
            lastError = nil
        } catch {
            report(error.localizedDescription)
        }
    }

    private func reconcile() {
        defer { onChange?() }
        let closed = lid.isClosed
        // 放在总开关判断之前：盖子合着时关掉功能，屏幕亮度可能没恢复成，开盖后在这里补上。
        if !closed { restoreLights() }
        guard enabled else { return }
        let keep = keepsAwake
        do {
            if appliedSleepDisabled != keep {
                try SleepSetting.setDisabled(keep)
                appliedSleepDisabled = keep
            }
            lastError = nil
            if closed && keep {
                dimLights()
            } else if closed {
                // 合盖期间电量跌破阈值或拔掉电源：系统不会因为设置改变而自动睡，需要主动让它睡。
                try SleepSetting.sleepNow()
            }
        } catch {
            report(error.localizedDescription)
        }
    }

    /// 只调亮度，不让屏幕熄灭：熄屏会触发锁屏，远程桌面也会看到锁屏界面。
    private func dimLights() {
        guard !isDimmed else { return }
        isDimmed = true
        if savedBrightness == nil {
            if let brightness = DisplayBrightness.get(), DisplayBrightness.set(0) {
                savedBrightness = brightness
            } else {
                log.error("合盖：调低屏幕亮度失败")
            }
        }
        if let keyboard {
            savedKeyboard = keyboard.snapshot()
            keyboard.apply(.init(brightness: 0, autoBrightness: false))
        }
        log.notice("合盖：屏幕亮度和键盘背光已调到 0")
    }

    private func restoreLights() {
        guard isDimmed || savedBrightness != nil else { return }
        isDimmed = false
        if let snapshot = savedKeyboard {
            keyboard?.apply(snapshot)
            savedKeyboard = nil
        }
        restoreDisplay(attemptsLeft: 10)
        log.notice("开盖：已恢复屏幕和键盘背光")
    }

    /// 开盖后内置屏要过一会儿才重新上线，所以每 0.5 秒重试一次。
    private func restoreDisplay(attemptsLeft: Int) {
        guard let brightness = savedBrightness else { return }
        if DisplayBrightness.set(brightness) {
            savedBrightness = nil
            return
        }
        guard attemptsLeft > 0 else {
            report("恢复屏幕亮度失败：内置屏一直未就绪")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isDimmed, !self.lid.isClosed else { return }
            self.restoreDisplay(attemptsLeft: attemptsLeft - 1)
        }
    }

    private func report(_ message: String) {
        lastError = message
        log.error("\(message)")
        onChange?()
    }
}
