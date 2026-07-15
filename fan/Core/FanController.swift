//
//  FanController.swift
//  ffan
//
//  Created by mohamad on 11/1/2026.
//  SMC fan control with per-fan targets and hardware-derived RPM limits.
//

import Foundation
import Combine
import IOKit

enum ControlMode: String, CaseIterable {
    case manual
    case automatic
}

class FanController: ObservableObject {
    @Published var mode: ControlMode = .manual
    /// Unified manual target (single slider / legacy settings).
    @Published var manualSpeed: Int = 2000
    /// When `perFanManualControl` is true, each index maps to `F%dTg` for fan `d`.
    @Published var manualSpeeds: [Int] = []
    @Published var perFanManualControl: Bool = false

    @Published var autoThreshold: Double = 60.0
    @Published var autoMaxSpeed: Int = 4500
    @Published var autoAggressiveness: Double = 1.5  // 0.0 = always min, 1.5 = temp-based, 3.0 = always max
    @Published var isControlEnabled = false
    @Published var lastWriteSuccess = false
    @Published var statusMessage: String = ""
    /// Largest target RPM last applied (used for auto-mode hysteresis).
    @Published var lastAppliedSpeed: Int = 0

    private weak var systemMonitor: SystemMonitor?
    private var autoControlTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Serializes privileged-helper invocations off the main thread so a slider
    /// drag (or the auto loop) never blocks the UI on sudo + waitUntilExit.
    private let applyQueue = DispatchQueue(label: "com.solofan.fan-apply", qos: .userInitiated)

    private var smcHelperPath: String {
        "/usr/local/bin/smc-helper"
    }

    init(systemMonitor: SystemMonitor) {
        self.systemMonitor = systemMonitor
        loadSettings()

        systemMonitor.$fanMaxSpeeds
            .combineLatest(systemMonitor.$fanMinSpeeds, systemMonitor.$numberOfFans)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, fanCount in
                guard let self = self, fanCount > 0 else { return }
                self.onHardwareLimitsUpdated()
            }
            .store(in: &cancellables)

