//
//  SystemPulseManager.swift
//  boringNotch
//
//  Lightweight system health monitor for closed-notch alerts.
//

import Combine
import Defaults
import Foundation
import IOKit
import SwiftUI

struct SystemPulseTopProcess: Equatable {
    let name: String
    let cpuPercent: Double

    var displayName: String {
        let fileName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        if fileName.isEmpty { return name }
        return fileName
            .replacingOccurrences(of: " Helper", with: "")
            .replacingOccurrences(of: " (Renderer)", with: "")
    }
}

struct SystemPulseSnapshot: Equatable {
    let fanRPMs: [Int?]
    let temperatureCelsius: Double?
    let thermalState: ProcessInfo.ThermalState
    let topProcess: SystemPulseTopProcess?
    let capturedAt: Date

    var fanRPM: Int? {
        fanRPMs.compactMap { $0 }.max()
    }

    var severity: SystemPulseSeverity {
        if let fanRPM, fanRPM >= 5200 { return .critical }
        if let temperatureCelsius, temperatureCelsius >= 90 { return .critical }
        if topProcess?.cpuPercent ?? 0 >= 250 { return .critical }
        if thermalState == .critical { return .critical }

        if let fanRPM, fanRPM >= 3800 { return .high }
        if let temperatureCelsius, temperatureCelsius >= 78 { return .high }
        if topProcess?.cpuPercent ?? 0 >= 140 { return .high }
        if thermalState == .serious { return .high }

        if let fanRPM, fanRPM >= 2600 { return .medium }
        if let temperatureCelsius, temperatureCelsius >= 68 { return .medium }
        if topProcess?.cpuPercent ?? 0 >= 80 { return .medium }
        if thermalState == .fair { return .medium }

        return .normal
    }

    var shouldShowClosedAlert: Bool {
        severity != .normal
    }

    var primaryMetric: String {
        if let fanRPM {
            return "\(fanRPM) RPM"
        }
        if let temperatureCelsius {
            return "\(Int(temperatureCelsius.rounded()))°C"
        }
        return thermalLabel
    }

    var secondaryMetric: String {
        if let topProcess, topProcess.cpuPercent >= 35 {
            return "\(topProcess.displayName) \(Int(topProcess.cpuPercent.rounded()))%"
        }
        if let temperatureCelsius, fanRPM != nil {
            return "\(Int(temperatureCelsius.rounded()))°C"
        }
        return thermalLabel
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Thermal"
        }
    }
}

enum SystemPulseSeverity: Int, Comparable {
    case normal
    case medium
    case high
    case critical

    static func < (lhs: SystemPulseSeverity, rhs: SystemPulseSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .medium: return "fan"
        case .high: return "flame.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class SystemPulseManager: ObservableObject {
    static let shared = SystemPulseManager()

    @Published private(set) var snapshot = SystemPulseSnapshot(
        fanRPMs: [nil, nil],
        temperatureCelsius: nil,
        thermalState: ProcessInfo.processInfo.thermalState,
        topProcess: nil,
        capturedAt: Date()
    )
    @Published private(set) var sensorStatus: String = "Starting…"

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private let smc = SMCReader()
    private let hidTemperatureReader = HIDTemperatureReader()

    private init() {
        if Defaults[.systemPulseEnabled] {
            start()
        }
    }

    func start() {
        guard timer == nil else { return }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: Defaults[.systemPulseRefreshInterval], repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func restart() {
        stop()
        if Defaults[.systemPulseEnabled] {
            start()
        }
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) { [smc, hidTemperatureReader] in
            let sensors = smc.readSnapshot()
            let hidTemperature = sensors.temperatureCelsius == nil ? hidTemperatureReader.readRepresentativeTemperature() : nil
            let temperature = sensors.temperatureCelsius ?? hidTemperature
            let top = await Self.readTopProcess()
            let status = Self.describeSensorStatus(
                fanRPM: sensors.fanRPM,
                temperature: temperature,
                smcAvailable: sensors.smcAvailable,
                hidTemperatureAvailable: hidTemperature != nil
            )
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.sensorStatus = status
                self.snapshot = SystemPulseSnapshot(
                    fanRPMs: sensors.fanRPMs,
                    temperatureCelsius: temperature,
                    thermalState: ProcessInfo.processInfo.thermalState,
                    topProcess: top,
                    capturedAt: Date()
                )
            }
        }
    }

    private nonisolated static func describeSensorStatus(fanRPM: Int?, temperature: Double?, smcAvailable: Bool, hidTemperatureAvailable: Bool) -> String {
        if fanRPM != nil && temperature != nil { return "SMC sensors active" }
        if hidTemperatureAvailable && fanRPM == nil { return "Temperature via Apple Silicon HID; fan RPM unavailable" }
        if fanRPM != nil { return "Fan speed active; temperature unavailable" }
        if temperature != nil { return "Temperature active; fan speed unavailable" }
        if smcAvailable { return "SMC reachable, but no known fan/temp keys responded" }
        return "SMC unavailable; showing thermal state + top process only"
    }

    private static func readTopProcess() async -> SystemPulseTopProcess? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "%cpu=", "-o", "comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            return output
                .split(separator: "\n")
                .compactMap { line -> SystemPulseTopProcess? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard parts.count == 2, let cpu = Double(parts[0]) else { return nil }
                    let command = String(parts[1])
                    if command.contains("boringNotch") { return nil }
                    return SystemPulseTopProcess(name: command, cpuPercent: cpu)
                }
                .max(by: { $0.cpuPercent < $1.cpuPercent })
        } catch {
            return nil
        }
    }
}

