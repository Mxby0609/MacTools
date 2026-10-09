import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let log = Log.windowCentering

/// 窗口居中：按 ⌃⌥C 把当前窗口移到所在屏幕可用区域的正中，不改变窗口大小。
final class WindowCentering {
    private enum CenterError: LocalizedError {
        case noWindow
        case fullScreen
        case notMoved

        var errorDescription: String? {
            switch self {
            case .noWindow: "前台软件没有可移动的窗口"
            case .fullScreen: "窗口处于全屏状态"
            case .notMoved: "窗口没有按要求移动"
            }
        }
    }

    private static let enabledKey = "windowCentering.enabled"

    /// 菜单里的标题。其中的快捷键要和 register() 里注册的保持一致。
    let menuTitle = "按 ⌃⌥C 居中当前窗口"

    private let defaults = UserDefaults.standard
    private var hotKey: HotKey?
    /// 启动时注册快捷键失败的原因。此时开关仍是打开的，菜单靠它提示功能没有生效。
    private(set) var lastError: String?

    var enabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// 移动其他软件的窗口必须有辅助功能权限。重新编译安装后签名改变，系统会把之前的授权作废。
    var needsPermission: Bool {
        enabled && !AXIsProcessTrusted()
    }

    func start() {
        guard enabled else { return }
        do {
            try register()
        } catch {
            lastError = error.localizedDescription
            log.error("\(error.localizedDescription)")
        }
    }

    func setEnabled(_ on: Bool) throws {
        if on {
            try register()
            requestPermission()
        } else {
            hotKey = nil
        }
        lastError = nil
        defaults.set(on, forKey: Self.enabledKey)
    }

    func openPermissionSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    private func register() throws {
        hotKey = try HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in
            self?.handleHotKey()
        }
    }

    private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func handleHotKey() {
        guard AXIsProcessTrusted() else {
            requestPermission()
            return
        }
        do {
            try Self.moveFrontWindowToCenter()
        } catch {
            log.error("居中失败：\(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private static func moveFrontWindowToCenter() throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw CenterError.noWindow }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // 前台软件卡死时，默认要等 6 秒才返回。
        AXUIElementSetMessagingTimeout(appElement, 1)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else {
            throw CenterError.noWindow
        }
        let window = windowRef as! AXUIElement

        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           fullScreen as? Bool == true {
            throw CenterError.fullScreen
        }

        guard let origin = position(of: window), let size = size(of: window) else {
            throw CenterError.noWindow
        }
        var target = try centeredOrigin(for: CGRect(origin: origin, size: size))
        guard let targetValue = AXValueCreate(.cgPoint, &target) else { throw CenterError.notMoved }

        // 全屏、被软件自己固定位置的窗口会返回成功却不移动，所以读回位置核实。
        guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, targetValue) == .success,
              let moved = position(of: window),
              abs(moved.x - target.x) <= 1, abs(moved.y - target.y) <= 1
        else {
            throw CenterError.notMoved
        }
    }

    /// 辅助功能接口的坐标原点在主屏左上角，NSScreen 的原点在主屏左下角，这里统一换算成前者。
    private static func centeredOrigin(for window: CGRect) throws -> CGPoint {
        let screens = NSScreen.screens
        guard let primary = screens.first else { throw CenterError.noWindow }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = flipped(screen.frame).intersection(window)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = screens.max { overlap($0) < overlap($1) } ?? primary
        // 可用区域不含菜单栏和程序坞，和系统自带的“窗口 > 居中”基准相同。
        let visible = flipped(screen.visibleFrame)
        let x = (visible.midX - window.width / 2).rounded()
        let y = (visible.midY - window.height / 2).rounded()
        // 窗口比可用区域还高时贴住顶边，标题栏才不会被菜单栏挡住。
        return CGPoint(x: x, y: max(visible.minY, y))
    }

    private static func position(of window: AXUIElement) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(of: window, kAXPositionAttribute),
              AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of window: AXUIElement) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(of: window, kAXSizeAttribute),
              AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(of element: AXUIElement, _ attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }
}

/// Carbon 的全局快捷键，注册不需要任何权限。整个软件只注册这一个，所以回调不核对快捷键编号。
private final class HotKey {
    struct RegistrationFailed: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "注册快捷键失败（错误码 \(status)），可能已被其他软件占用"
        }
    }

    private let action: () -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        var status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, context, &handlerRef)
        guard status == noErr else { throw RegistrationFailed(status: status) }

        let id = EventHotKeyID(signature: OSType(0x4D41_4354), id: 1) // "MACT"
        status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { throw RegistrationFailed(status: status) }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
