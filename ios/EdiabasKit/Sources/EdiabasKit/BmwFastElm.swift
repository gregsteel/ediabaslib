import Foundation

/// EDIABAS interface for BMW D-CAN / BMW-FAST over an ELM327 compatible adapter
/// (the ELM path of EdInterfaceObd: parameter concepts 0x010F and 0x0110, TransBmwFast).
public final class ElmBmwInterface: EdInterface {
    public let interfaceName = "ELM327"
    public let interfaceType = "ELM"
    public var interfaceVersion: UInt32 { 0x0200 }
    public let bmwFastProtocol = true
    public weak var ediabas: Ediabas? {
        didSet { elm.ediabas = ediabas }
    }

    public var commRepeats: UInt32 = 0
    public var commAnswerLen: [Int16] = BmwFast.defaultCommAnswerLen

    public var commParameter: [UInt32] = [] {
        didSet { applyCommParameter() }
    }

    private let elm: ElmCan
    private let transport: ByteTransport
    public private(set) var connected = false
    private var cancel = false

    // communication parameters
    private var timeoutStd = 0
    private var timeoutTelEnd = 0
    private var regenTime = 0
    private var timeoutNr78 = 0
    private var retryNr78 = 0
    private var checksumByUser = false
    private var checksumNoCheck = false
    private var parametersValid = false

    private var nr78: [UInt8: Int] = [:]
    private var lastResponseTick: Int64 = 0
    private var addRecTimeout = 20

    public init(transport: ByteTransport) {
        self.transport = transport
        elm = ElmCan(transport: transport)
        elm.cancelRequested = { [weak self] in self?.cancel ?? false }
    }

    public var adapterDescription: String { elm.deviceDescription }

    /// Fast presence check used by the vehicle scan: short timeouts, no retries.
    public func probeEcu(address: UInt8) -> Bool {
        guard connected, let ediabas else { return false }
        let saved = (commParameter, elm.receiveTimeoutOffset, commRepeats)
        defer { commParameter = saved.0; elm.receiveTimeoutOffset = saved.1; commRepeats = saved.2 }
        var p = BmwFast.defaultCommParameter
        p[2] = 200      // response timeout
        p[5] = 0        // NR78 retries
        p[6] = 300      // NR78 timeout
        commParameter = p
        elm.receiveTimeoutOffset = 300
        commRepeats = 0
        do {
            let response = try transmitData([0x82, address, 0xF1, 0x1A, 0x80])
            return response != nil
        } catch {
            _ = ediabas
            return false
        }
    }

    private func log(_ m: @autoclosure () -> String) { ediabas?.log(.ifh, m()) }

    // MARK: connection

    public func interfaceConnect() throws -> Bool {
        if connected { return true }
        if !elm.initialize() {
            log("*** ELM init failed")
            try ediabas?.setError(.EDIABAS_IFH_0002)
            return false
        }
        connected = true
        return true
    }

    public func interfaceDisconnect() throws -> Bool {
        if connected { elm.disconnect() }
        connected = false
        return true
    }

    public func interfaceReset() throws -> Bool { true }

    public func transmitCancel(_ cancel: Bool) throws -> Bool {
        self.cancel = cancel
        return true
    }

    // MARK: parameters

    private func applyCommParameter() {
        parametersValid = false
        guard let first = commParameter.first else { return }
        let p = commParameter
        nr78.removeAll()
        switch first {
        case 0x010F:    // BMW-FAST
            guard p.count >= 7 else { try? ediabas?.setError(.EDIABAS_IFH_0041); return }
            if p.count >= 8 {
                checksumByUser = (p[7] & 0x01) == 0
                checksumNoCheck = (p[7] & 0x02) != 0
            } else {
                checksumByUser = false
                checksumNoCheck = false
            }
            timeoutStd = Int(p[2])
            regenTime = Int(p[3])
            timeoutTelEnd = Int(p[4])
            timeoutNr78 = Int(p[6])
            retryNr78 = Int(p[5])
        case 0x0110:    // D-CAN
            guard p.count >= 30 else { try? ediabas?.setError(.EDIABAS_IFH_0041); return }
            checksumByUser = false
            checksumNoCheck = false
            timeoutStd = Int(p[7])
            timeoutTelEnd = 10
            regenTime = Int(p[8])
            timeoutNr78 = Int(p[9])
            retryNr78 = Int(p[10])
        default:
            log("*** Concept not implemented: \(String(format: "%04X", first))")
            try? ediabas?.setError(.EDIABAS_IFH_0014)
            return
        }
        parametersValid = true
    }

    // MARK: transfer

