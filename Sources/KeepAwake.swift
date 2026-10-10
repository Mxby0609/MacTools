import AppKit
import os

private let log = Log.keepAwake

/// 保持运行：合上盖子，或者开着盖子但一段时间无人操作时，不让电脑睡眠，并调暗屏幕。
/// 两种情况各有开关，共用电池设置。什么时候调暗由这里决定，怎么调暗见 Dimmer。
final class KeepAwake {
    private enum Key {
        static let lidEnabled = "keepAwake.lidEnabled"
        static let idleEnabled = "keepAwake.idleEnabled"
        static let idleSeconds = "keepAwake.idleSeconds"
        static let lowersVolume = "keepAwake.lowersVolume"
        static let pausesPlayback = "keepAwake.pausesPlayback"
        static let fadesGradually = "keepAwake.fadesGradually"
        static let allowOnBattery = "keepAwake.allowOnBattery"
        static let batteryThreshold = "keepAwake.batteryThreshold"
    }

    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private let powerMonitor = PowerMonitor()
    private let idle = IdleMonitor()
    private let displaySleepBlocker = DisplaySleepBlocker()
    private lazy var dimmer = Dimmer(lid: lid)
    private var power = PowerState.current()
    private var appliedSleepDisabled: Bool?
    private(set) var lastError: String?

    init() {
        defaults.register(defaults: [Key.batteryThreshold: 30, Key.idleSeconds: 300, Key.fadesGradually: true,
                                     Key.pausesPlayback: true])
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

    /// 调暗时是否把音量也调到 0。合盖和无人操作两种调暗都适用。
    var lowersVolume: Bool {
        get { defaults.bool(forKey: Key.lowersVolume) }
        set { defaults.set(newValue, forKey: Key.lowersVolume) }
    }

    /// 音量调到最低后是否暂停正在播放的内容。只在 lowersVolume 打开时生效，恢复时不会自动继续播放。
    var pausesPlayback: Bool {
        get { defaults.bool(forKey: Key.pausesPlayback) }
        set { defaults.set(newValue, forKey: Key.pausesPlayback) }
    }

    /// 是否逐渐调暗和恢复。合盖和无人操作两种情况都适用。
    var fadesGradually: Bool {
        get { defaults.bool(forKey: Key.fadesGradually) }
        set { defaults.set(newValue, forKey: Key.fadesGradually) }
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
        dimmer.onError = { [weak self] in self?.report($0) }
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
            dimmer.restore(gradually: false)
            return
        }
        restoreSystemState()
    }

    /// 固定设回允许睡眠，不恢复开启前的值：那个值可能是别的软件临时设的禁止睡眠。
    private func restoreSystemState() {
        dimmer.restore(gradually: false)
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
            dimmer.dim(
                gradually: fadesGradually,
                lowersVolume: lowersVolume,
                pausesPlayback: lowersVolume && pausesPlayback
            )
        } else if !closed {
            dimmer.restore(gradually: fadesGradually)
        }
    }

    private func report(_ message: String) {
        lastError = message
        log.error("\(message)")
        onChange?()
    }
}
