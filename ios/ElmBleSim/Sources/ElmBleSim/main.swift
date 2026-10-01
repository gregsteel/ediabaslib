import Foundation
@preconcurrency import CoreBluetooth
import EdiabasKit

// Usage: ElmBleSim [recording.sim] [--name OBDII]
// Advertises a "serial" GATT service (FFE0 / FFE1, the layout of most cheap BLE ELM327 adapters).

setvbuf(stdout, nil, _IONBF, 0)
let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func print(_ s: String) { Swift.print("[\(stampFormatter.string(from: Date()))] \(s)") }
var simPath: String?
var adapterName = "OBDII"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--name", !args.isEmpty { adapterName = args.removeFirst() } else { simPath = a }
}

var simFile: SimFileResponder?
let elm = ElmSimulator()
elm.log = { print($0) }
if let simPath {
    do {
        let file = try SimFileResponder(contentsOf: URL(fileURLWithPath: simPath))
        simFile = file
        elm.responder = { target, payload in
            let r = file.answer(target: target, payload: payload)
            if r == nil { print(String(format: "  (no recorded answer for %02X ", target) + payload.map { String(format: "%02X", $0) }.joined(separator: " ") + ")") }
            return r
        }
        print("Loaded \(file.entryCount) recorded requests from \(simPath)")
    } catch {
        print("Cannot read \(simPath): \(error)")
        exit(1)
    }
} else {
    print("No .sim file given: using the built-in test ECU 0x12 (VIN F190, DID reads, 0x31 routine)")
}

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    let queue = DispatchQueue(label: "ble.sim")
    var manager: CBPeripheralManager!
    let serviceUUID = CBUUID(string: "FFE0")
    let charUUID = CBUUID(string: "FFE1")
    var characteristic: CBMutableCharacteristic!
    var subscriber: CBCentral?
    var pending: [Data] = []

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("Bluetooth state: \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else { return }
        characteristic = CBMutableCharacteristic(
            type: charUUID,
            properties: [.notify, .write, .writeWithoutResponse, .read],
            value: nil,
            permissions: [.readable, .writeable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { print("Add service failed: \(error)"); return }
        startAdvertising()
        print("Advertising as \"\(adapterName)\" - connect from the app. Ctrl-C to stop.")
        // macOS does not always resume advertising after a client disconnects: check regularly
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.manager.state == .poweredOn, !self.manager.isAdvertising else { return }
            print("Not advertising any more - restarting")
            self.startAdvertising()
        }
        timer.resume()
        watchdog = timer
    }

    var watchdog: DispatchSourceTimer?

    func startAdvertising() {
        manager.startAdvertising([CBAdvertisementDataLocalNameKey: adapterName, CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { print("Advertising error: \(error)") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscriber = central
        pending.removeAll()
        elm.reset()
        simFile?.reset()
        print("Client subscribed (max notification size \(central.maximumUpdateValueLength))")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscriber = nil
        pending.removeAll()
        print("Client unsubscribed")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if let v = r.value { try? elm.write([UInt8](v)) }
            peripheral.respond(to: r, withResult: .success)
        }
        flush()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { send() }

    /// Moves everything the ELM simulator produced into the notification queue.
    func flush() {
        var bytes: [UInt8] = []
        while elm.hasData { bytes.append(UInt8(elm.readByte())) }
        guard !bytes.isEmpty, let central = subscriber else { return }
        let mtu = max(20, central.maximumUpdateValueLength)
        var i = 0
        while i < bytes.count {
            pending.append(Data(bytes[i..<min(i + mtu, bytes.count)]))
            i += mtu
        }
        send()
    }

    func send() {
        while let first = pending.first {
            if manager.updateValue(first, for: characteristic, onSubscribedCentrals: nil) {
                pending.removeFirst()
            } else {
                return   // wait for peripheralManagerIsReady
            }
        }
    }
}

let peripheral = Peripheral()
_ = peripheral
dispatchMain()
