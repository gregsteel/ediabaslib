#if canImport(CoreBluetooth)
import Foundation
@preconcurrency import CoreBluetooth

public struct BleDevice: Identifiable, Hashable, @unchecked Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    /// Advertises a GATT service used by known serial BLE OBD adapters.
    public var looksLikeAdapter: Bool
    let peripheral: CBPeripheral

    public static func == (a: BleDevice, b: BleDevice) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public enum BleError: Error, LocalizedError {
    case bluetoothUnavailable(String)
    case connectFailed(String)
    case noSerialService
    case timeout(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let s): return "Bluetooth unavailable: \(s)"
        case .connectFailed(let s): return "Connect failed: \(s)"
        case .noSerialService: return "No serial service found on this device"
        case .timeout(let s): return "Timeout: \(s)"
        case .notConnected: return "Not connected"
        }
    }
}

/// Known BLE "serial port" GATT layouts used by ELM327 / OBD adapters (same table as the Android app).
struct GattSerialProfile {
    let name: String
    let service: CBUUID
    let notify: CBUUID
    let write: CBUUID
}

let knownSerialProfiles: [GattSerialProfile] = [
    GattSerialProfile(name: "FFE0/FFE1", service: CBUUID(string: "FFE0"), notify: CBUUID(string: "FFE1"), write: CBUUID(string: "FFE1")),
    GattSerialProfile(name: "Deep OBD", service: CBUUID(string: "FFE0"), notify: CBUUID(string: "FFE1"), write: CBUUID(string: "FFE2")),
    GattSerialProfile(name: "FFF0/FFF1/FFF2", service: CBUUID(string: "FFF0"), notify: CBUUID(string: "FFF1"), write: CBUUID(string: "FFF2")),
    GattSerialProfile(name: "vLinker", service: CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
                      notify: CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"), write: CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")),
    GattSerialProfile(name: "18F0/2AF0/2AF1", service: CBUUID(string: "18F0"), notify: CBUUID(string: "2AF0"), write: CBUUID(string: "2AF1")),
    GattSerialProfile(name: "ISSC", service: CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
                      notify: CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616"), write: CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")),
]

