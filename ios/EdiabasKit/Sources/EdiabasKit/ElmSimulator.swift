import Foundation

/// One ISO-TP answer of a simulated ECU.
public struct SimEcuAnswer {
    public let source: UInt8
    public let payload: [UInt8]
    public init(source: UInt8, payload: [UInt8]) { self.source = source; self.payload = payload }
}

/// Decides how a simulated ECU answers a request: (target address, payload) -> answers, nil = no answer.
public typealias SimEcuResponder = (_ target: UInt8, _ payload: [UInt8]) -> [SimEcuAnswer]?

/// Replays recorded BMW-FAST traffic from an EDIABAS ".sim" file.
public final class SimFileResponder {
    private var responses: [String: [[UInt8]]] = [:]
    private var counters: [String: Int] = [:]
    public private(set) var requestCount = 0

    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .isoLatin1)
        var section = ""
        var requests: [String: [Int: String]] = [:]
        var answers: [String: [Int: [UInt8]]] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") { section = line.uppercased(); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard let us = key.lastIndex(of: "_"), let idx = Int(key[key.index(after: us)...]) else { continue }
            let base = String(key[..<us])
            if section == "[REQUEST]" {
                requests[base, default: [:]][idx] = value
            } else if section == "[RESPONSE]" {
                let bytes = value.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                if bytes.count == value.split(separator: ",").count { answers[base, default: [:]][idx] = bytes }
            }
        }
        // only exact requests (pure hex bytes) are supported; masked / calculated entries are skipped
        for (base, byIndex) in answers {
            guard requests[base] != nil, base.allSatisfy({ $0.isHexDigit }) else { continue }
            responses[base] = byIndex.keys.sorted().map { byIndex[$0]! }
        }
    }

    public var entryCount: Int { responses.count }

    /// Back to the start of the recording (repeated requests cycle through their answers again).
    public func reset() {
        counters.removeAll()
        requestCount = 0
    }

    public func answer(target: UInt8, payload: [UInt8], tester: UInt8 = 0xF1) -> [SimEcuAnswer]? {
        var tel: [UInt8]
        if payload.count > 0x3F {
            tel = [0x80, target, tester, UInt8(payload.count)] + payload
        } else {
            tel = [UInt8(0x80 | payload.count), target, tester] + payload
        }
        let key = tel.map { String(format: "%02X", $0) }.joined()
        requestCount += 1
        guard let list = responses[key], !list.isEmpty else { return nil }
        let n = counters[key, default: 0]
        counters[key] = n + 1
        let resp = list[min(n, list.count - 1)]
        // response telegram: header, target(tester), source(ecu), data..., checksum
        guard resp.count >= 5 else { return nil }
        var dataLen = Int(resp[0] & 0x3F)
        var start = 3
        if dataLen == 0 { dataLen = Int(resp[3]); start = 4 }
        guard resp.count >= start + dataLen else { return nil }
        return [SimEcuAnswer(source: resp[2], payload: Array(resp[start..<(start + dataLen)]))]
    }
}

/// Minimal ELM327 emulator with simulated ECUs behind it (CAN custom protocol, ISO-TP framing done by the tester).
/// Used for tests and by the Mac BLE simulator so the app can be tried without a car or adapter.
public final class ElmSimulator: ByteTransport {
    public var out: [UInt8] = []
    public var echo = true
    public var inDataMode = false
    public var lineBuf = ""
    public var commands: [String] = []
    public var canFramesSeen: [[UInt8]] = []
    public var log: ((String) -> Void)?

    /// Default ECU: DME at 0x12 with a few canned services (see `testEcu`).
    public var responder: SimEcuResponder = ElmSimulator.testEcu

    private var pendingTarget: UInt8 = 0
    private var pendingRequest: [UInt8] = []
    private var pendingExpected = 0
    private var queuedFrames: [(UInt8, [UInt8])] = []

    public init() {}

    /// Power-cycle: forget all adapter state (called when a new client connects).
    public func reset() {
        out.removeAll()
        echo = true
        inDataMode = false
        lineBuf = ""
        pendingRequest = []
        pendingExpected = 0
        queuedFrames.removeAll()
    }

    public var hasData: Bool { !out.isEmpty }
    public func readByte() -> Int { out.isEmpty ? -1 : Int(out.removeFirst()) }
    public func close() {}

    func emit(_ s: String) { out.append(contentsOf: Array(s.utf8)) }

    public func write(_ data: [UInt8]) throws {
        for b in data {
            if inDataMode {
                // any character aborts the data mode
                inDataMode = false
                emit("STOPPED\r\r>")
                continue
            }
            if b == 0x0D {
                let line = lineBuf
                lineBuf = ""
                handle(line)
            } else {
                lineBuf.append(Character(UnicodeScalar(b)))
            }
        }
    }

