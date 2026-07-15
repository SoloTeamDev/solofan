//
//  SoloFanApp.swift
//  SoloFan
//
//  Created by mohamad on 11/1/2026.
//  Menu bar app entry point
//

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusBarManager: StatusBarManager?
    var viewModel: FanControlViewModel?
    private var iconUpdateTimer: Timer?
    private var displayModeObserver: NSObjectProtocol?
    private var menuBarVisibilityObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        installSettingsKeyboardShortcut()
        setupApplication()
    }

    private func installSettingsKeyboardShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "," else {
                return event
            }
            self?.openSettings()
            return nil
        }
    }

    private func setupApplication() {
        let viewModel = FanControlViewModel()
        self.viewModel = viewModel
        SettingsWindowController.shared.bind(viewModel: viewModel)

        let statusBarManager = StatusBarManager()
        self.statusBarManager = statusBarManager
        wireStatusBarActions(statusBarManager)

        let initialMode = UserDefaults.standard.string(forKey: "statusBarDisplayMode") ?? "temperature"
        statusBarManager.setDisplayMode(initialMode)

        displayModeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StatusBarDisplayModeChanged"),
            object: nil,
            queue: .main
        ) { [weak statusBarManager] notification in
            if let mode = notification.object as? String {
                statusBarManager?.setDisplayMode(mode)
            }
        }

        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if notification.object as? Bool == false {
                self.attachPopoverContent()
            }
        }

        statusBarManager.setupStatusBar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachPopoverContent()
            self?.initializeMonitoring()

            if MenuBarIconPreferences.isHidden {
                self?.presentSettingsForHiddenIcon(reason: "launch")
            }
        }
    }

    private func wireStatusBarActions(_ manager: StatusBarManager) {
        manager.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        manager.onHideIcon = { [weak self] in
            self?.hideMenuBarIconFromUserAction()
        }
        manager.onQuitApp = { [weak self] in
            self?.quitApplication()
        }
    }

    private func attachPopoverContent() {
        guard let statusBarManager, let viewModel else { return }
        // Provide a factory, not a live view. The popover builds its content on
        // open and releases it on close (see StatusBarManager), so the dashboard
        // gauges and glass panels never render while the popover is hidden.
        statusBarManager.popoverContentProvider = { [weak viewModel, weak statusBarManager] in
            guard let viewModel, let statusBarManager else { return NSViewController() }
            return NSHostingController(
                rootView: PopoverView(viewModel: viewModel, statusBarManager: statusBarManager)
            )
        }
    }

    func openSettings() {
        statusBarManager?.closePopover()
        SettingsWindowController.shared.openSettings()
    }

    private func hideMenuBarIconFromUserAction() {
        statusBarManager?.hideMenuBarIcon()
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        guard let statusBarManager else { return }
        if visible {
            statusBarManager.showMenuBarIcon()
            attachPopoverContent()
        } else {
            statusBarManager.hideMenuBarIcon()
        }
    }

    func presentSettingsForHiddenIcon(reason: String) {
        guard MenuBarIconPreferences.isHidden else { return }
        print("SoloFan: presenting settings (icon hidden, reason=\(reason))")
        openSettings()
    }

    private func quitApplication() {
        viewModel?.resetToSystemControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func initializeMonitoring() {
        guard let viewModel else { return }
        viewModel.startMonitoring()
        startIconUpdateTimer()
    }

    private func startIconUpdateTimer() {
        iconUpdateTimer?.invalidate()
        iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateStatusBarIcon()
        }
        RunLoop.current.add(iconUpdateTimer!, forMode: .common)
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        guard let viewModel,
              let statusBarManager,
              statusBarManager.isStatusItemVisible else { return }

        let maxTemp = viewModel.getMaxTemperature()
        let power = BatteryMonitor.shared.batteryInfo.powerWatts
        statusBarManager.updateIcon(
            fanSpeeds: viewModel.fanSpeeds,
            fanMinSpeeds: viewModel.fanMinSpeeds,
            fanMaxSpeeds: viewModel.fanMaxSpeeds,
            temperature: maxTemp > 0 ? maxTemp : nil,
            powerWatts: power
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if MenuBarIconPreferences.isHidden {
            presentSettingsForHiddenIcon(reason: "reopen")
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconUpdateTimer?.invalidate()
        viewModel?.stopMonitoring()

        if let observer = displayModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = menuBarVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SoloFanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("SoloFan")
                .frame(width: 0, height: 0)
                .hidden()
        }
    }
}
