//
//  SystemMonitor.swift
//  ffan
//
//  Created by mohamad on 11/1/2026.
//  Rewritten for proper SMC access on both Intel and Apple Silicon Macs
//

import Foundation
import Combine
import IOKit

// MARK: - Data Structures

struct TemperatureReading {
    let cpu: Double?
    let gpu: Double?
}

struct FanReading {
    let id: Int
    let speed: Int
    let minSpeed: Int
    let maxSpeed: Int
}

// MARK: - SMC Types (Compatible with actual Apple SMC)

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

// SMC key as 4-character code (FourCharCode)
private func fourCharCodeFrom(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, char) in string.utf8.prefix(4).enumerated() {
        result |= UInt32(char) << (8 * (3 - index))
    }
    return result
}

private func stringFrom(fourCharCode: UInt32) -> String {
    let bytes = [
        UInt8((fourCharCode >> 24) & 0xFF),
        UInt8((fourCharCode >> 16) & 0xFF),
        UInt8((fourCharCode >> 8) & 0xFF),
        UInt8(fourCharCode & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

// SMC Version structure
private struct SMCKeyData_vers_t {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

// SMC Limit Data
private struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

// SMC Key Info structure
private struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

// Main SMC structure - must match kernel's SMCParamStruct exactly
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_pLimitData_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// SMC selector (kSMCUserClientOpen = 0, kSMCHandleYPCEvent = 2, etc.)
private let KERNEL_INDEX_SMC: UInt32 = 2

// SMC commands
private let SMC_CMD_READ_BYTES: UInt8 = 5
private let SMC_CMD_WRITE_BYTES: UInt8 = 6
private let SMC_CMD_READ_KEYINFO: UInt8 = 9

// MARK: - System Monitor Class

class SystemMonitor: ObservableObject {
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    @Published var fanSpeeds: [Int] = []
    @Published var fanMinSpeeds: [Int] = []
    @Published var fanMaxSpeeds: [Int] = []
    @Published var numberOfFans: Int = 0
    @Published var isMonitoring = false
    @Published var hasAccess = false
    @Published var lastError: String?
    
    private var smcConnection: io_connect_t = 0
    private var monitoringTimer: Timer?
    private let monitoringInterval: TimeInterval = 2.0
    private var keyInfoCache: [UInt32: SMCKeyData_keyInfo_t] = [:]
    
    // Intel CPU/GPU proximity keys (legacy Macs).
    private let cpuTempKeysIntel = ["TC0P", "TCXC", "TC0E", "TC0F", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C"]
    private let gpuTempKeysIntel = ["TGDD", "TG0P", "TG0D", "TG0E", "TG0F"]

    // Apple Silicon die sensors: P/E-core clusters (Tp**/Te**) for CPU, Tg** for
    // GPU. The exact suffixes vary by chip (M1-M4), so we probe a generous set;
    // missing keys are simply skipped. Per-core sensors report ~1-2°C when their
    // core is gated/idle, so callers take the hottest plausible reading, never
    // the first that parses (which a gated 2°C core would win).
    private let cpuTempKeysAS = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X",
        "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r", "Tp0v", "Tp0z",
        "Tp19", "Tp1d", "Tp1f", "Tp1h", "Tp1n", "Tp1p", "Tp1t", "Tp1v",
    ]
    private let gpuTempKeysAS = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0V", "Tg0f", "Tg0j", "Tg1f", "Tg1j"]

    // GPU die sensors power-gate when the GPU goes idle: every Tg** key stops
    // reading at once, so a naive aggregate snaps to nil and the UI flickers
    // between a number and "--". Hold the last good value for a short window to
    // ride over those gaps; after it, report nil honestly (GPU genuinely idle).
    private var lastGPUTemp: Double?
    private var lastGPUTempAt = Date.distantPast
    private let gpuTempHoldWindow: TimeInterval = 8.0

    init() {
        // Try to connect on init
        _ = openSMCConnection()
    }
    
    deinit {
        stopMonitoring()
        closeSMCConnection()
    }
    
    // MARK: - SMC Connection Management
    
    private func openSMCConnection() -> Bool {
        if smcConnection != 0 {
            hasAccess = true
            return true
        }
        
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            lastError = "AppleSMC service not found"
            hasAccess = false
            return false
        }
        
        defer { IOObjectRelease(service) }
        
        let result = IOServiceOpen(service, mach_task_self_, 0, &smcConnection)
        
        if result == kIOReturnSuccess {
            hasAccess = true
            lastError = nil
            return true
        } else {
            let errorString = describeIOReturn(result)
            lastError = "Failed to open SMC connection: \(errorString)"
            hasAccess = false
            return false
        }
    }
    
    private func closeSMCConnection() {
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
    }
    
    private func describeIOReturn(_ result: IOReturn) -> String {
        switch Int32(bitPattern: UInt32(result)) {
        case kIOReturnSuccess: return "Success"
        case kIOReturnError: return "General error"
        case kIOReturnNoMemory: return "No memory"
        case kIOReturnNoResources: return "No resources"
        case kIOReturnBadArgument: return "Bad argument"
        case kIOReturnNotPrivileged: return "Not privileged (needs root)"
        case kIOReturnNotOpen: return "Not open"
        case kIOReturnNotFound: return "Not found"
        case kIOReturnNotReadable: return "Not readable"
        case kIOReturnNotWritable: return "Not writable"
        default: return "Error code: \(result)"
        }
    }
    
    func checkAccess() -> Bool {
        if smcConnection == 0 {
            _ = openSMCConnection()
        }
        return hasAccess
    }
    
    func getDataType(key: String) -> String? {
        // Ensure connection
        if smcConnection == 0 { _ = openSMCConnection() }
        
        let keyCode = fourCharCodeFrom(key)
        
        // Use cached if available
        if let info = keyInfoCache[keyCode] {
            return stringFrom(fourCharCode: info.dataType).trimmingCharacters(in: .whitespaces)
        }
        
        // Otherwise try to fetch it
        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = SMC_CMD_READ_KEYINFO
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        let result = IOConnectCallStructMethod(smcConnection, KERNEL_INDEX_SMC, &input, MemoryLayout<SMCParamStruct>.size, &output, &outputSize)
        
        if result == kIOReturnSuccess && output.result == 0 {
            // Validate dataSize to avoid corrupt/out-of-range values
            let dataSize = output.keyInfo.dataSize
            if dataSize == 0 || dataSize > 32 {
                print("SMC: Invalid dataSize (\(dataSize)) for key \(key)")
                return nil
            }
            keyInfoCache[keyCode] = output.keyInfo
            return stringFrom(fourCharCode: output.keyInfo.dataType).trimmingCharacters(in: .whitespaces)
        }
        
        return nil
    }
    
    // MARK: - Monitoring Control
    
    func startMonitoring() {
        guard openSMCConnection() else {
            print("SMC: Cannot start monitoring - no connection")
            return
        }
        
        stopMonitoring()
        isMonitoring = true
        
        // Initial read
        updateReadings()
        
        // Detect number of fans
        detectFans()
        
        // Start periodic timer
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.monitoringTimer = Timer.scheduledTimer(withTimeInterval: self.monitoringInterval, repeats: true) { [weak self] _ in
                self?.updateReadings()
            }
            RunLoop.current.add(self.monitoringTimer!, forMode: .common)
        }
    }
    
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        isMonitoring = false
    }
    
    // MARK: - Fan Detection
    
    private func detectFans() {
        var count = 0
        for i in 0..<8 {
            let key = String(format: "F%dAc", i)
            if let _ = readSMCValue(key: key) {
                count += 1
            } else {
                break
            }
        }
        
        DispatchQueue.main.async {
            self.numberOfFans = count
            print("SMC: Detected \(count) fan(s)")
        }
    }
    
    // MARK: - Reading Updates
    
    private func updateReadings() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Read temperatures — hottest plausible die sensor, Apple Silicon
            // first then Intel proximity as fallback. Hottest (not first) so a
            // gated ~2°C core never wins over the real cluster temperature.
            var cpuTemp = self.hottestTemperature(self.cpuTempKeysAS)
            if cpuTemp == nil { cpuTemp = self.hottestTemperature(self.cpuTempKeysIntel) }

            var gpuTemp = self.hottestTemperature(self.gpuTempKeysAS)
            if gpuTemp == nil { gpuTemp = self.hottestTemperature(self.gpuTempKeysIntel) }

            // Smooth over brief GPU power-gating so the readout doesn't flicker.
            if let g = gpuTemp {
                self.lastGPUTemp = g
                self.lastGPUTempAt = Date()
            } else if Date().timeIntervalSince(self.lastGPUTempAt) < self.gpuTempHoldWindow {
                gpuTemp = self.lastGPUTemp
            }
            
            // Read fan data
            var speeds: [Int] = []
            var minSpeeds: [Int] = []
            var maxSpeeds: [Int] = []
            
            for i in 0..<self.numberOfFans {
                // F%dAc = Actual speed, F%dMn = Minimum, F%dMx = Maximum
                let actualKey = String(format: "F%dAc", i)
                let minKey = String(format: "F%dMn", i)
                let maxKey = String(format: "F%dMx", i)
                
                if let speed = self.readSMCFanSpeed(key: actualKey) {
                    speeds.append(speed)
                }
                if let min = self.readSMCFanSpeed(key: minKey) {
                    minSpeeds.append(min)
                } else {
                    minSpeeds.append(FanRPMBounds.fallbackMinWhenSMCUnreadable)
                }
                if let max = self.readSMCFanSpeed(key: maxKey) {
                    maxSpeeds.append(max)
                } else {
                    // Placeholder: resolved below using peer fans or `FanRPMBounds`.
                    maxSpeeds.append(-1)
                }
            }

            /// If some `F%dMx` reads failed, reuse the highest successfully read maximum before falling back.
            let positiveMaxima = maxSpeeds.filter { $0 > 0 }
            let peerMax = positiveMaxima.max()
            for i in maxSpeeds.indices where maxSpeeds[i] <= 0 {
                maxSpeeds[i] = peerMax ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
            }
            
            // Fallback for demo mode
            let showDemo = UserDefaults.standard.bool(forKey: "showDemoData")
            if cpuTemp == nil && gpuTemp == nil && speeds.isEmpty && showDemo {
                cpuTemp = 55.0 + Double.random(in: 0...15)
                gpuTemp = 60.0 + Double.random(in: 0...20)
                speeds = [Int.random(in: 1800...3500)]
                minSpeeds = [FanRPMBounds.fallbackMinWhenSMCUnreadable]
                maxSpeeds = [FanRPMBounds.demoMaxRPM]
            }
            
            // Update on main thread (assign only on change to limit publisher churn and downstream SMC writes).
            DispatchQueue.main.async {
                if self.cpuTemperature != cpuTemp { self.cpuTemperature = cpuTemp }
                if self.gpuTemperature != gpuTemp { self.gpuTemperature = gpuTemp }
                if self.fanSpeeds != speeds { self.fanSpeeds = speeds }
                if self.fanMinSpeeds != minSpeeds { self.fanMinSpeeds = minSpeeds }
                if self.fanMaxSpeeds != maxSpeeds { self.fanMaxSpeeds = maxSpeeds }

                if self.numberOfFans == 0 && !speeds.isEmpty {
                    self.numberOfFans = speeds.count
                }
            }
        }
    }
    
    // MARK: - SMC Data Parsing
    
    // Type codes
    private let DATA_TYPE_FLT = fourCharCodeFrom("flt ")
    private let DATA_TYPE_SP78 = fourCharCodeFrom("sp78")
    private let DATA_TYPE_FPE2 = fourCharCodeFrom("fpe2")
    private let DATA_TYPE_UINT8 = fourCharCodeFrom("ui8 ")
    private let DATA_TYPE_UINT16 = fourCharCodeFrom("ui16")
    private let DATA_TYPE_UINT32 = fourCharCodeFrom("ui32")
    private let DATA_TYPE_SINT16 = fourCharCodeFrom("si16")
    
    private func parseSMCBytes(_ bytes: SMCBytes, dataType: UInt32, dataSize: UInt32) -> Double? {
        // Helper to get bytes as array
        let byteArray = [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
            bytes.16, bytes.17, bytes.18, bytes.19, bytes.20, bytes.21, bytes.22, bytes.23,
            bytes.24, bytes.25, bytes.26, bytes.27, bytes.28, bytes.29, bytes.30, bytes.31
        ]
        
        switch dataType {
        case DATA_TYPE_FLT:
            if dataSize == 4 {
                let val = byteArray.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: Float32.self, capacity: 1) { $0.pointee }
                }
                return Double(val)
            }
            
        case DATA_TYPE_SP78:
            if dataSize == 2 {
                // Fixed Point 7.8 (Signed)
                // First bit is sign, next 7 are integer part, last 8 are fractional
                let b0 = Int(byteArray[0])
                let b1 = Int(byteArray[1])
                let val = (b0 << 8) | b1
                return Double(Int16(bitPattern: UInt16(val))) / 256.0
            }
            
        case DATA_TYPE_FPE2:
            if dataSize == 2 {
                // Fixed Point 14.2 (Unsigned)
                // First 14 bits are integer part, last 2 are fractional
                // Calculation: (Byte0 << 6) + (Byte1 >> 2)
                let b0 = Int(byteArray[0])
                let b1 = Int(byteArray[1])
                let val = (b0 << 6) + (b1 >> 2)
                return Double(val)
            }
            
        case DATA_TYPE_UINT8:
            if dataSize == 1 {
                return Double(byteArray[0])
            }
            
        case DATA_TYPE_UINT16:
            if dataSize == 2 {
                let val = (Int(byteArray[0]) << 8) + Int(byteArray[1])
                return Double(val)
            }
            
        case DATA_TYPE_UINT32:
            if dataSize == 4 {
                let val = (UInt32(byteArray[0]) << 24) | (UInt32(byteArray[1]) << 16) | (UInt32(byteArray[2]) << 8) | UInt32(byteArray[3])
                return Double(val)
            }
        
        case DATA_TYPE_SINT16:
            if dataSize == 2 {
                let val = (UInt16(byteArray[0]) << 8) | UInt16(byteArray[1])
                return Double(Int16(bitPattern: val))
            }
            
        default:
            // Check for potential fallback or unknown type
            if dataSize == 2 {
                let val = (Int(byteArray[0]) << 8) + Int(byteArray[1])
                return Double(val)
            }
        }
        
        return nil
    }
    
    // MARK: - SMC Read Operations
    
    // Generic read that handles types automatically
    func readSMCValue(key: String) -> Double? {
        guard smcConnection != 0 else { return nil }
        
        let keyCode = fourCharCodeFrom(key)
        
        // 1. Get Key Info
        var keyInfo: SMCKeyData_keyInfo_t
        if let cached = keyInfoCache[keyCode] {
            keyInfo = cached
        } else {
            var input = SMCParamStruct()
            input.key = keyCode
            input.data8 = SMC_CMD_READ_KEYINFO
            
            var output = SMCParamStruct()
            let inputSize = MemoryLayout<SMCParamStruct>.size
            var outputSize = MemoryLayout<SMCParamStruct>.size
            
            let result = IOConnectCallStructMethod(
                smcConnection,
                KERNEL_INDEX_SMC,
                &input,
                inputSize,
                &output,
                &outputSize
            )
            
            if result != kIOReturnSuccess || output.result != 0 {
                // print("SMC: Key info failed for \(key)")
                return nil
            }
            
            keyInfo = output.keyInfo
            // Validate keyInfo.dataSize
            if keyInfo.dataSize == 0 || keyInfo.dataSize > 32 {
                print("SMC: Invalid keyInfo.dataSize (\(keyInfo.dataSize)) for key \(key)")
                return nil
            }
            keyInfoCache[keyCode] = keyInfo
        }
        
        // 2. Read Data
        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = SMC_CMD_READ_BYTES
        
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.size
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        let result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            inputSize,
            &output,
            &outputSize
        )
        
        if result != kIOReturnSuccess || output.result != 0 {
            return nil
        }
        
        // Validate data size before parsing
        if keyInfo.dataSize == 0 || keyInfo.dataSize > 32 {
            print("SMC: Invalid read size \(keyInfo.dataSize) for key \(key)")
            return nil
        }
        
        // 3. Parse Data
        return parseSMCBytes(output.bytes, dataType: keyInfo.dataType, dataSize: keyInfo.dataSize)
    }

    private func readSMCTemperature(key: String) -> Double? {
        return readSMCValue(key: key)
    }

    /// Hottest plausible sensor across a candidate list. Apple Silicon exposes
    /// many per-core die sensors; gated cores report ~1-2°C, so the `floor`
    /// filters that garbage and we keep the maximum — the hottest active
    /// core/cluster — rather than the first key that happens to parse.
    private func hottestTemperature(_ keys: [String], floor: Double = 10, ceiling: Double = 130) -> Double? {
        var hottest: Double? = nil
        for key in keys {
            if let t = readSMCTemperature(key: key), t > floor, t < ceiling {
                hottest = max(hottest ?? t, t)
            }
        }
        return hottest
    }
    
    private func readSMCFanSpeed(key: String) -> Int? {
        if let val = readSMCValue(key: key) {
            return Int(val)
        }
        return nil
    }
    
    // MARK: - SMC Write Operations
    
    func writeSMCKey(_ key: String, value: Double) -> Bool {
        guard smcConnection != 0 else {
            print("SMC Write: No connection")
            return false
        }
        
        let keyCode = fourCharCodeFrom(key)
        
        // Get key info first
        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = SMC_CMD_READ_KEYINFO
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        var result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        
        guard result == kIOReturnSuccess && output.result == 0 else {
            print("SMC Write: Failed to get key info for \(key)")
            return false
        }
        
        let keyInfo = output.keyInfo
        keyInfoCache[keyCode] = keyInfo
        
        // Prepare write
        input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = SMC_CMD_WRITE_BYTES
        
        // Encode value based on type
        switch keyInfo.dataType {
        case DATA_TYPE_FLT:
            if keyInfo.dataSize == 4 {
                var floatVal = Float32(value)
                withUnsafeBytes(of: &floatVal) { buffer in
                    // SMC expects bytes, usually we write them directly
                    // But we might need to handle endianness? 
                    // Verify: flt on SMC is usually native float? No, usually it's standard IEEE 754
                    // But passing through IOConnectCallStructMethod struct might require specific alignment
                    // Let's assume standard copy
                    if buffer.count >= 4 {
                        input.bytes.0 = buffer[0]
                        input.bytes.1 = buffer[1]
                        input.bytes.2 = buffer[2]
                        input.bytes.3 = buffer[3]
                    }
                }
            } else {
                print("SMC Write: flt type but size is \(keyInfo.dataSize)")
                return false
            }
            
        case DATA_TYPE_FPE2:
            // Fixed Point 14.2 (Unsigned)
            // (UInt8(self >> 6), UInt8((self << 2) ^ ((self >> 6) << 8)))
            let intVal = Int(value)
            input.bytes.0 = UInt8(intVal >> 6)
            input.bytes.1 = UInt8((intVal << 2) & 0xFF) // Simplified from SMCKit logic, verify if needed
            // SMCKit: UInt8((self << 2) ^ ((self >> 6) << 8))
            // Let's use strict SMCKit logic:
            // byte1 = (self << 2) is the lower 6 bits moved up
            // the XOR part seems complex, let's stick to standard 14.2 encoding:
            // High byte: top 8 bits of 14-bit integer
            // Low byte: bottom 6 bits of 14-bit integer << 2
            
            // Re-evaluating SMCKit logic:
            // (self >> 6) is high byte.
            // (self << 2) puts bottom 6 bits into top of low byte
            // ^ ((self >> 6) << 8) -> this part cancels out high bits if they remained?
            // Actually, if we just cast to UInt8, high bits are truncated.
            // So input.bytes.0 = UInt8(intVal >> 6) is correct for high byte.
            // For low byte: (intVal & 0x3F) << 2.
            input.bytes.1 = UInt8((intVal & 0x3F) << 2)
            
        case DATA_TYPE_SP78:
            // Internal 7.8 -> val * 256
            let intVal = Int16(value * 256.0)
            let uintVal = UInt16(bitPattern: intVal)
            input.bytes.0 = UInt8((uintVal >> 8) & 0xFF)
            input.bytes.1 = UInt8(uintVal & 0xFF)
            
        case DATA_TYPE_UINT8:
            input.bytes.0 = UInt8(value)
            
        case DATA_TYPE_UINT16:
            let intVal = UInt16(value)
            input.bytes.0 = UInt8((intVal >> 8) & 0xFF)
            input.bytes.1 = UInt8(intVal & 0xFF)
            
        case DATA_TYPE_UINT32:
            let intVal = UInt32(value)
            input.bytes.0 = UInt8((intVal >> 24) & 0xFF)
            input.bytes.1 = UInt8((intVal >> 16) & 0xFF)
            input.bytes.2 = UInt8((intVal >> 8) & 0xFF)
            input.bytes.3 = UInt8(intVal & 0xFF)
            
        default:
            // Fallback: try as uint16/uint8 based on value
            if keyInfo.dataSize == 1 {
                input.bytes.0 = UInt8(value)
            } else if keyInfo.dataSize == 2 {
                let intVal = UInt16(value)
                input.bytes.0 = UInt8((intVal >> 8) & 0xFF)
                input.bytes.1 = UInt8(intVal & 0xFF)
            } else {
                print("SMC Write: Unknown type \(stringFrom(fourCharCode: keyInfo.dataType))")
                return false
            }
        }
        
        output = SMCParamStruct()
        outputSize = MemoryLayout<SMCParamStruct>.size
        
        result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        
        // Note: result might be kIOReturnNotPrivileged if not root
        if result == kIOReturnSuccess {
            print("SMC Write: Successfully wrote \(key) = \(value)")
            return true
        } else {
            print("SMC Write: Failed to write \(key): \(describeIOReturn(result))")
            return false
        }
    }
    
    // MARK: - Alternative Methods (for Apple Silicon)
    
    func readTemperatureUsingPowermetrics() async -> Double? {
        // powermetrics requires root privileges
        // This is a fallback for Apple Silicon Macs where SMC may not work directly
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["--samplers", "smc", "-n", "1", "-i", "100"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse temperature from powermetrics output
                // Format: "CPU die temperature: XX.XX C"
                let pattern = #"CPU die temperature:\s*([\d.]+)"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range(at: 1), in: output),
                   let temp = Double(output[range]) {
                    return temp
                }
            }
        } catch {
            print("Powermetrics error: \(error)")
        }
        
        return nil
    }
}
