import Foundation

/// Raw byte pipe to the adapter (BLE GATT serial characteristic pair, a TCP socket or a test double).
public protocol ByteTransport: AnyObject {
    func write(_ data: [UInt8]) throws
    /// Non-blocking: next received byte or -1.
    func readByte() -> Int
    var hasData: Bool { get }
    func close()
}

extension ByteTransport {
    func flushInput() { while readByte() >= 0 {} }
}

func monotonicMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

/// ELM327 "standard transport" CAN layer: converts BMW-FAST telegrams to ISO-TP CAN frames sent with
/// raw hex strings and reassembles the answers (port of EdElmInterface for TransportType.Standard).
public final class ElmCan {
    struct InitEntry {
        let command: String
        let version: Int
        let okResponse: Bool
        init(_ command: String, version: Int = -1, ok: Bool = true) { self.command = command; self.version = version; okResponse = ok }
    }

    static let initCommands: [InitEntry] = [
        InitEntry("ATD"), InitEntry("ATE0"), InitEntry("ATSH6F1"), InitEntry("ATCF600"), InitEntry("ATCM700"),
        InitEntry("ATPBC001"), InitEntry("ATSPB"), InitEntry("ATAT0"), InitEntry("ATSTFF"), InitEntry("ATAL"),
        InitEntry("ATH1"), InitEntry("ATS0"), InitEntry("ATL0"),
        InitEntry("ATCSM0", version: 210), InitEntry("ATCTM5", version: 210), InitEntry("ATJE", version: 130),
    ]

    static let readTimeoutOffset = 1000
    static let commandTimeout = 1500
    static let dataTimeout = 2000
    static let canBlockSize: UInt8 = 3
    static let canSepTime: UInt8 = 0

    private let transport: ByteTransport
    /// Added to every response timeout (adapter/BLE latency reserve). Shorter while probing for ECUs.
    var receiveTimeoutOffset = ElmCan.readTimeoutOffset
    weak var ediabas: Ediabas?
    public var cancelRequested: () -> Bool = { false }

    private var dataMode = false
    private var timeoutMultiplier = 1
    private var canHeader = 0x6F1
    private var currentTimeout = -1
    private var respQueue: [UInt8] = []
    private var receiveStart: Int64 = 0
    public private(set) var streamFailure = false
    public private(set) var deviceDescription = ""

    public init(transport: ByteTransport) { self.transport = transport }

    private func log(_ m: @autoclosure () -> String) { ediabas?.log(.ifh, m()) }

    // MARK: lifecycle

    public func initialize() -> Bool {
        dataMode = false
        timeoutMultiplier = 1
        respQueue.removeAll()
        var first = true
        for entry in Self.initCommands {
            let optional = entry.version >= 0
            if !sendCommand(entry.command, readAnswer: entry.okResponse) {
                if !first {
                    if !optional { return false }
                    log("ELM optional command \(entry.command) failed")
                }
                if first && !optional {
                    if !sendCommand(entry.command, readAnswer: entry.okResponse) { return false }
                }
            } else if entry.command.uppercased() == "ATCTM5" {
                timeoutMultiplier = 5
            }
            if !entry.okResponse {
                if receiveAnswer(Self.commandTimeout).isEmpty { log("ELM no answer") }
            }
            first = false
        }
        log("ELM timeout multiplier: \(timeoutMultiplier)")

        guard sendCommand("AT@1", readAnswer: false) else { log("Sending @1 failed"); return false }
        deviceDescription = Self.trim(receiveAnswer(Self.commandTimeout))
        log("ELM ID: \(deviceDescription)")
        guard sendCommand("AT#1", readAnswer: false) else { log("Sending #1 failed"); return false }
        log("ELM Manufacturer: \(Self.trim(receiveAnswer(Self.commandTimeout)))")
        guard sendCommand("STI", readAnswer: false) else { log("Sending STI failed"); return false }
        let stn = Self.trim(receiveAnswer(Self.commandTimeout))
        if stn.uppercased().contains("STN") {
            log("STN Version: \(stn)")
            guard sendCommand("STIX", readAnswer: false) else { log("Sending STIX failed"); return false }
            _ = receiveAnswer(Self.commandTimeout)
        }
        canHeader = 0x6F1
        currentTimeout = -1
        streamFailure = false
        return true
    }

    public func disconnect() {
        _ = try? leaveDataMode(Self.commandTimeout)
        streamFailure = false
    }

    public func purgeInBuffer() { respQueue.removeAll() }