/// CoreBluetooth central: scans for adapters and opens serial transports.
public final class BleCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var manager: CBCentralManager!
    private let queue = DispatchQueue(label: "ediabas.ble.central")
    private var stateWaiters: [(Result<Void, BleError>) -> Void] = []
    private var connectWaiters: [UUID: (Result<CBPeripheral, BleError>) -> Void] = [:]
    var onDiscover: ((BleDevice) -> Void)?
    public var log: ((String) -> Void)?
    private var transports: [UUID: BleSerialTransport] = [:]

    public override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: state

    public func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.manager.state {
                case .poweredOn: cont.resume()
                case .unknown, .resetting:
                    self.stateWaiters.append { cont.resume(with: $0.mapError { $0 }) }
                case .unauthorized: cont.resume(throwing: BleError.bluetoothUnavailable("permission denied"))
                case .unsupported: cont.resume(throwing: BleError.bluetoothUnavailable("not supported"))
                case .poweredOff: cont.resume(throwing: BleError.bluetoothUnavailable("Bluetooth is off"))
                @unknown default: cont.resume(throwing: BleError.bluetoothUnavailable("unknown state"))
                }
            }
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = stateWaiters
        switch central.state {
        case .poweredOn:
            stateWaiters = []
            waiters.forEach { $0(.success(())) }
        case .unauthorized:
            stateWaiters = []
            waiters.forEach { $0(.failure(.bluetoothUnavailable("permission denied"))) }
        case .unsupported:
            stateWaiters = []
            waiters.forEach { $0(.failure(.bluetoothUnavailable("not supported"))) }
        case .poweredOff:
            stateWaiters = []
            waiters.forEach { $0(.failure(.bluetoothUnavailable("Bluetooth is off"))) }
        default: break
        }
    }

    // MARK: scanning

    public func startScan(_ handler: @escaping (BleDevice) -> Void) {
        queue.async {
            self.onDiscover = handler
            self.manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func stopScan() {
        queue.async {
            self.manager.stopScan()
            self.onDiscover = nil
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let adapter = advertised.contains { uuid in knownSerialProfiles.contains { $0.service == uuid } }
        onDiscover?(BleDevice(id: peripheral.identifier, name: name.isEmpty ? "(unnamed)" : name, rssi: RSSI.intValue,
                              looksLikeAdapter: adapter, peripheral: peripheral))
    }

    // MARK: connecting

    /// Connects and returns a ready serial transport (notifications enabled).
    public func connect(_ device: BleDevice, timeout: TimeInterval = 10) async throws -> BleSerialTransport {
        let peripheral: CBPeripheral = try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.connectWaiters[device.id] = { cont.resume(with: $0.mapError { $0 }) }
                self.manager.connect(device.peripheral, options: nil)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let w = self.connectWaiters.removeValue(forKey: device.id) {
                        self.manager.cancelPeripheralConnection(device.peripheral)
                        w(.failure(.timeout("connecting")))
                    }
                }
            }
        }
        log?("BLE connected to \(device.name), discovering services")
        let transport = BleSerialTransport(peripheral: peripheral, queue: queue, central: self)
        transport.log = log
        queue.async { self.transports[peripheral.identifier] = transport }
        do {
            try await transport.discoverSerialService(timeout: timeout)
        } catch {
            disconnect(transport)
            throw error
        }
        return transport
    }

    func disconnect(_ transport: BleSerialTransport) {
        queue.async {
            self.manager.cancelPeripheralConnection(transport.peripheral)
            self.transports.removeValue(forKey: transport.peripheral.identifier)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?(.success(peripheral))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?(.failure(.connectFailed(error?.localizedDescription ?? "unknown")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log?("BLE disconnected: \(error?.localizedDescription ?? "no error reported")")
        transports[peripheral.identifier]?.handleDisconnect()
    }
}

/// `ByteTransport` over a BLE serial characteristic pair. `write`/`readByte` may be used from any thread.
public final class BleSerialTransport: NSObject, ByteTransport, CBPeripheralDelegate, @unchecked Sendable {
    let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private weak var central: BleCentral?

    private let lock = NSCondition()
    private var rx: [UInt8] = []
    private var rxHead = 0
    private var connected = true
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var writeWithResponse = false
    private var writeReady = true
    private var writeAcked = false
    private var discoverCont: CheckedContinuation<Void, Error>?
    private var pendingServices = 0
    private var notifyEnabled = false
    public private(set) var profileName = ""
    public var log: ((String) -> Void)?
    /// Called (on an arbitrary queue) when the link is lost.
    public var onDisconnect: (() -> Void)?

    init(peripheral: CBPeripheral, queue: DispatchQueue, central: BleCentral) {
        self.peripheral = peripheral
        self.queue = queue
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    // MARK: discovery

    func discoverSerialService(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.discoverCont = cont
                self.peripheral.discoverServices(nil)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let c = self.discoverCont {
                        self.discoverCont = nil
                        c.resume(throwing: BleError.timeout("service discovery"))
                    }
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            finishDiscovery(.failure(BleError.noSerialService))
            return
        }
        log?("BLE services: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        pendingServices = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        let chars = (service.characteristics ?? []).map { "\($0.uuid.uuidString)[\($0.properties.rawValue)]" }
        log?("BLE service \(service.uuid.uuidString) characteristics: " + chars.joined(separator: ", "))
        if pendingServices <= 0 { selectCharacteristics() }
    }

    private func selectCharacteristics() {
        guard discoverCont != nil else { return }
        var chosen: (CBCharacteristic, CBCharacteristic, String)?
        let services = peripheral.services ?? []
        for profile in knownSerialProfiles {
            guard let svc = services.first(where: { $0.uuid == profile.service }),
                  let n = svc.characteristics?.first(where: { $0.uuid == profile.notify }),
                  let w = svc.characteristics?.first(where: { $0.uuid == profile.write }) else { continue }
            chosen = (n, w, profile.name)
            break
        }
        if chosen == nil {
            // generic fallback: first service with a notifying and a writable characteristic
            for svc in services {
                let chars = svc.characteristics ?? []
                guard let n = chars.first(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }) else { continue }
                if let w = chars.first(where: { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }) {
                    chosen = (n, w, "generic \(svc.uuid.uuidString)")
                    break
                }
            }
        }
        guard let (n, w, name) = chosen else {
            finishDiscovery(.failure(BleError.noSerialService))
            return
        }
        notifyChar = n
        writeChar = w
        writeWithResponse = !w.properties.contains(.writeWithoutResponse)
        profileName = name
        log?("BLE using profile \(name): notify \(n.uuid.uuidString), write \(w.uuid.uuidString) (\(writeWithResponse ? "with" : "without") response)")
        peripheral.setNotifyValue(true, for: n)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log?("BLE notification state: \(characteristic.isNotifying) error: \(error?.localizedDescription ?? "none")")
        if let error { finishDiscovery(.failure(BleError.connectFailed(error.localizedDescription))); return }
        if characteristic.uuid == notifyChar?.uuid, characteristic.isNotifying {
            notifyEnabled = true
            finishDiscovery(.success(()))
        }
    }

    private func finishDiscovery(_ result: Result<Void, Error>) {
        guard let c = discoverCont else { return }
        discoverCont = nil
        c.resume(with: result)
    }

    // MARK: data path

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == notifyChar?.uuid, let value = characteristic.value else { return }
        log?("BLE RX \(String(decoding: value.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self))")
        lock.lock()
        rx.append(contentsOf: value)
        lock.broadcast()
        lock.unlock()
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log?("BLE write error: \(error.localizedDescription)") }
        lock.lock()
        writeAcked = true
        lock.broadcast()
        lock.unlock()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        lock.lock()
        writeReady = true
        lock.broadcast()
        lock.unlock()
    }

    func handleDisconnect() {
        lock.lock()
        connected = false
        lock.broadcast()
        lock.unlock()
        onDisconnect?()
    }

    // MARK: ByteTransport

    public var hasData: Bool {
        lock.lock(); defer { lock.unlock() }
        return rxHead < rx.count
    }

    public func readByte() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard rxHead < rx.count else { return -1 }
        let b = rx[rxHead]
        rxHead += 1
        if rxHead > 4096 {
            rx.removeFirst(rxHead)
            rxHead = 0
        }
        return Int(b)
    }

    public func write(_ data: [UInt8]) throws {
        guard let w = writeChar else { throw BleError.notConnected }
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: writeWithResponse ? .withResponse : .withoutResponse))
        var offset = 0
        while offset < data.count {
            let chunk = Data(data[offset..<min(offset + chunkSize, data.count)])
            offset += chunk.count
            log?("BLE TX \(String(decoding: chunk.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self))")
            lock.lock()
            guard connected else { lock.unlock(); throw BleError.notConnected }
            if writeWithResponse {
                writeAcked = false
                lock.unlock()
                queue.async { self.peripheral.writeValue(chunk, for: w, type: .withResponse) }
                lock.lock()
                let deadline = Date().addingTimeInterval(2)
                while !writeAcked && connected {
                    if !lock.wait(until: deadline) { lock.unlock(); throw BleError.timeout("BLE write") }
                }
                lock.unlock()
            } else {
                let deadline = Date().addingTimeInterval(2)
                while !peripheral.canSendWriteWithoutResponse && connected {
                    if !lock.wait(until: min(deadline, Date().addingTimeInterval(0.01))), Date() >= deadline {
                        lock.unlock()
                        throw BleError.timeout("BLE write ready")
                    }
                }
                lock.unlock()
                queue.async { self.peripheral.writeValue(chunk, for: w, type: .withoutResponse) }
            }
        }
    }

    public func close() {
        central?.disconnect(self)
    }
}
#endif