private final class SMCReader {
    private let connection: io_connect_t
    private let available: Bool

    init() {
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"))
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        }
        guard service != 0 else {
            connection = 0
            available = false
            return
        }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)

        connection = conn
        available = result == kIOReturnSuccess
    }

    deinit {
        if available {
            IOServiceClose(connection)
        }
    }

    func readSnapshot() -> (fanRPMs: [Int?], fanRPM: Int?, temperatureCelsius: Double?, smcAvailable: Bool) {
        guard available else { return ([nil, nil], nil, nil, false) }

        let fanRPMs = readFanRPMs()
        let fanRPM = fanRPMs.compactMap { $0 }.max()
        let temperature = readTemperature()
        return (fanRPMs, fanRPM, temperature, true)
    }

    private func readFanRPMs() -> [Int?] {
        let fanCount = Int(readNumber("FNum") ?? 0)
        let candidateKeys: [String]
        if fanCount > 0 {
            candidateKeys = (0..<min(fanCount, 4)).map { "F\($0)Ac" }
        } else {
            candidateKeys = ["F0Ac", "F1Ac"]
        }

        var values = candidateKeys.map { key -> Int? in
            guard let value = readNumber(key), value > 0 else { return nil }
            guard value < 10_000 else { return nil }
            return Int(value.rounded())
        }

        while values.count < 2 {
            values.append(nil)
        }

        return values
    }

    private func readTemperature() -> Double? {
        // Mix of common Intel and Apple Silicon-adjacent SMC temp keys. We use the max
        // valid reading as a coarse “system is hot” signal, not as lab-grade telemetry.
        let keys = [
            "TC0P", "TC0E", "TC0F", "TC0D", "TC1C",
            "TG0P", "TG0D",
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tm0P", "Ts0P"
        ]
        let values = keys.compactMap { readNumber($0) }.filter { $0 > 0 && $0 < 125 }
        return values.max()
    }

    private func readNumber(_ key: String) -> Double? {
        guard let response = readKey(key) else { return nil }
        let bytes = response.bytes
        let dataType = response.dataType.replacingOccurrences(of: "\0", with: "")

        switch dataType {
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let intPart = Int8(bitPattern: bytes[0])
            return Double(intPart) + Double(bytes[1]) / 256.0
        case "flt ", "flt":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw)
        default:
            if bytes.count >= 2 {
                let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                return Double(raw)
            }
            return nil
        }
    }

    private func readKey(_ key: String) -> (dataType: String, bytes: [UInt8])? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key.smcKey
        input.data8 = SMCCommand.readKeyInfo.rawValue

        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let infoResult = withUnsafePointer(to: &input) { inputPtr in
            withUnsafeMutablePointer(to: &output) { outputPtr in
                IOConnectCallStructMethod(
                    connection,
                    UInt32(kSMCUserClientOpen),
                    inputPtr,
                    MemoryLayout<SMCParamStruct>.stride,
                    outputPtr,
                    &outputSize
                )
            }
        }
        guard infoResult == kIOReturnSuccess, output.result == 0 else { return nil }

        input.keyInfo = output.keyInfo
        input.data8 = SMCCommand.readBytes.rawValue
        output = SMCParamStruct()
        outputSize = MemoryLayout<SMCParamStruct>.stride

        let readResult = withUnsafePointer(to: &input) { inputPtr in
            withUnsafeMutablePointer(to: &output) { outputPtr in
                IOConnectCallStructMethod(
                    connection,
                    UInt32(kSMCUserClientOpen),
                    inputPtr,
                    MemoryLayout<SMCParamStruct>.stride,
                    outputPtr,
                    &outputSize
                )
            }
        }
        guard readResult == kIOReturnSuccess, output.result == 0 else { return nil }

        let size = min(Int(input.keyInfo.dataSize), 32)
        return (input.keyInfo.dataType.smcString, Array(output.byteArray.prefix(size)))
    }
}

private let kSMCUserClientOpen = 2

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPowerLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    var byteArray: [UInt8] {
        withUnsafeBytes(of: bytes) { Array($0) }
    }

}

private final class HIDTemperatureReader {
    func readRepresentativeTemperature() -> Double? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue(),
              let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return nil }

        let readings = services.compactMap { service -> (product: String, value: Double)? in
            guard let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  product.hasPrefix("PMU t")
            else { return nil }

            guard let event = IOHIDServiceClientCopyEvent(service, 15, nil, 0)?.takeRetainedValue() else { return nil }
            let value = IOHIDEventGetFloatValue(event, 15 << 16)
            guard value > 0, value < 125 else { return nil }
            return (product, value)
        }

        let dieValues = readings
            .filter { $0.product.localizedCaseInsensitiveContains("tdie") }
            .map(\.value)

        if !dieValues.isEmpty {
            return dieValues.reduce(0, +) / Double(dieValues.count)
        }

        let values = readings.map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ matching: CFDictionary?, _ options: UInt32) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private extension String {
    var smcKey: UInt32 {
        utf8.prefix(4).reduce(UInt32(0)) { result, byte in
            (result << 8) + UInt32(byte)
        }
    }
}

private extension UInt32 {
    var smcString: String {
        let chars = [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }
}
