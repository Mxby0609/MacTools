import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let lidAwake = LidAwake()
    private let windowCentering = WindowCentering()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        lidAwake.onChange = { [weak self] in self?.updateIcon() }
        lidAwake.start()
        updateIcon()
        windowCentering.start()
    }

    func applicationWillTerminate(_: Notification) {
        lidAwake.shutdown()
    }

    private func updateIcon() {
        let name = lidAwake.lastError != nil ? "exclamationmark.triangle"
            : lidAwake.enabled ? "cup.and.saucer.fill" : "cup.and.saucer"
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let image = NSImage(systemSymbolName: name, accessibilityDescription: appName)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(note(lidAwake.statusText))
        menu.addItem(.separator())

        menu.addItem(item("合盖继续运行", #selector(toggleLidAwake), checked: lidAwake.enabled))
        menu.addItem(item("用电池时也运行", #selector(toggleBattery), checked: lidAwake.allowOnBattery))

        let threshold = NSMenuItem(title: "电量低于 \(lidAwake.batteryThreshold)% 时允许睡眠", action: nil, keyEquivalent: "")
        threshold.isEnabled = lidAwake.allowOnBattery
        let submenu = NSMenu()
        for percent in [10, 20, 30, 40, 50] {
            let option = item("\(percent)%", #selector(setThreshold(_:)), checked: percent == lidAwake.batteryThreshold)
            option.tag = percent
            submenu.addItem(option)
        }
        threshold.submenu = submenu
        menu.addItem(threshold)
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

    @objc private func toggleLidAwake() {
        do {
            try lidAwake.setEnabled(!lidAwake.enabled)
        } catch {
            showAlert("无法开启合盖运行", error)
        }
    }

    @objc private func toggleBattery() {
        lidAwake.allowOnBattery.toggle()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        lidAwake.batteryThreshold = sender.tag
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
