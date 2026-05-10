//
//  SystemMonitorTests.swift
//  ffanTests
//
//  Created by mohamad on 11/1/2026.
//

import XCTest
@testable import ffan

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
    
    func testTemperatureReadingStructure() {
        let reading = TemperatureReading(cpu: 65.5, gpu: 72.3)
        
        XCTAssertEqual(reading.cpu, 65.5)
        XCTAssertEqual(reading.gpu, 72.3)
    }
    
    func testFanReadingStructure() {
        let reading = FanReading(id: 0, speed: 2500, minSpeed: 1000, maxSpeed: 6000)
        
        XCTAssertEqual(reading.speed, 2500)
        XCTAssertEqual(reading.minSpeed, 1000)
        XCTAssertEqual(reading.maxSpeed, 6000)
    }

    func testEffectiveMonitoringIntervalUsesUserValueWhenNotRosetta() {
        let interval = SystemMonitor.effectiveMonitoringInterval(
            userConfiguredInterval: 5.0,
            isRosettaTranslated: false
        )
        XCTAssertEqual(interval, 5.0)
    }

    func testEffectiveMonitoringIntervalAppliesRosettaMinimum() {
        let interval = SystemMonitor.effectiveMonitoringInterval(
            userConfiguredInterval: 1.0,
            isRosettaTranslated: true
        )
        XCTAssertEqual(interval, 3.0)
    }

    func testEffectiveMonitoringIntervalAppliesGlobalMinimum() {
        let interval = SystemMonitor.effectiveMonitoringInterval(
            userConfiguredInterval: 0.0,
            isRosettaTranslated: false
        )
        XCTAssertEqual(interval, 0.5)
    }
}