    private func handle(_ lineIn: String) {
        let line = lineIn.trimmingCharacters(in: .whitespaces)
        if echo { emit(line + "\r") }
        let upper = line.uppercased()
        if upper.hasPrefix("AT") || upper.hasPrefix("ST") {
            commands.append(upper)
            log?("ELM cmd \(upper)")
            switch upper {
            case "ATE0": echo = false; emit("OK\r\r>")
            case "AT@1": emit("SIMULATED ELM327 v1.5\r\r>")
            case "AT#1", "STI", "STIX": emit("?\r\r>")
            case "ATMA": inDataMode = true
            default: emit("OK\r\r>")
            }
            return
        }
        let chars = Array(upper.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { emit("?\r\r>"); return }
        var bytes: [UInt8] = []
        var i = 0
        while i < chars.count {
            bytes.append(UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) ?? 0)
            i += 2
        }
        canFramesSeen.append(bytes)
        inDataMode = true
        ecuReceive(bytes)
    }

    private func frameLine(source: UInt8, _ data: [UInt8]) {
        var d = data
        while d.count < 8 { d.append(0) }
        emit(String(format: "6%02X", source) + d.map { String(format: "%02X", $0) }.joined() + "\r")
    }

    private func ecuReceive(_ f: [UInt8]) {
        guard f.count >= 2 else { return }
        switch f[1] >> 4 {
        case 0:
            let len = Int(f[1] & 0x0F)
            guard f.count >= 2 + len else { return }
            handleRequest(target: f[0], Array(f[2..<(2 + len)]))
        case 1:
            guard f.count >= 8 else { return }
            pendingTarget = f[0]
            pendingExpected = (Int(f[1] & 0x0F) << 8) + Int(f[2])
            pendingRequest = Array(f[3..<8])
            frameLine(source: f[0], [0xF1, 0x30, 0x00, 0x00])   // flow control: clear to send
        case 2:
            guard f[0] == pendingTarget, f.count >= 3 else { return }
            let take = min(6, pendingExpected - pendingRequest.count, f.count - 2)
            pendingRequest += f[2..<(2 + take)]
            if pendingRequest.count >= pendingExpected { handleRequest(target: pendingTarget, pendingRequest) }
        case 3:
            // flow control from the tester: release the queued consecutive frames
            let blockSize = f.count > 2 ? Int(f[2]) : 0
            let count = blockSize == 0 ? queuedFrames.count : min(blockSize, queuedFrames.count)
            for (src, fr) in queuedFrames.prefix(count) { frameLine(source: src, fr) }
            queuedFrames.removeFirst(count)
        default: break
        }
    }

    private func handleRequest(target: UInt8, _ payload: [UInt8]) {
        log?(String(format: "ECU %02X <- ", target) + payload.map { String(format: "%02X", $0) }.joined(separator: " "))
        guard let answers = responder(target, payload) else { return }
        for a in answers { send(a) }
    }

    private func send(_ a: SimEcuAnswer) {
        let payload = a.payload
        log?(String(format: "ECU %02X -> ", a.source) + payload.map { String(format: "%02X", $0) }.joined(separator: " "))
        if payload.count <= 6 {
            frameLine(source: a.source, [0xF1, UInt8(payload.count)] + payload)
            return
        }
        frameLine(source: a.source, [0xF1, UInt8(0x10 | (payload.count >> 8)), UInt8(payload.count & 0xFF)] + payload[0..<5])
        queuedFrames.removeAll()
        var idx = 5
        var n: UInt8 = 1
        while idx < payload.count {
            queuedFrames.append((a.source, [0xF1, 0x20 | (n & 0x0F)] + Array(payload[idx..<min(idx + 6, payload.count)])))
            idx += 6
            n &+= 1
        }
    }

    /// Built-in test ECU 0x12.
    public static func testEcu(_ target: UInt8, _ req: [UInt8]) -> [SimEcuAnswer]? {
        guard target == 0x12, let first = req.first else { return nil }
        func a(_ p: [UInt8]) -> SimEcuAnswer { SimEcuAnswer(source: 0x12, payload: p) }
        switch first {
        case 0x22 where req.count == 3 && req[1] == 0xF1 && req[2] == 0x90:
            return [a([0x62, 0xF1, 0x90] + Array("WBA1234567890ABCD".utf8))]
        case 0x22 where req.count >= 3:
            return [a([0x62, req[1], req[2], 0x12, 0x34])]
        case 0x2E where req.count >= 3:
            return [a([0x6E, req[1], req[2]])]
        case 0x31 where req.count >= 2:
            return [a([0x7F, 0x31, 0x78]), a([0x71, 0x01] + Array(req[2...]))]
        default:
            return [a([0x7F, first, 0x11])]
        }
    }
}
