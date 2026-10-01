import Foundation
@testable import EdiabasKit

// Replays the BEST/2 instruction tests on the Swift VM and diffs against output captured from the C# EdiabasLib.
let ecuDir = repoRoot.appendingPathComponent("EdiabasLib/Test/Ecu").path
let goldenDir = kitRoot.appendingPathComponent("Tests/EdiabasKitTests/Golden")

func format(_ sets: [ResultSet]) -> String {
    var out = ""
    for (n, set) in sets.enumerated() {
        out += " SET \(n)\n"
        for key in set.keys.sorted() where key != "JOBSTATUS" {
            let r = set[key]!
            let t = "Type" + "\(r.type)".dropFirst(4).uppercased()
            let v: String
            switch r.value {
            case .int(let i): v = "\(i)"
            case .double(let d): v = dotNetDouble(d)
            case .string(let s): v = s
            case .bytes(let b): v = b.map { String(format: "%02X", $0) }.joined(separator: "-")
            }
            out += "  \(key) [\(t)] = \(v)\n"
        }
    }
    return out
}

func runJobs(_ ecu: String, _ jobs: [String]) throws -> String {
    let ed = Ediabas(ecuPath: ecuDir)
    try ed.resolveSgbdFile(ecu)
    var out = ""
    for job in jobs {
        out += "JOB \(job)\n"
        ed.argString = ""
        do { try ed.executeJob(job) } catch let e as EdiabasNetException {
            out += "EXC Error occurred: \(e.code.ediabasName)\n"
            continue
        } catch {
            out += "EXC executeJob\n"
            continue
        }
        out += format(ed.resultSets ?? [])
    }
    return out
}

// CLI mode: EdiabasCheck scan <ecuDir> <recording.sim>   (vehicle scan against a recording)
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "scan" {
    let dir = CommandLine.arguments[2]
    let file = try SimFileResponder(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let sim = ElmSimulator()
    sim.responder = { t, p in file.answer(target: t, payload: p) }
    let ed = Ediabas(ecuPath: dir)
    if ProcessInfo.processInfo.environment["SCAN_DEBUG"] != nil {
        ed.setConfigProperty("BipDebugLevel", "3")
        ed.logHandler = { _, m in if m.hasPrefix("scan:") || m.hasPrefix("executeJob") || m.contains("***") || m.hasPrefix("SetError") { print("  LOG", m) } }
    }
    let iface = ElmBmwInterface(transport: sim)
    ed.interface = iface
    let t0 = Date()
    let map = EcuMap.build(ecuDir: dir)
    let names = EcuMap.ecuNames(ecuDir: dir)
    print(String(format: "maps ready in %.1f s", Date().timeIntervalSince(t0)))
    _ = try iface.interfaceConnect()
    let scanner = VehicleScanner(ediabas: ed, interface: iface, ecuDir: dir, map: map, names: names)
    var last = ""
    let results = scanner.scan(progress: { f, m in if m != last && !m.hasPrefix("Looking") { print(String(format: "%3.0f%% %@", f * 100, m)); last = m } }, shouldStop: { false })
    print(String(format: "scan finished in %.1f s, %d ECUs", Date().timeIntervalSince(t0), results.count))
    for r in results {
        print("\(r.addressText) \(r.name) group=\(r.group) variant=\(r.variant) faults=\(r.faults.count) \(r.error ?? "")")
        for f in r.faults { print("     \(f.codeText) \(f.location)") }
    }
    exit(0)
}

// CLI mode: EdiabasCheck ecumap <ecuDir>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "ecumap" {
    let t0 = Date()
    let map = EcuMap.build(ecuDir: CommandLine.arguments[2])
    print("group map: \(map.count) addresses in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    let names = EcuMap.ecuNames(ecuDir: CommandLine.arguments[2])
    print("names: \(names.count) addresses")
    for a in map.keys.sorted() { print(String(format: "0x%02X", a), names[a] ?? "?", map[a]!.joined(separator: ", ")) }
    exit(0)
}

// CLI mode: EdiabasCheck tables <ecuDir> <sgbd> [table]  (list tables, or dump one; no adapter needed)
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "tables" {
    let ed = Ediabas(ecuPath: CommandLine.arguments[2])
    ed.noInitForVJobs = true
    do {
        if CommandLine.arguments[3].lowercased().hasSuffix(".grp") { ed.sgbdFileName = CommandLine.arguments[3] }
        else { try ed.resolveSgbdFile(CommandLine.arguments[3]) }
        if CommandLine.arguments.count > 4 {
            try ed.executeJob("_TABLES")   // opens the file
            for line in try ed.tableLines(CommandLine.arguments[4]) ?? [] { print(line.joined(separator: " | ")) }
        } else {
            try ed.executeJob("_TABLES")
            for set in (ed.resultSets ?? []).dropFirst() { print(set["TABLE"]?.value.asString ?? "") }
        }
    } catch { print("ERROR:", error) }
    exit(0)
}

// CLI mode: EdiabasCheck simrun <ecuDir> <sgbd> <job> <recording.sim> [args]  (full stack against a replayed recording)
if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "simrun" {
    let ed = Ediabas(ecuPath: CommandLine.arguments[2])
    ed.setConfigProperty("BipDebugLevel", "3")
    ed.logHandler = { _, m in print("LOG", m) }
    do {
        let file = try SimFileResponder(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5]))
        let sim = ElmSimulator()
        sim.responder = { t, p in
            let r = file.answer(target: t, payload: p)
            if r == nil { print("MISS", String(format: "%02X", t), p.map { String(format: "%02X", $0) }.joined(separator: " ")) }
            return r
        }
        ed.interface = ElmBmwInterface(transport: sim)
        try ed.resolveSgbdFile(CommandLine.arguments[3])
        ed.argString = CommandLine.arguments.count > 6 ? CommandLine.arguments[6] : ""
        try ed.executeJob(CommandLine.arguments[4])
        print(format(ed.resultSets ?? []))
        try ed.closeAll()
    } catch { print("ERROR:", error) }
    exit(0)
}

