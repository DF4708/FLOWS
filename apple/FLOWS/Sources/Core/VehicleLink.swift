// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreBluetooth
import Foundation
#if canImport(ExternalAccessory)
import ExternalAccessory
#endif

/// The phone's own wireless path to REAL vehicle data — no OEM account
/// needed. Two device families over Bluetooth LE:
///
///  1. **Valve-cap TPMS sensor kits** (the ~$25 4-pack): each cap
///     broadcasts pressure/temperature in its advertisement manufacturer
///     data — no connection required, FLOWS just listens. The de-facto
///     format these kits share: ASCII name "TPMS<n>_XXXXXX", manufacturer
///     data ≥ 16 bytes with pressure as UInt32 little-endian at offset 8
///     (units 1/1000 kPa) and temperature at offset 12 (1/100 °C).
///     `parseTPMSAdvertisement` is pure and pinned by FLOWSTests.
///
///  2. **ELM327-compatible OBD-II adapters** (OBDLink, Veepeak, VGate):
///     BLE UART (service FFF0/FFE0). FLOWS speaks enough ELM327 to read the
///     SAE-standard fuel level PID 01 2F (percent) — real tank level on
///     most 2008+ vehicles. (Tire pressure over OBD is OEM-specific mode 22
///     — the TPMS caps above are the universal wireless answer.)
///
/// Everything feeds `VehicleStore.telemetry`: real fuel silences the gauge
/// check-ins automatically; low tire pressure raises a HUD chip.
@MainActor
final class VehicleLink: NSObject, ObservableObject {
    /// Latest tire pressures (psi), sensor id → psi.
    @Published private(set) var tirePressuresPsi: [String: Double] = [:]
    /// Latest OBD fuel level 0…1 (SAE PID 01 2F).
    @Published private(set) var obdFuelFraction: Double?
    @Published private(set) var status = "Off"
    @Published var scanning = false {
        didSet { scanning ? start() : stop() }
    }

    /// Threshold for the low-tire chip.
    static let lowPressurePsi = 28.0

    var lowTires: [String] {
        tirePressuresPsi.filter { $0.value < Self.lowPressurePsi }.map(\.key).sorted()
    }

    private var central: CBCentralManager?
    private var obdPeripheral: CBPeripheral?
    private var obdWrite: CBCharacteristic?
    private var obdBuffer = ""
    private var obdPollTask: Task<Void, Never>?

    // Immutable UUID list read from nonisolated CoreBluetooth delegates.
    nonisolated(unsafe) private static let uartServices =
        [CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "18F0")]

    // MARK: pure TPMS advertisement parsing (tested)

    /// Returns (sensorId, psi, celsius) for a TPMS valve-cap advertisement,
    /// nil when the frame doesn't match the family's format.
    nonisolated static func parseTPMSAdvertisement(
        name: String?, manufacturerData: Data?
    ) -> (id: String, psi: Double, celsius: Double)? {
        guard let name, name.uppercased().hasPrefix("TPMS"),
              let data = manufacturerData, data.count >= 16 else { return nil }
        // Pressure: UInt32 LE at offset 8, units of 1/1000 kPa. Temperature:
        // SIGNED Int32 LE at offset 12, units of 1/100 °C (these kits report
        // sub-freezing temps as two's-complement negatives). loadUnaligned
        // because a Data slice's backing buffer isn't guaranteed 4-byte aligned
        // — plain `load(as:)` can trap on a misaligned advertisement.
        let rawP = data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let rawT = data.subdata(in: 12..<16).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let kPa = Double(UInt32(littleEndian: rawP)) / 1000
        let celsius = Double(Int32(littleEndian: rawT)) / 100
        let psi = kPa * 0.145038
        // Sanity window: 3–200 psi (parked trailers run low; semis run 100+).
        guard psi > 3, psi < 200 else { return nil }
        // Sensor position from the name's digit ("TPMS1_..." = front left
        // by kit convention).
        let position = name.dropFirst(4).first.map(String.init) ?? "?"
        return ("Tire \(position)", psi, celsius)
    }

    /// ELM327 "41 2F xx" reply → fuel fraction (SAE: A/255).
    nonisolated static func parseFuelReply(_ line: String) -> Double? {
        let hex = line.uppercased().replacingOccurrences(of: " ", with: "")
        guard let range = hex.range(of: "412F"), hex.distance(
            from: range.upperBound, to: hex.endIndex) >= 2 else { return nil }
        let byte = hex[range.upperBound..<hex.index(range.upperBound, offsetBy: 2)]
        guard let a = UInt8(byte, radix: 16) else { return nil }
        return Double(a) / 255
    }

    // MARK: scanning lifecycle

    private func start() {
        status = "Scanning for TPMS caps + OBD adapters…"
        central = CBCentralManager(delegate: self, queue: .main)
        startMFiIfAvailable()
    }

    // MARK: MFi (Apple ExternalAccessory) — wired/licensed adapters
    // (OBDLink MX+ class). Available on iOS when the accessory declares an
    // MFi protocol; requires UISupportedExternalAccessoryProtocols (set in
    // Info.plist). Same ELM327 conversation, different transport.
    #if canImport(ExternalAccessory) && os(iOS)
    static let mfiProtocols = ["com.scantool.stn", "com.obdlink.obd"]
    private var mfiSession: EASession?

    private func startMFiIfAvailable() {
        for accessory in EAAccessoryManager.shared().connectedAccessories {
            guard let proto = accessory.protocolStrings.first(
                where: { Self.mfiProtocols.contains($0) }) else { continue }
            guard let session = EASession(accessory: accessory, forProtocol: proto),
                  let output = session.outputStream,
                  let input = session.inputStream else { continue }
            output.schedule(in: .main, forMode: .default)
            input.schedule(in: .main, forMode: .default)
            output.open()
            input.open()
            mfiSession = session
            status = "MFi OBD adapter connected (\(accessory.name))"
            // ELM init + fuel poll over the accessory streams.
            Task { [weak self] in
                for cmd in ["ATZ", "ATE0", "ATSP0"] {
                    self?.mfiWrite(cmd)
                    try? await Task.sleep(for: .seconds(1))
                }
                while !Task.isCancelled, self?.mfiSession != nil {
                    self?.mfiWrite("012F")
                    try? await Task.sleep(for: .seconds(5))
                    self?.mfiReadFuel()
                    try? await Task.sleep(for: .seconds(25))
                }
            }
            return
        }
    }

    private func mfiWrite(_ command: String) {
        guard let out = mfiSession?.outputStream,
              let data = (command + "\r").data(using: .ascii) else { return }
        _ = data.withUnsafeBytes {
            out.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
    }

    private func mfiReadFuel() {
        guard let input = mfiSession?.inputStream, input.hasBytesAvailable else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = input.read(&buffer, maxLength: buffer.count)
        guard n > 0, let text = String(bytes: buffer[0..<n], encoding: .ascii) else { return }
        if let fuel = Self.parseFuelReply(text) {
            obdFuelFraction = fuel
            status = String(format: "MFi OBD fuel: %.0f%%", fuel * 100)
        }
    }
    #else
    private func startMFiIfAvailable() {}
    #endif

    private func stop() {
        obdPollTask?.cancel()
        obdPollTask = nil
        central?.stopScan()
        if let p = obdPeripheral { central?.cancelPeripheralConnection(p) }
        obdPeripheral = nil
        central = nil
        status = "Off"
    }
}