    // MARK: BMW-FAST telegram interface

    /// Sends one BMW-FAST telegram (header, data and checksum byte) as ISO-TP CAN message.
    func sendTelegram(_ data: [UInt8]) -> Bool {
        guard data.count >= 4 else { return false }
        return canSend(data)
    }

    /// Receives `length` response bytes (ISO-TP answers converted to BMW-FAST telegrams).
    func receive(length: Int, timeout: Int) -> [UInt8]? {
        let timeout = timeout + receiveTimeoutOffset
        receiveStart = monotonicMs()
        while respQueue.count < length {
            if transport.hasData || partialPending {
                canReceiver()
                if respQueue.count >= length { break }
            }
            if monotonicMs() - receiveStart > Int64(timeout) {
                log("*** Receive timeout")
                return nil
            }
            if cancelRequested() { return nil }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let out = Array(respQueue[0..<length])
        respQueue.removeFirst(length)
        return out
    }

    private var partialPending: Bool { false }

    // MARK: ISO-TP sender

    private func canSend(_ req: [UInt8]) -> Bool {
        let target = req[1]
        let source = req[2]
        var dataOffset = 3
        var dataLength = Int(req[0] & 0x3F)
        if dataLength == 0 {
            if req[3] == 0 {
                dataLength = (Int(req[4]) << 8) + Int(req[5])
                dataOffset = 6
            } else {
                dataLength = Int(req[3])
                dataOffset = 4
            }
        }
        if req.count < dataOffset + dataLength { return false }

        let header = 0x600 | Int(source)
        if canHeader != header {
            if !sendCommand("ATSH" + String(format: "%03X", header)) { canHeader = -1; return false }
            canHeader = header
        }
        var frame = [UInt8](repeating: 0, count: 8)
        if dataLength <= 6 {
            log("Send SF")
            frame[0] = target
            frame[1] = UInt8(dataLength)
            for i in 0..<dataLength { frame[2 + i] = req[dataOffset + i] }
            return sendCanTelegram(frame)
        }

        log("Send FF")
        frame[0] = target
        frame[1] = UInt8(0x10 | ((dataLength >> 8) & 0x0F))
        frame[2] = UInt8(truncatingIfNeeded: dataLength)
        var telLen = 5
        for i in 0..<telLen { frame[3 + i] = req[dataOffset + i] }
        dataLength -= telLen
        dataOffset += telLen
        if !sendCanTelegram(frame) { return false }

        var blockSize: UInt8 = 0
        var sepTime: UInt8 = 0
        var waitForFc = true
        var blockCount: UInt8 = 1
        while true {
            if waitForFc {
                log("Wait for FC")
                var wait = false
                repeat {
                    guard let rec = receiveCanTelegram(Self.dataTimeout) else {
                        log("*** FC timeout")
                        return false
                    }
                    if rec.count >= 5, (rec[0] & 0xFF00) == 0x0600, (rec[0] & 0xFF) == Int(target),
                       rec[1] == Int(source), (rec[2] & 0xF0) == 0x30 {
                        let fc = rec[2] & 0x0F
                        switch fc {
                        case 0: wait = false
                        case 1: log("Wait for next FC"); wait = true
                        default: log("*** Invalid FC: \(fc)"); return false
                        }
                        blockSize = UInt8(truncatingIfNeeded: rec[3])
                        sepTime = UInt8(truncatingIfNeeded: rec[4])
                        receiveStart = monotonicMs()
                        log("BS=\(blockSize) ST=\(sepTime)")
                    }
                    if cancelRequested() { return false }
                } while wait
            }
            waitForFc = false
            if blockSize > 0 {
                if blockSize == 1 { waitForFc = true }
                blockSize -= 1
            }
            log("Send CF")
            let expectResponse = waitForFc || dataLength <= 6
            frame = [UInt8](repeating: 0, count: 8)
            frame[0] = target
            frame[1] = UInt8(0x20 | (blockCount & 0x0F))
            telLen = min(dataLength, 6)
            for i in 0..<telLen { frame[2 + i] = req[dataOffset + i] }
            dataLength -= telLen
            dataOffset += telLen
            blockCount &+= 1
            if !sendCanTelegram(frame, expectResponse: expectResponse) { return false }
            if dataLength <= 0 { break }
            if !waitForFc { Thread.sleep(forTimeInterval: Double(max(50, Int(sepTime))) / 1000) }
            if cancelRequested() { return false }
        }
        return true
    }

    // MARK: ISO-TP receiver

    private func canReceiver() {
        var blockCount: UInt8 = 0
        var sourceAddr: UInt8 = 0
        var targetAddr: UInt8 = 0
        var fcCount: UInt8 = 0
        var recLen = 0
        var recData: [UInt8]?

        outer: while true {
            let dataAvailable = transport.hasData
            if recLen == 0 && !dataAvailable { return }

            if let can = receiveCanTelegram(Self.dataTimeout) {
                if can.count >= 3 {
                    let frameType = (can[2] >> 4) & 0x0F
                    if recLen == 0 {
                        sourceAddr = UInt8(truncatingIfNeeded: can[0])
                        targetAddr = UInt8(truncatingIfNeeded: can[1])
                        switch frameType {
                        case 0:
                            log("Rec SF")
                            let telLen = can[2] & 0x0F
                            if telLen > can.count - 3 { log("Invalid length"); continue outer }
                            recData = (0..<telLen).map { UInt8(truncatingIfNeeded: can[3 + $0]) }
                            recLen = telLen
                            receiveStart = monotonicMs()
                        case 1:
                            log("Rec FF")
                            if can.count < 9 { log("Invalid length"); continue outer }
                            let telLen = ((can[2] & 0x0F) << 8) + can[3]
                            var buf = [UInt8](repeating: 0, count: telLen)
                            recLen = 5
                            for i in 0..<min(recLen, telLen) { buf[i] = UInt8(truncatingIfNeeded: can[4 + i]) }
                            recData = buf
                            blockCount = 1
                            var fc = [UInt8](repeating: 0, count: 8)
                            fc[0] = sourceAddr; fc[1] = 0x30; fc[2] = Self.canBlockSize; fc[3] = Self.canSepTime
                            fcCount = Self.canBlockSize
                            if !sendCanTelegram(fc) { return }
                            receiveStart = monotonicMs()
                        default:
                            log("*** Rec invalid frame \(frameType)")
                            continue outer
                        }
                    } else if frameType == 2, recData != nil,
                              Int(sourceAddr) == (can[0] & 0xFF), Int(targetAddr) == can[1] {
                        let bc1 = can[2] & 0x0F
                        let bc2 = Int(blockCount & 0x0F)
                        if bc1 != bc2 { log("Invalid block count: \(bc1) \(bc2)"); continue outer }
                        log("Rec CF")
                        let telLen = min(recData!.count - recLen, 6)
                        if telLen > can.count - 3 { log("Invalid length"); continue outer }
                        for i in 0..<telLen { recData![recLen + i] = UInt8(truncatingIfNeeded: can[3 + i]) }
                        recLen += telLen
                        blockCount &+= 1
                        if fcCount > 0 && recLen < recData!.count {
                            fcCount -= 1
                            if fcCount == 0 {
                                log("(Rec) Send FC")
                                var fc = [UInt8](repeating: 0, count: 8)
                                fc[0] = sourceAddr; fc[1] = 0x30; fc[2] = Self.canBlockSize; fc[3] = Self.canSepTime
                                fcCount = Self.canBlockSize
                                if !sendCanTelegram(fc) { return }
                            }
                        }
                        receiveStart = monotonicMs()
                    }
                    if let d = recData, recLen >= d.count { break outer }
                }
            } else {
                return   // nothing received
            }
            if cancelRequested() { return }
        }

        guard let data = recData, recLen >= data.count else { return }
        log("Received length: \(recLen)")
        var tel: [UInt8]
        if data.count > 0xFF {
            tel = [0x80, targetAddr, sourceAddr, 0x00, UInt8(data.count >> 8), UInt8(truncatingIfNeeded: data.count)] + data
        } else if data.count > 0x3F {
            tel = [0x80, targetAddr, sourceAddr, UInt8(data.count)] + data
        } else {
            tel = [UInt8(0x80 | data.count), targetAddr, sourceAddr] + data
        }
        tel.append(BmwFast.checksum(tel, length: tel.count))
        respQueue.append(contentsOf: tel)
    }

    // MARK: ELM command layer

    @discardableResult
    func sendCommand(_ command: String, readAnswer: Bool = true) -> Bool {
        do {
            if !(try leaveDataMode(Self.commandTimeout)) { dataMode = false; return false }
            transport.flushInput()
            try transport.write(Array((command + "\r").utf8))
            log("ELM CMD send: \(command)")
            if readAnswer {
                let answer = receiveAnswer(Self.commandTimeout)
                if !answer.contains("OK\r") {
                    log("*** ELM invalid response: \(answer)")
                    return false
                }
            }
        } catch {
            log("*** ELM stream failure: \(error)")
            streamFailure = true
            return false
        }
        return true
    }

    func sendCanTelegram(_ can: [UInt8], expectResponse: Bool = true) -> Bool {
        do {
            let timeout = expectResponse ? 0xFF : 0x00
            if timeout == 0 || timeout != currentTimeout {
                if !sendCommand(String(format: "ATST%02X", timeout), readAnswer: false) {
                    log("Setting timeout failed")
                    currentTimeout = -1
                    return false
                }
                let answer = receiveAnswer(Self.commandTimeout)
                if !answer.contains("OK\r") && !answer.contains("STOPPED\r") && !answer.contains("NO DATA\r") && !answer.contains("DATA ERROR\r") {
                    log("*** ELM set timeout invalid response: \(answer)")
                    currentTimeout = -1
                    return false
                }
            }
            currentTimeout = timeout

            if !(try leaveDataMode(Self.commandTimeout)) {
                dataMode = false
                currentTimeout = -1
                return false
            }
            transport.flushInput()
            let hex = can.map { String(format: "%02X", $0) }.joined()
            log("ELM CAN send: \(hex)")
            try transport.write(Array((hex + "\r").utf8))
            dataMode = expectResponse
        } catch {
            log("*** ELM stream failure: \(error)")
            streamFailure = true
            return false
        }
        return true
    }

    /// Returns [canId, data...] or nil.
    func receiveCanTelegram(_ timeout: Int) -> [Int]? {
        guard dataMode else { return nil }
        var answer = receiveAnswer(timeout, canData: true)
        if !dataMode {
            // switch to monitor mode
            if !sendCommand("ATMA", readAnswer: false) { return nil }
            dataMode = true
        }
        if answer.isEmpty { return nil }
        answer = answer.replacingOccurrences(of: " ", with: "")
        if answer.count & 1 == 0 { return nil }
        let chars = Array(answer.utf8)
        guard chars.count >= 3, chars.count <= 19, chars.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        func hexVal(_ s: ArraySlice<UInt8>) -> Int { Int(String(decoding: s, as: UTF8.self), radix: 16) ?? 0 }
        var result = [hexVal(chars[0..<3])]
        var i = 3
        while i + 1 < chars.count + 0 {
            result.append(hexVal(chars[i..<i + 2]))
            i += 2
        }
        return result
    }

    private func leaveDataMode(_ timeout: Int) throws -> Bool {
        if !dataMode { return true }
        var text = ""
        while transport.hasData {
            let b = transport.readByte()
            if b < 0 { break }
            text.append(Self.toChar(b))
            if b == 0x3E {
                log("ELM data mode already terminated: \(text)")
                dataMode = false
                return true
            }
        }
        try transport.write([0x20, 0x20, 0x20, 0x20])
        log("ELM send SPACE")
        let start = monotonicMs()
        while true {
            while transport.hasData {
                let b = transport.readByte()
                if b < 0 { break }
                text.append(Self.toChar(b))
                if b == 0x3E {
                    log(text.contains("STOPPED\r") ? "ELM data mode terminated" : "ELM data mode not stopped: \(text)")
                    dataMode = false
                    return true
                }
            }
            if monotonicMs() - start > Int64(timeout) {
                log("*** ELM leave data mode timeout")
                return false
            }
            if cancelRequested() { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    func receiveAnswer(_ timeout: Int, canData: Bool = false) -> String {
        var text = ""
        let start = monotonicMs()
        while true {
            while transport.hasData {
                let b = transport.readByte()
                if b < 0 { break }
                if b == 0 { continue }
                if canData {
                    if b == 0x0D {
                        log("ELM CAN rec: \(text)")
                        return text
                    }
                    text.append(Self.toChar(b))
                } else {
                    text.append(Self.toChar(b))
                }
                if b == 0x3E {
                    dataMode = false
                    if canData {
                        log("ELM Data mode aborted")
                        return ""
                    }
                    log("ELM CMD rec: \(text)")
                    return text
                }
            }
            if monotonicMs() - start > Int64(timeout) {
                log("ELM rec timeout")
                return ""
            }
            if cancelRequested() { return "" }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    static func toChar(_ b: Int) -> Character { Character(UnicodeScalar(UInt8(truncatingIfNeeded: b))) }

    static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n> "))
    }
}
