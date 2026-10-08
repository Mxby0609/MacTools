import AppKit

/// 根据总开关、电源和合盖状态，决定是否禁止睡眠，以及是否把屏幕亮度和键盘背光调到 0。
final class Controller {
    private enum Key {
        static let enabled = "enabled"
        static let allowOnBattery = "allowOnBattery"
        static let batteryThreshold = "batteryThreshold"
        /// 打开总开关前系统的 disablesleep 值。总开关关闭或软件退出时恢复它；
        /// 软件异常退出时它留在磁盘上，下次启动继续沿用，不会把自己设过的值误当成原值。
        static let originalSleepDisabled = "originalSleepDisabled"
    }

    private struct DimmedLights {
        var displayBrightness: Float?
        var keyboard: KeyboardBacklight.Snapshot?
    }

    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private let powerMonitor = PowerMonitor()
    private let keyboard = KeyboardBacklight()
    private var power = PowerState.current()
    private var appliedSleepDisabled: Bool?
    private var dimmed: DimmedLights?
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

    private var originalSleepDisabled: Bool? {
        get { defaults.object(forKey: Key.originalSleepDisabled) as? Bool }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.originalSleepDisabled) }
            else { defaults.removeObject(forKey: Key.originalSleepDisabled) }
        }
    }

    var keepsAwake: Bool {
        guard enabled else { return false }
        if power.onAC { return true }
        return allowOnBattery && (power.batteryPercent ?? 0) >= batteryThreshold
    }

    var statusText: String {
        if let lastError { return "出错：\(lastError)" }
        guard enabled else { return "已关闭，合盖按系统原设置" }
        let source = power.onAC ? "插电中" : "电池 \(power.batteryPercent ?? 0)%"
        return keepsAwake ? "\(source)，合盖继续运行" : "\(source)，合盖会睡眠"
    }

    func start() {
        lid.start { [weak self] in self?.reconcile() }
        powerMonitor.start { [weak self] in
            self?.power = PowerState.current()
            self?.reconcile()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.power = PowerState.current()
            self?.reconcile()
        }
        if enabled { activate() }
    }

    func setEnabled(_ on: Bool) throws {
        if on {
            if !SleepSetting.isAuthorized { try SleepSetting.authorize() }
            defaults.set(true, forKey: Key.enabled)
            activate()
        } else {
            defaults.set(false, forKey: Key.enabled)
            restoreSystemState()
        }
    }

    /// 软件退出时调用：恢复系统原设置，但保留总开关，下次启动继续生效。
    func shutdown() {
        guard enabled else { return }
        restoreSystemState()
    }

    private func activate() {
        do {
            if originalSleepDisabled == nil {
                originalSleepDisabled = try SleepSetting.readDisabled()
            }
            appliedSleepDisabled = nil
            reconcile()
        } catch {
            report(error)
        }
    }

    private func restoreSystemState() {
        restoreLights()
        defer { onChange?() }
        guard let original = originalSleepDisabled else { return }
        do {
            try SleepSetting.setDisabled(original)
            originalSleepDisabled = nil
            appliedSleepDisabled = nil
            lastError = nil
        } catch {
            report(error)
        }
    }

    private func reconcile() {
        defer { onChange?() }
        guard enabled else { return }
        let keep = keepsAwake
        do {
            if appliedSleepDisabled != keep {
                try SleepSetting.setDisabled(keep)
                appliedSleepDisabled = keep
            }
            lastError = nil
        } catch {
            report(error)
            return
        }
        guard lid.isClosed else {
            restoreLights()
            return
        }
        if keep {
            dimLights()
        } else {
            // 合盖期间电量跌破阈值或拔掉电源：系统不会因为设置改变而自动睡，需要主动让它睡。
            do { try SleepSetting.sleepNow() } catch { report(error) }
        }
    }

    /// 只调亮度，不让屏幕熄灭：熄屏会触发锁屏，远程桌面也会看到锁屏界面。
    private func dimLights() {
        guard dimmed == nil else { return }
        var lights = DimmedLights()
        if let brightness = DisplayBrightness.get(), DisplayBrightness.set(0) {
            lights.displayBrightness = brightness
        } else {
            log.error("合盖：调低屏幕亮度失败")
        }
        if let keyboard {
            let snapshot = keyboard.snapshot()
            keyboard.apply(.init(brightness: 0, autoBrightness: false))
            lights.keyboard = snapshot
        }
        dimmed = lights
        log.notice("合盖：屏幕亮度和键盘背光已调到 0")
    }

    private func restoreLights() {
        guard let lights = dimmed else { return }
        dimmed = nil
        if let snapshot = lights.keyboard { keyboard?.apply(snapshot) }
        if let brightness = lights.displayBrightness { restoreDisplay(brightness, attemptsLeft: 10) }
        log.notice("开盖：已恢复屏幕和键盘背光")
    }

    /// 开盖后内置屏要过一会儿才重新上线，所以每 0.5 秒重试一次。
    private func restoreDisplay(_ brightness: Float, attemptsLeft: Int) {
        if DisplayBrightness.set(brightness) { return }
        guard attemptsLeft > 0 else {
            report(CommandError(command: "恢复屏幕亮度", status: -1, output: "内置屏一直未就绪"))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.dimmed == nil, !self.lid.isClosed else { return }
            self.restoreDisplay(brightness, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        log.error("\(error.localizedDescription)")
        onChange?()
    }
}
