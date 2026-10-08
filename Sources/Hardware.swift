import AppKit
import CoreGraphics
import IOKit
import IOKit.ps
import os

let log = Logger(subsystem: "local.mxby.lidawake", category: "main")

struct CommandError: LocalizedError {
    let command: String
    let status: Int32
    let output: String

    var errorDescription: String? {
        "\(command) 退出码 \(status)：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

@discardableResult
func runCommand(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw CommandError(command: ([path] + arguments).joined(separator: " "),
                           status: process.terminationStatus, output: output)
    }
    return output
}

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
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { context, _, messageType, _ in
            guard messageType == clamshellStateChangeMessage, let context else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
            log.notice("合盖状态变化：closed=\(monitor.isClosed)")
            monitor.onChange?()
        }, context, &notifier)
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

// MARK: - 屏幕亮度（私有框架 DisplayServices）

enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFunction = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setFunction = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFunction.self) }

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
        guard let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              let first = ids.first else {
            log.error("读取键盘背光编号失败")
            return nil
        }
        self.client = client
        self.keyboardID = first.uint64Value
    }

    func snapshot() -> Snapshot {
        let getSel = NSSelectorFromString("brightnessForKeyboard:")
        let autoSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        let brightness = unsafeBitCast(client.method(for: getSel), to: GetBrightness.self)(client, getSel, keyboardID)
        let auto = unsafeBitCast(client.method(for: autoSel), to: GetAuto.self)(client, autoSel, keyboardID)
        return Snapshot(brightness: brightness, autoBrightness: auto)
    }

    func apply(_ snapshot: Snapshot) {
        let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
        let autoSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        // 先关自动调节再设亮度，否则关灯后会被自动调节重新点亮；恢复时顺序相反。
        if !snapshot.autoBrightness {
            _ = unsafeBitCast(client.method(for: autoSel), to: SetAuto.self)(client, autoSel, false, keyboardID)
        }
        if !unsafeBitCast(client.method(for: setSel), to: SetBrightness.self)(client, setSel, snapshot.brightness, keyboardID) {
            log.error("设置键盘背光失败")
        }
        if snapshot.autoBrightness {
            _ = unsafeBitCast(client.method(for: autoSel), to: SetAuto.self)(client, autoSel, true, keyboardID)
        }
    }
}
