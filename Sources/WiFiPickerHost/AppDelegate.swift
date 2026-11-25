import AppKit
import Carbon
import MacWiFiPicker
import ServiceManagement
import os

private let log = Logger(subsystem: "io.github.ruodou233.MacWiFiPicker", category: "host")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private enum CloseCause {
        case user
        case automatic
    }

    private let controller = WiFiPickerController()
    private let launchedByFallbackAgent: Bool
    private var pickerViewController: WiFiPickerViewController!
    private var popover: NSPopover!
    private var statusItem: NSStatusItem!
    private var loginItemMessage: String?
    private var closeCause: CloseCause?
    private var isClosing = false
    private var showRequestedWhileClosing = false
    private var statusIndicator: WiFiStatusIndicator?

    init(launchedByFallbackAgent: Bool = false) {
        self.launchedByFallbackAgent = launchedByFallbackAgent
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPopover()
        buildStatusItem()
        configureLoginItem()

        controller.onLinkChange = { [weak self] link in
            guard let self else { return }
            self.updateStatusIcon(WiFiStatusIndicator.make(link: link))
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        controller.onVisibilityRequest = { [weak self] request in
            switch request {
            case .show: self?.showPicker()
            case .hide: self?.hidePicker()
            }
        }

        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = launchedByFallbackAgent
            || (event?.eventID == AEEventID(kAEOpenApplication)
                && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                    == OSType(keyAELaunchedAsLogInItem))
        controller.start(manuallyLaunched: !launchedAsLoginItem)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.presentManually()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func buildPopover() {
        pickerViewController = WiFiPickerViewController(controller: controller)
        pickerViewController.onRequestClose = { [weak self] in
            self?.hidePicker(userInitiated: true)
        }

        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = pickerViewController
        popover.delegate = self
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(symbolName: "wifi", variableValue: 0, description: "Wi‑Fi")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateStatusIcon(_ indicator: WiFiStatusIndicator) {
        guard indicator != statusIndicator, let button = statusItem.button else { return }
        statusIndicator = indicator
        button.image = Self.statusImage(
            symbolName: indicator.symbolName,
            variableValue: indicator.variableValue,
            description: indicator.accessibilityLabel
        )
    }

    private static func statusImage(symbolName: String, variableValue: Double?, description: String) -> NSImage? {
        let image = variableValue.flatMap {
            NSImage(systemSymbolName: symbolName, variableValue: $0, accessibilityDescription: description)
        } ?? NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        let configured = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        configured?.isTemplate = true
        return configured
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            togglePicker()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// A clean exit; the LaunchAgent only restarts crashes, so this stays quit until next login.
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func systemDidWake() {
        controller.noteSystemDidWake()
    }

    private func togglePicker() {
        if popover.isShown {
            hidePicker(userInitiated: true)
        } else {
            controller.presentManually()
        }
    }

    private func showPicker() {
        if isClosing {
            showRequestedWhileClosing = true
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            // Already on screen after an auto-show; the user has now asked for it.
            if controller.isManuallyPresented { pickerViewController.engageKeyboard() }
            return
        }
        let screenHeight = button.window?.screen?.visibleFrame.height ?? 800
        pickerViewController.maximumPanelHeight = screenHeight * 0.6
        NSApp.setActivationPolicy(.accessory)
        // The system's menu-bar panels have no arrow. The key is private: if a later macOS drops
        // it, the check fails and the arrow simply comes back.
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Only a user-opened panel takes the keyboard. Auto-show leaves the app inactive, so
        // Return keeps going to whatever the user was typing in; a mouse click still works.
        if controller.isManuallyPresented {
            pickerViewController.engageKeyboard()
        } else {
            pickerViewController.presentWithoutKeyboard()
        }
        if let loginItemMessage {
            self.loginItemMessage = nil
            pickerViewController.presentLoginItemNotice(loginItemMessage) {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    private func hidePicker(userInitiated: Bool = false) {
        guard popover.isShown, !isClosing else { return }
        isClosing = true
        closeCause = userInitiated ? .user : .automatic
        popover.close()
        NSApp.setActivationPolicy(.accessory)
    }

    func popoverWillClose(_ notification: Notification) {
        if !isClosing {
            isClosing = true
            closeCause = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        let completedCloseCause = closeCause
        closeCause = nil
        isClosing = false
        pickerViewController.prepareForPopoverClose()
        let shouldReopen = showRequestedWhileClosing
        showRequestedWhileClosing = false
        if completedCloseCause != .automatic, !shouldReopen {
            controller.pickerDidCloseByUser()
        }
        NSApp.setActivationPolicy(.accessory)
        guard shouldReopen else { return }
        DispatchQueue.main.async { [weak self] in self?.showPicker() }
    }

    private func configureLoginItem() {
        let service = SMAppService.mainApp
        let fallbackURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.github.ruodou233.MacWiFiPicker.plist")
        if launchedByFallbackAgent || FileManager.default.fileExists(atPath: fallbackURL.path) {
            // The compatibility LaunchAgent is itself the login mechanism. Do
            // not recreate a pending main-app login item from this process or
            // a later user approval could start a second copy at login.
            switch service.status {
            case .enabled, .requiresApproval:
                do {
                    try service.unregister()
                } catch {
                    log.notice("login item: could not remove the duplicate, \(String(describing: error), privacy: .public)")
                }
            case .notRegistered, .notFound:
                break
            @unknown default:
                do {
                    try service.unregister()
                } catch {
                    log.notice("login item: could not remove the unknown one, \(String(describing: error), privacy: .public)")
                }
            }
            return
        }

        switch service.status {
        case .enabled:
            return
        case .notRegistered:
            do {
                try service.register()
                if service.status == .requiresApproval {
                    loginItemMessage = "需要在系统设置中允许“登录时打开”"
                } else if service.status != .enabled {
                    loginItemMessage = "需要在系统设置中允许“登录时打开”"
                }
            } catch {
                loginItemMessage = "未能设为登录时打开"
            }
        case .requiresApproval:
            loginItemMessage = "需要在系统设置中允许“登录时打开”"
        case .notFound:
            // The system could not find this app for a login item. Scripts/install.sh
            // starts it from a LaunchAgent instead.
            return
        @unknown default:
            return
        }
    }

}
