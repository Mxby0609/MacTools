import AppKit
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

private let log = Log.keepAwake

// MARK: - 合盖状态

/// iokit_family_msg(sub_iokit_powermanagement, 0x100)，即 IOPM.h 里的 kIOPMMessageClamshellStateChange；Swift 不导入这个宏。
private let clamshellStateChangeMessage: UInt32 = 0xE003_4100

final class LidMonitor {
    private let rootDomain: io_service_t
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var onChange: (() -> Void)?

    init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        precondition(rootDomain != 0, "找不到 IOPMrootDomain")
    }

    var isClosed: Bool {
        let value = IORegistryEntryCreateCFProperty(
            rootDomain,
            kAppleClamshellStateKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { context, _, messageType, _ in
                guard messageType == clamshellStateChangeMessage, let context else { return }
                let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
                log.notice("合盖状态变化：closed=\(monitor.isClosed)")
                monitor.onChange?()
            },
            context,
            &notifier
        )
        if result != KERN_SUCCESS {
            log.error("注册合盖通知失败：\(result)")
        }
    }
}

// MARK: - 电源

struct PowerState {
    let onAC: Bool
    let batteryPercent: Int?

    static func current() -> PowerState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        var percent: Int?
        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            percent = current * 100 / max
        }
        return PowerState(onAC: source == kIOPMACPowerKey, batteryPercent: percent)
    }
}

final class PowerMonitor {
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else {
            log.error("注册电源通知失败")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}

// MARK: - 无人操作

/// 无人操作检测：定时查看距离上次键盘、鼠标操作过了多久，“有人操作”和“无人操作”互相切换时发出通知。
final class IdleMonitor {
    /// CGEventTypes.h 里的 kCGAnyInputEventType，表示任意输入事件；Swift 不导入这个宏。
    private static let anyInputEvent = CGEventType(rawValue: ~0)!

    var onChange: (() -> Void)?
    private(set) var isIdle = false
    private var threshold: TimeInterval?
    private var watchStart = Date()
    private var timer: Timer?

    /// 开始检测，传 nil 则停止。传入的时长和正在用的相同时什么都不做，可以反复调用。
    func watch(threshold: TimeInterval?) {
        guard threshold != self.threshold else { return }
        self.threshold = threshold
        timer?.invalidate()
        timer = nil
        isIdle = false
        guard let threshold else { return }
        watchStart = Date()
        schedule(after: threshold)
    }

    private func schedule(after delay: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.check() }
    }

    private func check() {
        guard let threshold else { return }
        // 远程桌面发来的操作也算，所以用 combinedSessionState。
        let sinceInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEvent)
        let quiet = min(sinceInput, Date().timeIntervalSince(watchStart))
        // 别的软件要求屏幕保持点亮时（放视频、开视频会议）不进入无人操作状态，免得看到一半屏幕变黑。
        let idleNow = quiet >= threshold && (isIdle || !DisplaySleepBlocker.heldByOthers)

        // 无人操作期间每 0.25 秒看一次，有操作就能马上恢复；其余时间等到可能满足条件的时刻再看。
        if idleNow {
            schedule(after: 0.25)
        } else {
            schedule(after: quiet < threshold ? threshold - quiet : 5)
        }
        // 先安排好下一次再通知：收到通知的一方可能会调用 watch 停止检测。
        if idleNow != isIdle {
            isIdle = idleNow
            log.notice("无人操作状态变化：idle=\(idleNow)")
            onChange?()
        }
    }
}

// MARK: - 防止熄屏

/// 向系统声明“无人操作时不要熄屏、不要睡眠”，效果和 `caffeinate -d` 相同。软件退出时系统会自动撤销。
final class DisplaySleepBlocker {
    private var assertion: IOPMAssertionID?

    func setActive(_ active: Bool) {
        if active, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "无人操作时保持运行" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertion = id
            } else {
                log.error("声明防止熄屏失败：\(result)")
            }
        } else if !active, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }

    /// 别的软件是否正要求屏幕保持点亮。
    static var heldByOthers: Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        let displayTypes = [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypeNoDisplaySleep]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return byProcess.contains { pid, assertions in
            pid.int32Value != ownPID && assertions.contains {
                displayTypes.contains($0[kIOPMAssertionTypeKey] as? String ?? "")
            }
        }
    }
}

// MARK: - 屏幕亮度（私有框架 DisplayServices）

enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW
    )
    private static let getFunction = dlsym(handle, "DisplayServicesGetBrightness")
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setFunction = dlsym(handle, "DisplayServicesSetBrightness")
        .map { unsafeBitCast($0, to: SetFunction.self) }

    /// 合盖后内置屏可能已经下线，此时返回 nil。
    private static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let getFunction, let display = builtinDisplay() else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) -> Bool {
        guard let setFunction, let display = builtinDisplay() else { return false }
        return setFunction(display, value) == 0
    }
}

// MARK: - 键盘背光（私有框架 CoreBrightness）

final class KeyboardBacklight {
    struct Snapshot {
        let brightness: Float
        let autoBrightness: Bool
    }

    private typealias GetBrightness = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetBrightness = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias GetAuto = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetAuto = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private let client: NSObject
    private let keyboardID: UInt64

    init?() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            log.error("找不到 KeyboardBrightnessClient")
            return nil
        }
        let client = type.init()
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let ids = client.perform(selector)?.takeRetainedValue() as? [NSNumber],
              let first = ids.first
        else {
            log.error("读取键盘背光编号失败")
            return nil
        }
        self.client = client
        keyboardID = first.uint64Value
    }

    func snapshot() -> Snapshot {
        let brightnessSel = NSSelectorFromString("brightnessForKeyboard:")
        let autoSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        let getBrightness = unsafeBitCast(client.method(for: brightnessSel), to: GetBrightness.self)
        let getAuto = unsafeBitCast(client.method(for: autoSel), to: GetAuto.self)
        return Snapshot(brightness: getBrightness(client, brightnessSel, keyboardID),
                        autoBrightness: getAuto(client, autoSel, keyboardID))
    }

    func apply(_ snapshot: Snapshot) {
        let brightnessSel = NSSelectorFromString("setBrightness:forKeyboard:")
        let autoSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        let setBrightness = unsafeBitCast(client.method(for: brightnessSel), to: SetBrightness.self)
        let setAuto = unsafeBitCast(client.method(for: autoSel), to: SetAuto.self)
        // 先关自动调节再设亮度，否则关灯后会被自动调节重新点亮；恢复时顺序相反。
        if !snapshot.autoBrightness {
            _ = setAuto(client, autoSel, false, keyboardID)
        }
        if !setBrightness(client, brightnessSel, snapshot.brightness, keyboardID) {
            log.error("设置键盘背光失败")
        }
        if snapshot.autoBrightness {
            _ = setAuto(client, autoSel, true, keyboardID)
        }
    }
}
