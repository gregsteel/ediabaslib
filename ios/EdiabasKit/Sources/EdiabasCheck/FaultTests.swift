import Foundation
@testable import EdiabasKit

/// Fault memory read / clear / read against a recording with two stored faults. Needs a real SGBD set
/// (not part of the repo): set EDIABAS_ECU_DIR or place it in <repo>/SGBD/E60_v74/ecu.
func runFaultTests() -> Bool {
    let ecuDir = ProcessInfo.processInfo.environment["EDIABAS_ECU_DIR"] ?? repoRoot.appendingPathComponent("SGBD/E60_v74/ecu").path
    guard FileManager.default.fileExists(atPath: ecuDir + "/D_MOTOR.grp") else {
        print("Fault memory: skipped (no SGBD set at \(ecuDir))")
        return true
    }
    print("Fault memory over simulated adapter:")
    var ok = true
    func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        print("  \(cond ? "ok  " : "FAIL") \(name)\(cond ? "" : " " + detail())")
        if !cond { ok = false }
    }
    do {
        let sim = ElmSimulator()
        let file = try SimFileResponder(contentsOf: kitRoot.appendingPathComponent("Tests/EdiabasKitTests/Golden/obd_faults.sim"))
        sim.responder = { t, p in file.answer(target: t, payload: p) }
        let ed = Ediabas(ecuPath: ecuDir)
        ed.interface = ElmBmwInterface(transport: sim)
        try ed.resolveSgbdFile("D_MOTOR.grp")

        try ed.executeJob("FS_LESEN")
        let faults = FaultReader.parse(ed.resultSets ?? [])
        check("two faults read", faults.count == 2, "\(faults.count)")
        check("fault codes", faults.map { $0.code } == [11379, 7827], "\(faults.map { $0.code })")
        check("fault text present", faults.first?.location.isEmpty == false)

        try ed.executeJob("FS_LOESCHEN")
        check("clear accepted", FaultReader.isOkay(ed.resultSets ?? []))

        try ed.executeJob("FS_LESEN")
        check("empty after clear", FaultReader.parse(ed.resultSets ?? []).isEmpty)
        try ed.closeAll()
    } catch {
        check("no exception", false, "\(error)")
    }
    return ok
}
