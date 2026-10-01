import XCTest
@testable import EdiabasKit

final class VMTests: XCTestCase {
    static let ecuDir: String = {
        // walk up to the repository root (the folder that contains EdiabasLib/)
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("EdiabasLib").path) {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("EdiabasLib/Test/Ecu").path
    }()

    static let goldenDir: String = {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden").path
    }()

    func testOpcodeTable() throws {
        let url = URL(fileURLWithPath: Self.goldenDir).deletingLastPathComponent().appendingPathComponent("opnames.txt")
        let names = try String(contentsOf: url, encoding: .utf8).split(separator: " ").map(String.init)
        XCTAssertEqual(Ediabas.ocList.map { $0.name }, names)
    }

    static func format(_ sets: [ResultSet]) -> String {
        var out = ""
        for (n, set) in sets.enumerated() {
            out += " SET \(n)\n"
            for key in set.keys.sorted() where key != "JOBSTATUS" {
                let r = set[key]!
                let typeName = "\(r.type)"
                let t = "Type" + typeName.dropFirst(4).uppercased()
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
        let ed = Ediabas(ecuPath: Self.ecuDir)
        try ed.resolveSgbdFile(ecu)
        var out = ""
        for job in jobs {
            let parts = job.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            ed.argString = parts.count > 1 ? parts[1] : ""
            out += "JOB \(parts[0])\n"
            do { try ed.executeJob(parts[0]) } catch let e as EdiabasNetException {
                out += "EXC Error occurred: \(e.code.ediabasName)\n"
                continue
            } catch {
                out += "EXC executeJob\n"
                continue
            }
            out += Self.format(ed.resultSets ?? [])
        }
        return out
    }

    func testCmdTest2MatchesReference() throws {
        let jobsURL = URL(fileURLWithPath: Self.goldenDir).appendingPathComponent("cmd_test2.jobs")
        let jobs = try String(contentsOf: jobsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        let golden = try String(contentsOf: URL(fileURLWithPath: Self.goldenDir).appendingPathComponent("cmd_test2.txt"), encoding: .utf8)
        let actual = try runJobs("cmd_test2", ["INFO"] + jobs)
        let g = golden.split(separator: "\n", omittingEmptySubsequences: false)
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        var diffs: [String] = []
        for i in 0..<max(g.count, a.count) {
            let gl = i < g.count ? String(g[i]) : "<none>"
            let al = i < a.count ? String(a[i]) : "<none>"
            if gl != al { diffs.append("line \(i + 1):\n  ref: \(gl)\n  swf: \(al)") }
            if diffs.count >= 25 { break }
        }
        XCTAssertTrue(diffs.isEmpty, "Differences:\n" + diffs.joined(separator: "\n"))
    }
}