    public func transmitData(_ send: [UInt8]) throws -> [UInt8]? {
        guard let ediabas, parametersValid else {
            try self.ediabas?.setError(.EDIABAS_IFH_0006)
            return nil
        }
        if send.count > 1040 {
            try ediabas.setError(.EDIABAS_IFH_0031)
            return nil
        }
        guard connected else {
            try ediabas.setError(.EDIABAS_IFH_0019)
            return nil
        }

        var retries = commRepeats
        if let rc = ediabas.getConfigProperty("RetryComm"), ediStringToValue(rc) == 0 { retries = 0 }

        var error: EdiabasError = .EDIABAS_ERR_NONE
        var response: [UInt8] = []
        for _ in 0..<Int(retries + 1) {
            (error, response) = transBmwFast(send)
            if error == .EDIABAS_ERR_NONE { return response }
            if error == .EDIABAS_IFH_0003 || error == .EDIABAS_IFH_0011 { break }
            if send.isEmpty { break }
        }
        if error == .EDIABAS_IFH_0011 { error = .EDIABAS_IFH_0010 }
        try ediabas.setError(error)
        return nil
    }

    private func transBmwFast(_ sendData: [UInt8]) -> (EdiabasError, [UInt8]) {
        nr78.removeAll()

        if !sendData.isEmpty {
            guard sendData.count >= 4 else { return (.EDIABAS_IFH_0003, []) }
            var telegram = sendData
            let sendLength = BmwFast.telegramLength(sendData)
            if !checksumByUser {
                if telegram.count <= sendLength { telegram.append(0) }
                telegram[sendLength] = BmwFast.checksum(telegram, length: sendLength)
            }
            let full = Array(telegram[0..<min(telegram.count, sendLength + 1)])
            log("Send \(full.map { String(format: "%02X", $0) }.joined(separator: " "))")

            while monotonicMs() - lastResponseTick < Int64(regenTime) {
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !elm.sendTelegram(full) {
                log("*** Sending failed")
                return (.EDIABAS_IFH_0003, [])
            }
        }

        var receive: [UInt8] = []
        while true {
            let timeout = nr78.isEmpty ? timeoutStd : timeoutNr78
            guard var head = elm.receive(length: 4, timeout: timeout + addRecTimeout) else {
                log("*** No header received")
                return (.EDIABAS_IFH_0009, [])
            }
            if head[0] & 0xC0 != 0x80 {
                log("*** Invalid header")
                elm.purgeInBuffer()
                return (.EDIABAS_IFH_0009, [])
            }
            if head[0] & 0x3F == 0 && head[3] == 0 {
                guard let ext = elm.receive(length: 2, timeout: timeout + addRecTimeout) else {
                    log("*** No length received")
                    return (.EDIABAS_IFH_0009, [])
                }
                head += ext
            }
            let recLength = BmwFast.telegramLength(head, clamp: false)
            let tailLen = recLength - head.count + 1
            var tail: [UInt8] = []
            if tailLen > 0 {
                guard let t = elm.receive(length: tailLen, timeout: timeoutTelEnd + addRecTimeout) else {
                    log("*** No tail received: Length=\(recLength)")
                    return (.EDIABAS_IFH_0009, [])
                }
                tail = t
            }
            receive = head + tail
            if receive.count < recLength + 1 { return (.EDIABAS_IFH_0009, []) }
            log("Resp \(receive.map { String(format: "%02X", $0) }.joined(separator: " "))")
            if !checksumNoCheck {
                if BmwFast.checksum(receive, length: recLength) != receive[recLength] {
                    log("*** Checksum incorrect")
                    elm.purgeInBuffer()
                    return (.EDIABAS_IFH_0009, [])
                }
            }

            var dataLen = Int(receive[0] & 0x3F)
            var dataStart = 3
            if dataLen == 0 {
                dataLen = Int(receive[3])
                dataStart += 1
            }
            if dataLen == 3 && receive[dataStart] == 0x7F && receive[dataStart + 2] == 0x78 {
                nr78Add(receive[2])
            } else {
                nr78.removeValue(forKey: receive[2])
                break
            }
            if nr78.isEmpty { break }
        }

        lastResponseTick = monotonicMs()
        let len = BmwFast.telegramLength(receive) + 1
        return (.EDIABAS_ERR_NONE, Array(receive[0..<min(len, receive.count)]))
    }

    private func nr78Add(_ addr: UInt8) {
        if let r = nr78[addr] {
            nr78.removeValue(forKey: addr)
            let retries = r + 1
            if retries <= retryNr78 {
                log("NR78(\(String(format: "%02X", addr))) count=\(retries)")
                nr78[addr] = retries
            } else {
                log("*** NR78(\(String(format: "%02X", addr))) exceeded")
            }
        } else {
            log("NR78(\(String(format: "%02X", addr))) added")
            nr78[addr] = 0
        }
    }

    public func rawData(_ send: [UInt8]) throws -> [UInt8]? { nil }
}
