import AppKit
import os

private let log = Log.keepAwake

/// 保持运行：合上盖子，或者开着盖子但一段时间无人操作时，不让电脑睡眠，并把屏幕亮度和键盘背光调到 0。
/// 两种情况各有开关，共用电池设置。
final class KeepAwake {
    private enum Key {
        static let lidEnabled = "keepAwake.lidEnabled"
        static let idleEnabled = "keepAwake.idleEnabled"
        static let idleSeconds = "keepAwake.idleSeconds"
        static let allowOnBattery = "keepAwake.allowOnBattery"
        static let batteryThreshold = "keepAwake.batteryThreshold"
    }

    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private let powerMonitor = PowerMonitor()
    private let idle = IdleMonitor()
    private let displaySleepBlocker = DisplaySleepBlocker()
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
        defaults.register(defaults: [Key.batteryThreshold: 30, Key.idleSeconds: 300])
    }

    var lidEnabled: Bool {
        defaults.bool(forKey: Key.lidEnabled)
    }

    var idleEnabled: Bool {
        get { defaults.bool(forKey: Key.idleEnabled) }
        set { defaults.set(newValue, forKey: Key.idleEnabled); reconcile() }
    }

    /// 无人操作多少秒后调暗。
    var idleSeconds: Int {
        get { defaults.integer(forKey: Key.idleSeconds) }
        set { defaults.set(newValue, forKey: Key.idleSeconds); reconcile() }
    }

    var allowOnBattery: Bool {
        get { defaults.bool(forKey: Key.allowOnBattery) }
        set { defaults.set(newValue, forKey: Key.allowOnBattery); reconcile() }
    }

    var batteryThreshold: Int {
        get { defaults.integer(forKey: Key.batteryThreshold) }
        set { defaults.set(newValue, forKey: Key.batteryThreshold); reconcile() }
    }

    var enabled: Bool {
        lidEnabled || idleEnabled
    }

    /// 当前电源条件下是否保持运行：插电时总是，用电池时看设置和电量。
    private var powerAllows: Bool {
        power.onAC || (allowOnBattery && (power.batteryPercent ?? 0) >= batteryThreshold)
    }

    var statusText: String {
        if let lastError {
            return "出错：\(lastError)"
        }
        guard enabled else { return "已关闭" }
        let source = power.onAC ? "插电中" : "电池 \(power.batteryPercent ?? 0)%"
        return powerAllows ? "\(source)，保持运行" : "\(source)，允许睡眠"
    }

    func start() {
        lid.start { [weak self] in self?.reconcile() }
        powerMonitor.start { [weak self] in self?.refreshPower() }
        idle.onChange = { [weak self] in self?.reconcile() }
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

    func setLidEnabled(_ on: Bool) throws {
        if on {
            if !SleepSetting.isAuthorized {
                // 在密码框点取消不算出错，开关保持关闭。
                do { try SleepSetting.authorize() } catch is SleepSetting.AuthorizationCancelled { return }
            }
            defaults.set(true, forKey: Key.lidEnabled)
            reconcile()
        } else {
            defaults.set(false, forKey: Key.lidEnabled)
            restoreSystemState()
        }
    }

    /// 软件退出时调用：允许系统睡眠，但保留两个开关，下次启动继续生效。
    func shutdown() {
        guard lidEnabled else {
            restoreLights()
            return
        }
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
        let allowed = powerAllows

        displaySleepBlocker.setActive(idleEnabled && allowed)
        // 合着盖子时不看有没有人操作。开盖后重新开始计时，所以开盖本身也算一次操作。
        idle.watch(threshold: idleEnabled && allowed && !closed ? TimeInterval(idleSeconds) : nil)
        var dim = idle.isIdle

        if lidEnabled {
            do {
                if appliedSleepDisabled != allowed {
                    try SleepSetting.setDisabled(allowed)
                    appliedSleepDisabled = allowed
                }
                lastError = nil
                if closed, allowed {
                    dim = true
                } else if closed {
                    // 合盖期间电量跌破阈值或拔掉电源：系统不会因为设置改变而自动睡，需要主动让它睡。
                    try SleepSetting.sleepNow()
                }
            } catch {
                report(error.localizedDescription)
            }
        }

        // 盖子合着时不恢复：这时内置屏不在线，恢复不了，等开盖后再走到这里。
        if dim {
            dimLights()
        } else if !closed {
            restoreLights()
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
                log.error("调低屏幕亮度失败")
            }
        }
        if let keyboard {
            savedKeyboard = keyboard.snapshot()
            keyboard.apply(.init(brightness: 0, autoBrightness: false))
        }
        log.notice("屏幕亮度和键盘背光已调到 0")
    }

    private func restoreLights() {
        guard isDimmed || savedBrightness != nil else { return }
        isDimmed = false
        if let snapshot = savedKeyboard {
            keyboard?.apply(snapshot)
            savedKeyboard = nil
        }
        restoreDisplay(attemptsLeft: 10)
        log.notice("已恢复屏幕和键盘背光")
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
            restoreDisplay(attemptsLeft: attemptsLeft - 1)
        }
    }

    private func report(_ message: String) {
        lastError = message
        log.error("\(message)")
        onChange?()
    }
}
