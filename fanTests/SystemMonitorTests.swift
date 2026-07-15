//
//  SystemMonitorTests.swift
//  ffanTests
//
//  Created by mohamad on 11/1/2026.
//

import XCTest
@testable import SoloFan

final class SystemMonitorTests: XCTestCase {
    
    func testSystemMonitorInitialization() {
        let monitor = SystemMonitor()
        
        XCTAssertNotNil(monitor)
        XCTAssertFalse(monitor.isMonitoring)
    }
    
    func testSystemMonitorAccessCheck() {
        let monitor = SystemMonitor()
        
        // This will depend on actual system access
        // In a real test environment, you might mock this
        let hasAccess = monitor.checkAccess()
        
        // Just verify the method doesn't crash
        XCTAssertNotNil(hasAccess)
    }
    
    func testSystemMonitorStartStop() {
        let monitor = SystemMonitor()
        
        XCTAssertFalse(monitor.isMonitoring)
        
        monitor.startMonitoring()
        // Note: In actual implementation, monitoring might start asynchronously
        // This test verifies the method can be called without crashing
        
        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
    }
    
    func testPreferredCPUTemperatureKeyOrderMatchesArchitecture() {
        let monitor = SystemMonitor()
        let keys = monitor.preferredCPUTemperatureKeys()
        
        #if arch(arm64)
        XCTAssertEqual(Array(keys.prefix(6)), ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0b"])
        #else
        XCTAssertEqual(Array(keys.prefix(9)), ["TC0P", "TCXC", "TC0E", "TC0F", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C"])
        #endif
    }
    
    func testTemperatureReadingStructure() {
        let reading = TemperatureReading(cpu: 65.5, gpu: 72.3)
        
        XCTAssertEqual(reading.cpu, 65.5)
        XCTAssertEqual(reading.gpu, 72.3)
    }
    
    func testFanReadingStructure() {
        let reading = FanReading(speed: 2500, minSpeed: 1000, maxSpeed: 6000)
        
        XCTAssertEqual(reading.speed, 2500)
        XCTAssertEqual(reading.minSpeed, 1000)
        XCTAssertEqual(reading.maxSpeed, 6000)
    }
}