// CLI mode: EdiabasCheck run <ecuDir> <sgbd> <job> [args]  (no adapter, jobs that need no communication)
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "run" {
    let ed = Ediabas(ecuPath: CommandLine.arguments[2])
    ed.setConfigProperty("BipDebugLevel", "3")
    ed.logHandler = { _, m in print("LOG", m) }
    do {
        try ed.resolveSgbdFile(CommandLine.arguments[3])
        ed.argString = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : ""
        try ed.executeJob(CommandLine.arguments[4])
        print(format(ed.resultSets ?? []))
    } catch { print("ERROR:", error) }
    exit(0)
}

var failed = false

let names = try String(contentsOf: goldenDir.deletingLastPathComponent().appendingPathComponent("opnames.txt"), encoding: .utf8)
    .split(separator: " ").map(String.init)
if Ediabas.ocList.map({ $0.name }) == names { print("opcode table: OK (\(names.count))") } else { print("opcode table: MISMATCH"); failed = true }

let jobs = try String(contentsOf: goldenDir.appendingPathComponent("cmd_test2.jobs"), encoding: .utf8).split(separator: "\n").map(String.init)
let golden = try String(contentsOf: goldenDir.appendingPathComponent("cmd_test2.txt"), encoding: .utf8)
let actual = try runJobs("cmd_test2", ["INFO"] + jobs)
let g = golden.split(separator: "\n", omittingEmptySubsequences: false)
let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
var diffs = 0
for i in 0..<max(g.count, a.count) {
    let gl = i < g.count ? String(g[i]) : "<none>"
    let al = i < a.count ? String(a[i]) : "<none>"
    if gl != al {
        diffs += 1
        if diffs <= 30 { print("line \(i + 1):\n  ref: \(gl)\n  swf: \(al)") }
    }
}
print("cmd_test2: \(diffs == 0 ? "OK" : "\(diffs) differing lines") (\(g.count) lines)")
if diffs != 0 { failed = true }
if !runElmTests() { failed = true }
if !runFaultTests() { failed = true }
exit(failed ? 1 : 0)