extension VehicleLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.status = "Listening (TPMS broadcasts + OBD adapters)"
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            case .unauthorized:
                self.status = "Bluetooth permission denied — enable in Settings"
            case .poweredOff:
                self.status = "Bluetooth is off"
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        Task { @MainActor in
            // TPMS caps: parse straight from the advertisement.
            if let tpms = Self.parseTPMSAdvertisement(name: name, manufacturerData: mfg) {
                self.tirePressuresPsi[tpms.id] = (tpms.psi * 10).rounded() / 10
                return
            }
            // OBD adapters: connect once to the first likely UART device.
            let lower = (name ?? "").lowercased()
            if self.obdPeripheral == nil,
               lower.contains("obd") || lower.contains("vlink")
                || lower.contains("veepeak") || lower.contains("elm") {
                self.obdPeripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral)
                self.status = "Connecting to \(name ?? "OBD adapter")…"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(Self.uartServices)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for ch in service.characteristics ?? [] {
            if ch.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: ch)
            }
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                Task { @MainActor in
                    self.obdWrite = ch
                    self.beginOBDPolling(peripheral)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value,
              let chunk = String(data: data, encoding: .ascii) else { return }
        Task { @MainActor in
            self.obdBuffer += chunk
            if self.obdBuffer.contains(">") {   // ELM327 prompt = reply complete
                if let fuel = Self.parseFuelReply(self.obdBuffer) {
                    self.obdFuelFraction = fuel
                    self.status = String(format: "OBD fuel: %.0f%%", fuel * 100)
                }
                self.obdBuffer = ""
            }
        }
    }

    /// ELM327 init + a fuel-level poll every 30 s.
    private func beginOBDPolling(_ peripheral: CBPeripheral) {
        guard obdPollTask == nil else { return }
        status = "OBD adapter connected"
        obdPollTask = Task { [weak self] in
            let setup = ["ATZ", "ATE0", "ATSP0"]
            for cmd in setup {
                self?.sendOBD(cmd, to: peripheral)   // @MainActor-inherited: no hop
                try? await Task.sleep(for: .seconds(1))
            }
            while !Task.isCancelled {
                self?.sendOBD("012F", to: peripheral)   // SAE fuel level
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func sendOBD(_ command: String, to peripheral: CBPeripheral) {
        guard let ch = obdWrite, let data = (command + "\r").data(using: .ascii) else { return }
        let kind: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: ch, type: kind)
    }
}
