import Foundation
@testable import EdiabasKit

func bmwTelegram(target: UInt8, payload: [UInt8]) -> [UInt8] {
    if payload.count > 0x3F {
        return [0x80, target, 0xF1, UInt8(payload.count)] + payload
    }
    return [UInt8(0x80 | payload.count), target, 0xF1] + payload
}

func runElmTests() -> Bool {
    var ok = true
    func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        print("  \(cond ? "ok  " : "FAIL") \(name)\(cond ? "" : " " + detail())")
        if !cond { ok = false }
    }
    print("ELM / BMW-FAST over simulated adapter:")

    let sim = ElmSimulator()
    let ed = Ediabas(ecuPath: "")
    var logLines: [String] = []
    ed.logHandler = { _, m in logLines.append(m) }
    let iface = ElmBmwInterface(transport: sim)
    ed.interface = iface
    iface.commParameter = BmwFast.defaultCommParameter

    do {
        check("connect", try iface.interfaceConnect())
        check("init commands", sim.commands.prefix(3).elementsEqual(["ATD", "ATE0", "ATSH6F1"]), "\(sim.commands)")

        // single frame request, single frame response
        var r = try iface.transmitData(bmwTelegram(target: 0x12, payload: [0x22, 0x10, 0x00]))
        check("SF request/response", r?.dropLast().elementsEqual([0x85, 0xF1, 0x12, 0x62, 0x10, 0x00, 0x12, 0x34]) ?? false, "\(String(describing: r))")
        check("response checksum", r.map { BmwFast.checksum($0, length: $0.count - 1) == $0.last } ?? false)

        // multi-frame response (20 bytes -> FF + CFs and our flow control)
        r = try iface.transmitData(bmwTelegram(target: 0x12, payload: [0x22, 0xF1, 0x90]))
        let vin = r.map { Array($0.dropFirst(6).dropLast()) } ?? []
        check("multi-frame response (VIN)", String(decoding: vin, as: UTF8.self) == "WBA1234567890ABCD", "\(String(describing: r))")
        check("response length byte", r?.first == 0x94 && r?.count == 24, "\(String(describing: r?.first)) \(r?.count ?? 0)")

        // multi-frame request: 12 payload bytes need FF + CF with flow control from the ECU
        r = try iface.transmitData(bmwTelegram(target: 0x12, payload: [0x2E, 0xF1, 0x90] + [UInt8](repeating: 0x55, count: 9)))
        check("multi-frame request", r?.dropLast().elementsEqual([0x83, 0xF1, 0x12, 0x6E, 0xF1, 0x90]) ?? false, "\(String(describing: r))")

        // negative response 0x78 followed by the real answer
        r = try iface.transmitData(bmwTelegram(target: 0x12, payload: [0x31, 0x01, 0xAA]))
        check("NR78 then result", r?.dropLast().elementsEqual([0x83, 0xF1, 0x12, 0x71, 0x01, 0xAA]) ?? false, "\(String(describing: r))")

        // negative response without retry
        r = try iface.transmitData(bmwTelegram(target: 0x12, payload: [0x99]))
        check("negative response passes through", r?.dropLast().elementsEqual([0x83, 0xF1, 0x12, 0x7F, 0x99, 0x11]) ?? false, "\(String(describing: r))")

        check("ATSH6F1 header kept", sim.commands.filter { $0.hasPrefix("ATSH") }.allSatisfy { $0 == "ATSH6F1" })
    } catch {
        check("no exception", false, "\(error)\n" + logLines.suffix(15).joined(separator: "\n"))
    }

    // recorded .sim file replay
    do {
        let url = kitRoot.appendingPathComponent("Tests/EdiabasKitTests/Golden/obd.sim")
        let file = try SimFileResponder(contentsOf: url)
        check("sim file parsed", file.entryCount > 100, "entries=\(file.entryCount)")
        let s3 = ElmSimulator()
        s3.responder = { t, p in file.answer(target: t, payload: p) }
        let e3 = Ediabas(ecuPath: "")
        let i3 = ElmBmwInterface(transport: s3)
        e3.interface = i3
        i3.commParameter = BmwFast.defaultCommParameter
        _ = try i3.interfaceConnect()
        var r = try i3.transmitData([0x83, 0x00, 0xF1, 0x22, 0x20, 0x00])
        check("sim: short answer", r == [0x83, 0xF1, 0x00, 0x62, 0x20, 0x00, 0xF6], "\(String(describing: r))")
        r = try i3.transmitData([0x82, 0x00, 0xF1, 0x1A, 0x80])
        check("sim: multi-frame identification", r?.first == 0x9F && r?.count == 35, "len=\(r?.count ?? 0) first=\(String(describing: r?.first))")
        r = try i3.transmitData([0x83, 0x00, 0xF1, 0x22, 0xEF, 0xE1])
        let r2 = try i3.transmitData([0x83, 0x00, 0xF1, 0x22, 0xEF, 0xE1])
        check("sim: repeated request cycles responses", r != nil && r2 != nil && r! != r2)
    } catch {
        check("sim file replay", false, "\(error)")
    }

    // no ECU answers: expect IFH-0009
    do {
        let sim2 = ElmSimulator()
        let ed2 = Ediabas(ecuPath: "")
        let i2 = ElmBmwInterface(transport: sim2)
        ed2.interface = i2
        var p = BmwFast.defaultCommParameter
        p[2] = 100    // short timeout
        i2.commParameter = p
        _ = try i2.interfaceConnect()
        _ = try i2.transmitData(bmwTelegram(target: 0x40, payload: [0x22, 0x10, 0x00]))
        check("no response is an error", false)
    } catch let e as EdiabasNetException {
        check("no response -> IFH-0009", e.code == .EDIABAS_IFH_0009, "\(e.code)")
    } catch {
        check("no response -> IFH-0009", false, "\(error)")
    }
    return ok
}
