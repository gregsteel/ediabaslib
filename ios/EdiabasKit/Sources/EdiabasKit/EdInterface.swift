import Foundation

/// Communication adapter used by the EDIABAS x* opcodes (port of EdInterfaceBase).
///
/// The VM runs synchronously on a worker thread, so adapters are expected to block
/// until the transfer finished (BLE adapters bridge their delegate callbacks with semaphores).
public protocol EdInterface: AnyObject {
    var interfaceName: String { get }
    var interfaceType: String { get }
    var interfaceVersion: UInt32 { get }
    var bmwFastProtocol: Bool { get }
    var connected: Bool { get }

    /// Set by `Ediabas` when the interface is attached.
    var ediabas: Ediabas? { get set }

    var commRepeats: UInt32 { get set }
    var commParameter: [UInt32] { get set }
    var commAnswerLen: [Int16] { get set }

    func interfaceConnect() throws -> Bool
    func interfaceDisconnect() throws -> Bool
    func interfaceReset() throws -> Bool
    func interfaceBoot() throws -> Bool

    func transmitData(_ send: [UInt8]) throws -> [UInt8]?
    func transmitFrequent(_ send: [UInt8]) throws -> Bool
    func receiveFrequent() throws -> [UInt8]?
    func stopFrequent() throws -> Bool
    func rawData(_ send: [UInt8]) throws -> [UInt8]?
    func transmitCancel(_ cancel: Bool) throws -> Bool

    var keyBytes: [UInt8]? { get }
    var state: [UInt8]? { get }
    var loopTest: UInt32 { get }
    /// Battery voltage in 100 mV units, or `Int64.min` when not available.
    var batteryVoltage: Int64 { get }
    var ignitionVoltage: Int64 { get }

    func getPort(_ index: UInt32) -> Int64
    func setPort(_ index: UInt32, _ value: UInt32)
    func setProgramVoltage(_ voltage: UInt32)
    func switchSiRelais(_ time: UInt32)
}

public extension EdInterface {
    var interfaceVersion: UInt32 { 1 }
    var keyBytes: [UInt8]? { nil }
    var state: [UInt8]? { [0, 0] }
    var loopTest: UInt32 { 0 }
    var batteryVoltage: Int64 { Int64.min }
    var ignitionVoltage: Int64 { Int64.min }
    func getPort(_ index: UInt32) -> Int64 { 0 }
    func setPort(_ index: UInt32, _ value: UInt32) {}
    func setProgramVoltage(_ voltage: UInt32) {}
    func switchSiRelais(_ time: UInt32) {}
    func interfaceBoot() throws -> Bool { true }
    func transmitFrequent(_ send: [UInt8]) throws -> Bool { false }
    func receiveFrequent() throws -> [UInt8]? { nil }
    func stopFrequent() throws -> Bool { true }
    func rawData(_ send: [UInt8]) throws -> [UInt8]? { nil }
    func transmitCancel(_ cancel: Bool) throws -> Bool { true }
}

/// BMW-FAST telegram helpers (EdInterfaceBase statics).
public enum BmwFast {
    /// Telegram length without checksum (TelLengthBmwFast). `data` must hold at least the header.
    public static func telegramLength(_ data: [UInt8], clamp: Bool = true) -> Int {
        var tel = Int(data[0] & 0x3F)
        if tel == 0 {
            if data[3] == 0 {
                tel = (Int(data[4]) << 8) + Int(data[5]) + 6
            } else {
                tel = Int(data[3]) + 4
            }
        } else {
            tel += 3
        }
        return clamp ? min(tel, data.count) : tel
    }

    /// Payload length and offset (DataLengthBmwFast); length is -1 when the buffer is too short.
    public static func dataLength(_ data: [UInt8]) -> (length: Int, offset: Int) {
        var offset = 3
        var tel = Int(data[0] & 0x3F)
        if tel == 0 {
            if data[3] == 0 {
                offset = 6
                tel = (Int(data[4]) << 8) + Int(data[5])
            } else {
                offset = 4
                tel = Int(data[3])
            }
        }
        if tel + offset > data.count { return (-1, offset) }
        return (tel, offset)
    }

    public static func checksum(_ data: [UInt8], length: Int) -> UInt8 {
        var sum: UInt8 = 0
        for i in 0..<length { sum = sum &+ data[i] }
        return sum
    }

    public static let defaultCommParameter: [UInt32] = [0x0000010F, 0x0001C200, 0x000004B0, 0x00000014, 0x0000000A, 0x00000002, 0x00001388]
    public static let defaultCommAnswerLen: [Int16] = [0, 0]
}
