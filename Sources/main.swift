import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private let windowCentering = WindowCentering()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.updateIcon() }
        controller.start()
        updateIcon()
        do {
            try windowCentering.start()
        } catch {
            showAlert("无法开启窗口居中", error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func updateIcon() {
        let name = controller.lastError != nil ? "exclamationmark.triangle"
            : controller.enabled ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "合盖运行")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item("合盖继续运行", #selector(toggleEnabled), checked: controller.enabled))
        menu.addItem(item("用电池时也运行", #selector(toggleBattery), checked: controller.allowOnBattery))

        let threshold = NSMenuItem(title: "电量低于 \(controller.batteryThreshold)% 时允许睡眠", action: nil, keyEquivalent: "")
        threshold.isEnabled = controller.allowOnBattery
        let submenu = NSMenu()
        for percent in [10, 20, 30, 40, 50] {
            let option = item("\(percent)%", #selector(setThreshold(_:)), checked: percent == controller.batteryThreshold)
            option.tag = percent
            submenu.addItem(option)
        }
        threshold.submenu = submenu
        menu.addItem(threshold)
        menu.addItem(.separator())

        menu.addItem(item("按 ⌃⌥C 居中当前窗口", #selector(toggleWindowCentering), checked: windowCentering.enabled))
        if windowCentering.needsPermission {
            menu.addItem(item("授权辅助功能…", #selector(openAccessibilitySettings), checked: false))
        }
        menu.addItem(.separator())

        menu.addItem(item("开机自动启动", #selector(toggleLaunchAtLogin), checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggleEnabled() {
        do {
            try controller.setEnabled(!controller.enabled)
        } catch is SleepSetting.AuthorizationCancelled {
            return
        } catch {
            showAlert("无法开启合盖运行", error)
        }
    }

    @objc private func toggleBattery() {
        controller.allowOnBattery.toggle()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        controller.batteryThreshold = sender.tag
    }

    @objc private func toggleWindowCentering() {
        do {
            try windowCentering.setEnabled(!windowCentering.enabled)
        } catch {
            showAlert("无法开启窗口居中", error)
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