        systemMonitor.$numberOfFans
            .receive(on: DispatchQueue.main)
            .filter { $0 > 0 }
            .first()
            .sink { [weak self] _ in
                print("FanController: Fans detected, applying initial settings")
                self?.applyInitialSettings()
            }
            .store(in: &cancellables)
    }

    deinit {
        stopAutoControl()
        restoreAutomaticControl()
    }

    // MARK: - Hardware-derived clamps

    private var unifiedMinClamp: Int {
        systemMonitor?.fanMinSpeeds.min() ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
    }

    private var unifiedMaxClamp: Int {
        systemMonitor?.fanMaxSpeeds.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
    }

    private func minRPM(for index: Int) -> Int {
        guard let monitor = systemMonitor,
              index >= 0,
              index < monitor.fanMinSpeeds.count else {
            return FanRPMBounds.fallbackMinWhenSMCUnreadable
        }
        return monitor.fanMinSpeeds[index]
    }

    private func maxRPM(for index: Int) -> Int {
        guard let monitor = systemMonitor,
              index >= 0,
              index < monitor.fanMaxSpeeds.count else {
            return FanRPMBounds.fallbackMaxWhenSMCUnreadable
        }
        return monitor.fanMaxSpeeds[index]
    }

    private func clampToFan(_ speed: Int, index: Int) -> Int {
        max(minRPM(for: index), min(maxRPM(for: index), speed))
    }

    private func clampUnified(_ speed: Int) -> Int {
        max(unifiedMinClamp, min(unifiedMaxClamp, speed))
    }

    private func onHardwareLimitsUpdated() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        ensureManualSpeedsSize()
        manualSpeed = clampUnified(manualSpeed)
        autoMaxSpeed = clampUnified(autoMaxSpeed)
        if !manualSpeeds.isEmpty {
            manualSpeeds = manualSpeeds.enumerated().map { clampToFan($0.element, index: $0.offset) }
        }
        saveSettings()

        if mode == .manual && isControlEnabled {
            applyManualTargets()
        } else if mode == .automatic && isControlEnabled {
            lastAppliedSpeed = 0
            updateAutoControl()
        }
    }

    private func ensureManualSpeedsSize() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        let n = monitor.numberOfFans
        if manualSpeeds.count < n {
            var copy = manualSpeeds
            let template = copy.last ?? manualSpeed
            while copy.count < n {
                let idx = copy.count
                copy.append(clampToFan(template, index: idx))
            }
            manualSpeeds = copy
        } else if manualSpeeds.count > n {
            manualSpeeds = Array(manualSpeeds.prefix(n))
        }
    }

    private func syncManualSpeedsFromUnified() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        manualSpeeds = (0..<monitor.numberOfFans).map { clampToFan(manualSpeed, index: $0) }
    }

    // MARK: - Lifecycle

    private func applyInitialSettings() {
        print("FanController: Applying initial settings - mode: \(mode)")
        switch mode {
        case .manual:
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
        case .automatic:
            startAutoControl()
        }
    }

    func reapplySettings() {
        print("FanController: Reapplying settings after wake - mode: \(mode)")
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else {
            print("FanController: No fans detected yet, retrying in 2 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.reapplySettings()
            }
            return
        }

        switch mode {
        case .manual:
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
            print("FanController: Manual mode reapplied")
        case .automatic:
            enableManualMode()
            startAutoControl()
            lastAppliedSpeed = 0
            updateAutoControl()
            print("FanController: Auto mode reapplied")
        }
    }

    /// Toggle independent sliders for each fan (manual mode only).
    func setPerFanManualControl(_ enabled: Bool) {
        perFanManualControl = enabled
        if enabled {
            syncManualSpeedsFromUnified()
        } else {
            if !manualSpeeds.isEmpty {
                let avg = Int(round(Double(manualSpeeds.reduce(0, +)) / Double(manualSpeeds.count)))
                manualSpeed = clampUnified(avg)
            }
            syncManualSpeedsFromUnified()
        }
        saveSettings()
        if mode == .manual && isControlEnabled {
            applyManualTargets()
        }
    }

    func setManualSpeed(_ speed: Int) {
        guard mode == .manual else { return }
        manualSpeed = clampUnified(speed)
        if !perFanManualControl {
            syncManualSpeedsFromUnified()
        }
        if isControlEnabled {
            applyManualTargets()
        }
        saveSettings()
    }

    func setManualSpeed(fanIndex: Int, speed: Int) {
        guard mode == .manual, perFanManualControl else { return }
        ensureManualSpeedsSize()
        guard fanIndex >= 0, fanIndex < manualSpeeds.count else { return }
        var next = manualSpeeds
        next[fanIndex] = clampToFan(speed, index: fanIndex)
        manualSpeeds = next
        saveSettings()
        if isControlEnabled {
            applyManualTargets()
        }
    }

    func setMode(_ newMode: ControlMode) {
        mode = newMode

        if newMode == .automatic {
            restoreAutomaticControl()
            startAutoControl()
        } else {
            stopAutoControl()
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
        }

        saveSettings()
    }

    private func enableManualMode() {
        guard systemMonitor != nil else {
            statusMessage = "No system monitor available"
            return
        }
        isControlEnabled = true
        statusMessage = "Manual control enabled"
        print("Fan Control: Manual control enabled")
    }

    func restoreAutomaticControl() {
        guard let monitor = systemMonitor else { return }
        let n = monitor.numberOfFans
        guard n > 0 else { return }

        applyQueue.async { [weak self] in
            guard let self = self else { return }
            var allSuccess = true
            for i in 0..<n {
                if !self.runSmcHelper(args: ["auto", "\(i)"]) {
                    allSuccess = false
                }
            }
            DispatchQueue.main.async {
                if allSuccess {
                    self.isControlEnabled = false
                    self.statusMessage = "Automatic mode restored"
                    print("Fan Control: Automatic mode restored")
                } else {
                    self.statusMessage = "Failed to restore auto mode"
                    print("Fan Control: Failed to restore auto mode")
                }
            }
        }
    }

    private func applyManualTargets() {
        guard let monitor = systemMonitor else {
            statusMessage = "No system monitor"
            lastWriteSuccess = false
            return
        }
        guard monitor.numberOfFans > 0 else {
            statusMessage = "No fans detected"
            lastWriteSuccess = false
            return
        }

        ensureManualSpeedsSize()
        var targets: [Int] = []
        for i in 0..<monitor.numberOfFans {
            let raw: Int
            if perFanManualControl, i < manualSpeeds.count {
                raw = manualSpeeds[i]
            } else {
                raw = manualSpeed
            }
            targets.append(clampToFan(raw, index: i))
        }
        applyFanTargets(targets)
    }

    private func applyFanTargets(_ targets: [Int]) {
        guard let monitor = systemMonitor else {
            statusMessage = "No system monitor"
            lastWriteSuccess = false
            return
        }
        guard monitor.numberOfFans > 0, targets.count == monitor.numberOfFans else {
            statusMessage = "Fan target mismatch"
            lastWriteSuccess = false
            return
        }

        // Spawning the privileged helper blocks: sudo + waitUntilExit, and the
        // helper itself sleeps while taking manual control. Running that on the
        // main thread freezes the UI mid slider-drag. Serialize applies onto a
        // background queue and only touch @Published state back on main.
        applyQueue.async { [weak self] in
            guard let self = self else { return }
            var allSuccess = true
            for (i, t) in targets.enumerated() {
                let safe = max(FanRPMBounds.absoluteWriteMinRPM, min(FanRPMBounds.absoluteWriteMaxRPM, t))
                if !self.runSmcHelper(args: ["set", "\(i)", "\(safe)"]) {
                    allSuccess = false
                }
            }
            let parts = targets.enumerated().map { "F\($0.offset): \($0.element)" }.joined(separator: ", ")
            DispatchQueue.main.async {
                if allSuccess {
                    self.statusMessage = "Fan targets RPM — \(parts)"
                    self.lastWriteSuccess = true
                    print("Fan Control: \(parts)")
                } else {
                    self.statusMessage = "Failed to set fan speed"
                    self.lastWriteSuccess = false
                }
            }
        }
    }

    private func runSmcHelper(args: [String]) -> Bool {
        let helperPath = smcHelperPath

        // Runs on a background queue — do not touch @Published here. Callers map
        // the false return to a status message back on the main thread.
        if !FileManager.default.fileExists(atPath: helperPath) {
            print("Error: \(helperPath) not found")
            return false
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", helperPath] + args
        task.environment = ["LANG": "C"]
        let stderrPipe = Pipe()
        task.standardError = stderrPipe

        do {
            try task.run()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return true
            }
            // Two failures exit non-zero: sudo refusing to run us (a privilege
            // problem the password prompt can fix) and the helper running AS ROOT
            // then failing — e.g. thermalmonitord transiently holding the fan in
            // SYSTEM mode right after wake, where unlockFanManual loses the reclaim
            // race. Re-running the latter under admin privileges hits the same SMC
            // failure and only pops a spurious password dialog. Only sudo's own
            // refusal warrants the AppleScript fallback, and sudo prefixes those
            // messages with "sudo:".
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            if !stderr.contains("sudo:") {
                print("Fan Control: helper ran as root and failed (exit \(task.terminationStatus)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return false
            }
        } catch {
            print("Fan Control: sudo -n execution error: \(error)")
        }

        print("Fan Control: sudo -n unauthorized. Falling back to AppleScript.")
        let argsString = args.joined(separator: " ")
        let fullCommand = "'\(helperPath)' \(argsString)"
        let scriptSource = "do shell script \"\(fullCommand)\" with administrator privileges"

        // NSAppleScript drives Apple Events and must run on the main thread; this
        // path is normally reached from applyQueue (off-main), so hop to main.
        // restoreAutomaticControlSync() calls us already on main at quit — run
        // inline there, since main.sync onto itself would deadlock.
        let runScript: () -> Bool = {
            var error: NSDictionary?
            guard let scriptObject = NSAppleScript(source: scriptSource) else { return false }
            _ = scriptObject.executeAndReturnError(&error)
            if error != nil {
                let errorMsg = error?["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                print("Fan Control: AppleScript failed: \(errorMsg)")
                return false
            }
            return true
        }
        return Thread.isMainThread ? runScript() : DispatchQueue.main.sync(execute: runScript)
    }

    func startAutoControl() {
        stopAutoControl()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateAutoControl()
            self.autoControlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.updateAutoControl()
            }
            RunLoop.current.add(self.autoControlTimer!, forMode: .common)
        }
    }

    func stopAutoControl() {
        autoControlTimer?.invalidate()
        autoControlTimer = nil
    }

    private func updateAutoControl() {
        guard mode == .automatic, let monitor = systemMonitor else { return }

        let currentTemp = max(
            monitor.cpuTemperature ?? 0,
            monitor.gpuTemperature ?? 0
        )

        guard currentTemp > 0, monitor.numberOfFans > 0 else { return }

        let response = autoAggressiveness
        let midPoint = 1.5

        let tempFloor = 30.0
        let tempCeiling = 90.0
        let tempRatio = max(0.0, min(1.0, (currentTemp - tempFloor) / (tempCeiling - tempFloor)))
        let autoCeiling = min(autoMaxSpeed, unifiedMaxClamp)
        let autoFloor = unifiedMinClamp
        let tempBasedSpeed = Double(autoFloor) + Double(max(0, autoCeiling - autoFloor)) * tempRatio

        let targetSpeed: Double
        if response <= midPoint {
            let blend = response / midPoint
            targetSpeed = Double(autoFloor) * (1.0 - blend) + tempBasedSpeed * blend
        } else {
            let blend = (response - midPoint) / (3.0 - midPoint)
            targetSpeed = tempBasedSpeed * (1.0 - blend) + Double(autoCeiling) * blend
        }

        if !isControlEnabled {
            enableManualMode()
        }

        let unifiedTarget = Int(max(Double(autoFloor), min(targetSpeed, Double(autoCeiling))))

        var targets: [Int] = []
        for i in 0..<monitor.numberOfFans {
            let mx = maxRPM(for: i)
            let mn = minRPM(for: i)
            let cap = min(mx, autoCeiling)
            targets.append(max(mn, min(unifiedTarget, cap)))
        }

        let representative = targets.max() ?? unifiedTarget

        if abs(representative - lastAppliedSpeed) >= 50 || lastAppliedSpeed == 0 {
            applyFanTargets(targets)
            lastAppliedSpeed = representative

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let parts = targets.enumerated().map { "F\($0.offset): \($0.element)" }.joined(separator: ", ")
                self.statusMessage = "Auto — \(parts) (response \(String(format: "%.1f", self.autoAggressiveness)))"
            }
        }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard

        if let savedMode = defaults.string(forKey: "fanControlMode") {
            mode = ControlMode(rawValue: savedMode) ?? .manual
        }

        perFanManualControl = defaults.bool(forKey: "perFanManualControl")

        let savedManualSpeed = defaults.integer(forKey: "manualFanSpeed")
        if savedManualSpeed >= FanRPMBounds.absoluteWriteMinRPM && savedManualSpeed <= FanRPMBounds.absoluteWriteMaxRPM {
            manualSpeed = savedManualSpeed
        }

        if let savedPerFan = defaults.array(forKey: "manualFanSpeedsPerFan") as? [Int], !savedPerFan.isEmpty {
            manualSpeeds = savedPerFan
        }

        let savedThreshold = defaults.double(forKey: "autoThreshold")
        if savedThreshold >= 40 && savedThreshold <= 90 {
            autoThreshold = savedThreshold
        }

        let savedMaxSpeed = defaults.integer(forKey: "autoMaxSpeed")
        if savedMaxSpeed >= FanRPMBounds.absoluteWriteMinRPM && savedMaxSpeed <= FanRPMBounds.absoluteWriteMaxRPM {
            autoMaxSpeed = savedMaxSpeed
        }

        let savedAggressiveness = defaults.double(forKey: "autoAggressiveness")
        if savedAggressiveness >= 0.0 && savedAggressiveness <= 3.0 {
            autoAggressiveness = savedAggressiveness
        }
    }

    func resetToSystemControl() {
        print("Fan Control: Resetting to system default...")
        stopAutoControl()
        restoreAutomaticControl()
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: "fanControlMode")
        defaults.set(perFanManualControl, forKey: "perFanManualControl")
        defaults.set(manualSpeed, forKey: "manualFanSpeed")
        defaults.set(manualSpeeds, forKey: "manualFanSpeedsPerFan")
        defaults.set(autoThreshold, forKey: "autoThreshold")
        defaults.set(autoMaxSpeed, forKey: "autoMaxSpeed")
        defaults.set(autoAggressiveness, forKey: "autoAggressiveness")
    }

    func setAutoThreshold(_ threshold: Double) {
        autoThreshold = max(40, min(90, threshold))
        saveSettings()
        if mode == .automatic {
            lastAppliedSpeed = 0
            updateAutoControl()
        }
    }

    func setAutoMaxSpeed(_ speed: Int) {
        autoMaxSpeed = clampUnified(speed)
        saveSettings()
        if mode == .automatic {
            lastAppliedSpeed = 0
            updateAutoControl()
        }
    }

    func setAutoAggressiveness(_ value: Double) {
        autoAggressiveness = max(0.0, min(3.0, value))
        saveSettings()
        if mode == .automatic {
            lastAppliedSpeed = 0
            updateAutoControl()
        }
    }
}
