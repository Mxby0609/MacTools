import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let windowCentering = WindowCentering()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        keepAwake.onChange = { [weak self] in self?.updateIcon() }
        keepAwake.start()
        updateIcon()
        windowCentering.start()
    }

    func applicationWillTerminate(_: Notification) {
        keepAwake.shutdown()
    }

    private func updateIcon() {
        let name = keepAwake.lastError != nil ? "exclamationmark.triangle"
            : keepAwake.enabled ? "cup.and.saucer.fill" : "cup.and.saucer"
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let image = NSImage(systemSymbolName: name, accessibilityDescription: appName)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(note(keepAwake.statusText))
        menu.addItem(.separator())

        menu.addItem(item("合盖继续运行", #selector(toggleLid), checked: keepAwake.lidEnabled))
        menu.addItem(item("无人操作时调暗并继续运行", #selector(toggleIdle), checked: keepAwake.idleEnabled))
        menu.addItem(choices(
            "无人操作 \(durationText(keepAwake.idleSeconds))后调暗",
            enabled: keepAwake.idleEnabled,
            options: [5, 60, 120, 300, 600, 1800].map { ($0 == 5 ? "5 秒（测试用）" : durationText($0), $0) },
            selected: keepAwake.idleSeconds,
            #selector(setIdleSeconds(_:))
        ))
        menu.addItem(item("用电池时也运行", #selector(toggleBattery), checked: keepAwake.allowOnBattery))
        menu.addItem(choices(
            "电量低于 \(keepAwake.batteryThreshold)% 时允许睡眠",
            enabled: keepAwake.allowOnBattery,
            options: [10, 20, 30, 40, 50].map { ("\($0)%", $0) },
            selected: keepAwake.batteryThreshold,
            #selector(setThreshold(_:))
        ))
        menu.addItem(.separator())

        menu.addItem(item(
            windowCentering.menuTitle,
            #selector(toggleWindowCentering),
            checked: windowCentering.enabled
        ))
        if let error = windowCentering.lastError {
            menu.addItem(note("出错：\(error)"))
        }
        if windowCentering.needsPermission {
            menu.addItem(item("授权辅助功能…", #selector(openAccessibilitySettings), checked: false))
        }
        menu.addItem(.separator())

        menu.addItem(item("开机自动启动", #selector(toggleLaunchAtLogin), checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 只用来显示文字、不能点击的一行。
    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    /// 带子菜单的一行，子菜单是一组单选项，各项的数值放在 tag 里。
    private func choices(
        _ title: String,
        enabled: Bool,
        options: [(title: String, value: Int)],
        selected: Int,
        _ action: Selector
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = enabled
        let submenu = NSMenu()
        for option in options {
            let child = item(option.title, action, checked: option.value == selected)
            child.tag = option.value
            submenu.addItem(child)
        }
        parent.submenu = submenu
        return parent
    }

    private func durationText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
    }

    @objc private func toggleLid() {
        do {
            try keepAwake.setLidEnabled(!keepAwake.lidEnabled)
        } catch {
            showAlert("无法开启合盖运行", error)
        }
    }

    @objc private func toggleIdle() {
        keepAwake.idleEnabled.toggle()
    }

    @objc private func setIdleSeconds(_ sender: NSMenuItem) {
        keepAwake.idleSeconds = sender.tag
    }

    @objc private func toggleBattery() {
        keepAwake.allowOnBattery.toggle()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        keepAwake.batteryThreshold = sender.tag
    }

    @objc private func toggleWindowCentering() {
        do {
            try windowCentering.setEnabled(!windowCentering.enabled)
        } catch {
            showAlert("无法开启窗口居中", error)
        }
    }

    @objc private func openAccessibilitySettings() {
        windowCentering.openPermissionSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert("无法修改开机启动", error)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func showAlert(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
