// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
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
    /// When `obdFuelFraction` arrived — only a current reading may stand in
    /// for the odometer model (`FuelReading.freshest`).
    private(set) var obdFuelReadAt: Date?
    @Published private(set) var status = "Off"
    @Published var scanning = false {
        didSet { scanning ? start() : stop() }
    }

    var obdFuelReading: FuelReading? {
        guard let obdFuelFraction, let obdFuelReadAt else { return nil }
        return FuelReading(fraction: obdFuelFraction, at: obdFuelReadAt)
    }


    /// Threshold for the low-tire chip (AppModel.lowTireWarning).
    static let lowPressurePsi = flows_tags_low_pressure_psi()

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
        // Pressure: UInt32 LE at offset 8, units of 1/1000 kPa. Temperature:
        // SIGNED Int32 LE at offset 12, units of 1/100 °C (sub-freezing temps
        // arrive as two's-complement negatives). A 3–200 psi sanity window
        // (parked trailers run low; semis run 100+), and the position is the
        // name's digit ("TPMS1_..." = front left by kit convention) —
        // rust/flows-core tags_and_replies.rs.
        let bytes = manufacturerData.map { [UInt8]($0) } ?? []
        let buffer = bytes.isEmpty ? [UInt8(0)] : bytes
        let reading = buffer.withUnsafeBufferPointer {
            Array(flows_tags_parse_tpms(name ?? "", name != nil, $0,
                                        Int64(bytes.count), manufacturerData != nil))
        }
        guard reading.count == 2, let name else { return nil }
        return ("Tire \(flows_tags_tpms_position(name).text)", reading[0], reading[1])
    }

    /// ELM327 "41 2F xx" reply → fuel fraction (SAE: A/255).
    nonisolated static func parseFuelReply(_ line: String) -> Double? {
        let fuel = flows_tags_parse_fuel_reply(line)
        return fuel.has ? fuel.value : nil
    }

    // MARK: scanning lifecycle

    private func start() {
        status = "Looking for tire sensors and car plug-ins…"
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
    private var mfiPollTask: Task<Void, Never>?

    private func startMFiIfAvailable() {
        // Reentry guard: the scanning toggle calls start() on every off→on
        // flip — without this, each flip spawned ANOTHER permanent poll loop
        // and orphaned the previous EASession with its streams still open.
        guard mfiSession == nil else { return }
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
            status = "Car plug-in connected (\(accessory.name))"
            // ELM init + fuel poll over the accessory streams. Stored so
            // stop() can actually end it — the Task.isCancelled guard was
            // dead code while nothing held the handle.
            mfiPollTask?.cancel()
            mfiPollTask = Task { [weak self] in
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

    private func stopMFi() {
        mfiPollTask?.cancel()
        mfiPollTask = nil
        if let session = mfiSession {
            session.inputStream?.close()
            session.outputStream?.close()
            session.inputStream?.remove(from: .main, forMode: .default)
            session.outputStream?.remove(from: .main, forMode: .default)
        }
        mfiSession = nil
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
            obdFuelReadAt = Date()
            status = String(format: "Fuel from the car plug-in: %.0f%%", fuel * 100)
        }
    }
    #else
    private func startMFiIfAvailable() {}
    private func stopMFi() {}
    #endif

    private func stop() {
        obdPollTask?.cancel()
        obdPollTask = nil
        stopMFi()
        central?.stopScan()
        if let p = obdPeripheral { central?.cancelPeripheralConnection(p) }
        obdPeripheral = nil
        obdWrite = nil
        central = nil
        obdBuffer = ""
        // Nothing is listening now, so nothing here is current: a kept fuel
        // level froze the range, and kept pressures sat in Settings.
        obdFuelFraction = nil
        obdFuelReadAt = nil
        tirePressuresPsi = [:]
        status = "Off"
    }

    /// The reader went away (engine off at a stop, unplugged, out of range).
    /// Forget it and its last reading: scanning connects only while no reader
    /// is held, so a kept one was never found again, and its last fuel level
    /// stood in for the tank for the rest of the drive.
    private func dropOBDAdapter(_ id: UUID) {
        guard obdPeripheral?.identifier == id else { return }
        obdPollTask?.cancel()
        obdPollTask = nil
        obdPeripheral = nil
        obdWrite = nil
        obdBuffer = ""
        obdFuelFraction = nil
        obdFuelReadAt = nil
        if scanning { status = "Car plug-in disconnected — listening again" }
    }
}

extension VehicleLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.status = "Listening for tire sensors and car plug-ins"
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
                self.tirePressuresPsi[tpms.id] = flows_tags_displayed_psi(tpms.psi)
                return
            }
            // OBD adapters: connect once to the first likely UART device.
            if self.obdPeripheral == nil,
               flows_tags_looks_like_obd_adapter(name ?? "") {
                self.obdPeripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral)
                self.status = "Connecting to \(name ?? "the car plug-in")…"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(Self.uartServices)
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        Task { @MainActor in self.dropOBDAdapter(id) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        Task { @MainActor in self.dropOBDAdapter(id) }
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
                    self.obdFuelReadAt = Date()
                    self.status = String(format: "Fuel from the car plug-in: %.0f%%", fuel * 100)
                }
                self.obdBuffer = ""
            } else if self.obdBuffer.count > 4096 {
                // Device matched the name heuristic but never sends an ELM
                // prompt: without a cap the buffer grows (and the contains
                // scan rescans it) for the whole drive. A real reply fits in
                // well under 4 KB — keep only the tail.
                self.obdBuffer.removeFirst(self.obdBuffer.count - 4096)
            }
        }
    }

    /// ELM327 init + a fuel-level poll every 30 s.
    private func beginOBDPolling(_ peripheral: CBPeripheral) {
        guard obdPollTask == nil else { return }
        status = "Car plug-in connected"
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
