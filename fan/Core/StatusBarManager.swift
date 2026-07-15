//
//  StatusBarManager.swift
//  ffan
//
//  Created by mohamad on 11/1/2026.
//  Static status bar icon with dynamic display text (temp / power / fan load)
//

import AppKit
import SwiftUI
import Combine

class StatusBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var refreshTimer: Timer?
    /// Builds the popover's SwiftUI content on demand. Kept as a factory (not a
    /// retained view) so the heavy hierarchy — dashboard gauges, Metal glass
    /// panels, the spinning-fan animation — exists only while the popover is open.
    var popoverContentProvider: (() -> NSViewController)?
    private var popoverCloseObserver: PopoverCloseObserver?
    /// Built once and reused. The menu-bar glyph is intentionally static: a
    /// per-frame redraw of the status item forces AppKit (and any menu-bar
    /// manager observing it) to recomposite continuously, pegging a core even
    /// while the item is hidden. Information lives in the title text, not motion.
    private lazy var fanIcon: NSImage = {
        let icon = createFanIcon(size: 16, rotation: 0)
        icon.isTemplate = true // tinted by the system to match every other menu-bar glyph
        return icon
    }()
    /// Latest sampled RPM per fan (from SMC).
    private var cachedFanSpeeds: [Int] = []
    private var cachedFanMinRPM: [Int] = []
    private var cachedFanMaxRPM: [Int] = []
    private var displayFanSpeedMax: Int = 0
    private var currentTemperature: Double?
    private var currentPowerWatts: Double?
    private var displayMode: String = "temperature"

    /// Called when the user chooses **Open Settings** from the status item menu.
    var onOpenSettings: (() -> Void)?
    /// Called when the user chooses **Hide Icon** from the status item menu.
    var onHideIcon: (() -> Void)?
    /// Called when the user chooses **Close App** from the status item menu.
    var onQuitApp: (() -> Void)?

    var isStatusItemVisible: Bool { statusItem != nil }
    
    func setupStatusBar() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if MenuBarIconPreferences.isHidden {
                self.ensurePopoverExists()
                return
            }
            self.createStatusItemIfNeeded()
            self.startRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let power = BatteryMonitor.shared.batteryInfo.powerWatts
            self.currentPowerWatts = power
            self.updateDisplay()
        }
        RunLoop.current.add(refreshTimer!, forMode: .common)
    }

    private func ensurePopoverExists() {
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 340, height: 600)
            // Release the SwiftUI hierarchy (and its Metal pipeline / animations)
            // the moment the popover closes — NSPopover otherwise retains its
            // contentViewController and keeps rendering it in the background.
            let observer = PopoverCloseObserver { [weak self] in
                self?.popover?.contentViewController = nil
            }
            popover.delegate = observer
            self.popoverCloseObserver = observer
            self.popover = popover
        }
    }

    private func createStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        createStatusItem()
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else {
            return
        }
        
        // Set static icon
        button.image = fanIcon
        button.title = "SoloFan"
        button.imagePosition = .imageLeft
        button.toolTip = "SoloFan"
        
        print("StatusBar: Created status item - button exists: \(button), title=\(button.title), image=\(String(describing: button.image)), isTemplate=\(button.image?.isTemplate ?? false)")
        
        // Left click → popover; right click → context menu
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        
        ensurePopoverExists()
    }

    /// Removes the menu bar icon while keeping monitoring and popover state alive.
    func hideMenuBarIcon(persist: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.closePopover()

            if persist {
                MenuBarIconPreferences.isHidden = true
            }

            if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }

            print("StatusBar: Menu bar icon hidden")
        }
    }

    /// Restores the menu bar icon after it was hidden.
    func showMenuBarIcon(persist: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if persist {
                MenuBarIconPreferences.isHidden = false
            }

            self.createStatusItemIfNeeded()
            self.startRefreshTimer()
            self.setDisplayMode(self.displayMode)
            self.updateDisplay()

            print("StatusBar: Menu bar icon shown")
        }
    }
    
    private func createFanIcon(size: CGFloat, rotation: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.cgContext.translateBy(x: size/2, y: size/2)
            NSGraphicsContext.current?.cgContext.rotate(by: rotation * .pi / 180)
            NSGraphicsContext.current?.cgContext.translateBy(x: -size/2, y: -size/2)
            
            let center = NSPoint(x: size/2, y: size/2)
            let bladeLength: CGFloat = size * 0.42
            
            for i in 0..<3 {
                let angle = CGFloat(i) * 120 * .pi / 180
                
                let bladePath = NSBezierPath()
                let hubRadius: CGFloat = size * 0.15
                
                let endX = center.x + cos(angle) * bladeLength
                let endY = center.y + sin(angle) * bladeLength
                
                let leftAngle = angle - 0.35
                let leftStartX = center.x + cos(leftAngle) * hubRadius
                let leftStartY = center.y + sin(leftAngle) * hubRadius
                let leftEndX = center.x + cos(angle - 0.2) * bladeLength * 0.9
                let leftEndY = center.y + sin(angle - 0.2) * bladeLength * 0.9
                
                let rightAngle = angle + 0.35
                let rightStartX = center.x + cos(rightAngle) * hubRadius
                let rightStartY = center.y + sin(rightAngle) * hubRadius
                let rightEndX = center.x + cos(angle + 0.15) * bladeLength * 0.95
                let rightEndY = center.y + sin(angle + 0.15) * bladeLength * 0.95
                
                bladePath.move(to: NSPoint(x: leftStartX, y: leftStartY))
                bladePath.curve(to: NSPoint(x: leftEndX, y: leftEndY),
                               controlPoint1: NSPoint(x: center.x + cos(angle - 0.25) * bladeLength * 0.5,
                                                     y: center.y + sin(angle - 0.25) * bladeLength * 0.5),
                               controlPoint2: NSPoint(x: leftEndX, y: leftEndY))
                
                bladePath.curve(to: NSPoint(x: rightEndX, y: rightEndY),
                               controlPoint1: NSPoint(x: endX, y: endY),
                               controlPoint2: NSPoint(x: rightEndX, y: rightEndY))
                
                bladePath.curve(to: NSPoint(x: rightStartX, y: rightStartY),
                               controlPoint1: NSPoint(x: center.x + cos(angle + 0.2) * bladeLength * 0.5,
                                                     y: center.y + sin(angle + 0.2) * bladeLength * 0.5),
                               controlPoint2: NSPoint(x: rightStartX, y: rightStartY))
                
                bladePath.close()
                
                NSColor.black.setFill()
                bladePath.fill()
            }
            
            let hubSize = size * 0.3
            let hubPath = NSBezierPath(ovalIn: NSRect(x: center.x - hubSize/2,
                                                       y: center.y - hubSize/2,
                                                       width: hubSize,
                                                       height: hubSize))
            NSColor.black.setFill()
            hubPath.fill()
            
            return true
        }
        
        image.isTemplate = true
        return image
    }
    
    func updateIcon(fanSpeeds: [Int], fanMinSpeeds: [Int], fanMaxSpeeds: [Int], temperature: Double?, powerWatts: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cachedFanSpeeds = fanSpeeds
            self.cachedFanMinRPM = fanMinSpeeds
            self.cachedFanMaxRPM = fanMaxSpeeds
            self.displayFanSpeedMax = fanSpeeds.max() ?? 0
            self.currentTemperature = temperature
            self.currentPowerWatts = powerWatts
            self.updateDisplay()
        }
    }

    /// Mean utilization in \([0,100]\) across fans using each fan's SMC min/max span.
    private func averageFanLoadPercent() -> Int {
        guard !cachedFanSpeeds.isEmpty else { return 0 }
        var sum = 0.0
        var count = 0
        for i in 0..<cachedFanSpeeds.count {
            let mn = i < cachedFanMinRPM.count ? cachedFanMinRPM[i] : cachedFanMinRPM.first ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
            guard i < cachedFanMaxRPM.count else { continue }
            let mx = cachedFanMaxRPM[i]
            guard mx > mn else { continue }
            let p = Double(cachedFanSpeeds[i] - mn) / Double(mx - mn)
            sum += min(1.0, max(0.0, p))
            count += 1
        }
        guard count > 0 else {
            let ref = cachedFanMaxRPM.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
            guard ref > 0 else { return 0 }
            return min(100, max(0, Int(round(Double(displayFanSpeedMax) / Double(ref) * 100))))
        }
        return Int(min(100, max(0, round(sum / Double(count) * 100))))
    }

    func setDisplayMode(_ mode: String) {
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            if let button = self?.statusItem?.button {
                if mode == "none" {
                    button.title = ""
                    button.imagePosition = .imageOnly
                } else {
                    button.imagePosition = .imageLeft
                }
            }
            self?.updateDisplay()
        }
    }
    
    private func updateDisplay() {
        guard let button = statusItem?.button else { return }
        
        // Update button title based on display mode
        let text = getDisplayText()
        // Use a compact font for the title to reduce visual length
        if text.isEmpty {
            button.title = ""
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular)
            ]
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
        print("StatusBar: updateDisplay mode=\(displayMode) text='\(text)'")
    }
    
    private func getDisplayText() -> String {
        switch displayMode {
        case "none":
            return ""
        case "temperature":
            if let temp = currentTemperature {
                return String(format: "%.0f°", temp)
            }
            return "--°"
        case "power":
            if BatteryMonitor.shared.hasBattery, let pw = currentPowerWatts, pw > 0.01 {
                return String(format: "%.1fW", pw)
            }
            // Desktop / no battery: show fan load or temperature
            if !BatteryMonitor.shared.hasBattery {
                let percentage = averageFanLoadPercent()
                if percentage > 0 {
                    return "\(percentage)%"
                }
                if let temp = currentTemperature {
                    return String(format: "%.0f°", temp)
                }
            }
            if let pw = currentPowerWatts, pw > 0.01 {
                return String(format: "%.1fW", pw)
            }
            let percentage = averageFanLoadPercent()
            return "\(percentage)%"
        case "fanSpeedPercentage":
            let percentage = averageFanLoadPercent()
            return "\(percentage)%"
        default:
            if let temp = currentTemperature {
                return String(format: "%.0f°", temp)
            }
            return "--°"
        }
    }
    
    @objc private func statusBarButtonClicked(_ sender: NSButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        switch event.type {
        case .rightMouseUp:
            showContextMenu(for: sender)
        default:
            togglePopover()
        }
    }

    private func showContextMenu(for button: NSButton) {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Open Settings",
            action: #selector(contextMenuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hideItem = NSMenuItem(
            title: "Hide Icon",
            action: #selector(contextMenuHideIcon),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Close App",
            action: #selector(contextMenuQuitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func contextMenuOpenSettings() {
        onOpenSettings?()
    }

    @objc private func contextMenuHideIcon() {
        onHideIcon?()
    }

    @objc private func contextMenuQuitApp() {
        onQuitApp?()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else {
            print("StatusBar: Cannot toggle - button or popover is nil")
            return
        }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // Content is intentionally nil until open (and cleared on close) so the
        // SwiftUI hierarchy does not keep rendering in the background.
        if popover.contentViewController == nil {
            guard let popoverContentProvider else {
                print("StatusBar: Popover content provider is nil")
                return
            }
            popover.contentViewController = popoverContentProvider()
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    
    func closePopover() {
        popover?.performClose(nil)
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
}

/// Releases popover content when the popover closes. NSPopover retains its
/// contentViewController, so without this the SwiftUI hierarchy keeps rendering
/// (and holding a Metal pipeline) while the popover is hidden.
private final class PopoverCloseObserver: NSObject, NSPopoverDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func popoverDidClose(_ notification: Notification) { onClose() }
}
