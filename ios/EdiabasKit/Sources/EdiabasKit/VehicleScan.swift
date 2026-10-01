import Foundation

/// Interface that talks to nobody: it only records which ECU address a job tries to reach.
final class ProbeInterface: EdInterface {
    let interfaceName = "PROBE"
    let interfaceType = "PROBE"
    let bmwFastProtocol = true
    weak var ediabas: Ediabas?
    var commRepeats: UInt32 = 0
    var commParameter: [UInt32] = []
    var commAnswerLen: [Int16] = []
    var connected = true
    var targets: [UInt8] = []

    func interfaceConnect() throws -> Bool { true }
    func interfaceDisconnect() throws -> Bool { true }
    func interfaceReset() throws -> Bool { true }

    func transmitData(_ send: [UInt8]) throws -> [UInt8]? {
        if send.count >= 4 { targets.append(send[1]) }
        try ediabas?.setError(.EDIABAS_IFH_0009)
        return nil
    }
}

public enum EcuMap {
    /// ECU diagnostic address -> group SGBD files (e.g. 0x12 -> ["D_MOTOR.grp"]), found by running every group's
    /// identification job against a recording-only interface. Takes a few seconds for a full SGBD set.
    public static func build(ecuDir: String, progress: ((Int, Int) -> Void)? = nil) -> [UInt8: [String]] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: ecuDir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".grp") }
            .sorted()
        let probe = ProbeInterface()
        let ed = Ediabas(ecuPath: ecuDir)
        ed.interface = probe
        var map: [UInt8: [String]] = [:]
        for (i, f) in files.enumerated() {
            progress?(i, files.count)
            probe.targets = []
            ed.clearGroupMapping()
            _ = try? ed.resolveSgbdFile(f)
            if let t = probe.targets.first, t != 0xFF { map[t, default: []].append(f) }
        }
        try? ed.closeAll()
        progress?(files.count, files.count)
        return map
    }

    /// Address -> abbreviation(s) from the GROBNAME table of the vehicle level SGBDs in the set (e.g. 0x12 -> "DME/DDE").
    public static func ecuNames(ecuDir: String) -> [UInt8: String] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: ecuDir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".prg") }
            .sorted()
        let ed = Ediabas(ecuPath: ecuDir)
        ed.noInitForVJobs = true
        var names: [UInt8: String] = [:]
        for f in files {
            guard let list = try? readGrobname(ed, f) else { continue }
            for (a, n) in list where names[a] == nil { names[a] = n }
        }
        return names
    }

    private static func readGrobname(_ ed: Ediabas, _ file: String) throws -> [(UInt8, String)]? {
        try ed.resolveSgbdFile(file)
        try ed.executeJob("_TABLES")
        guard let lines = try ed.tableLines("GROBNAME"), lines.count > 1 else { return nil }
        let adr = lines[0].firstIndex { $0.uppercased() == "ADR" } ?? 0
        let name = lines[0].firstIndex { $0.uppercased() == "GROBNAME" } ?? 1
        return lines.dropFirst().compactMap { row in
            guard row.count > max(adr, name) else { return nil }
            let v = ediStringToValue(row[adr])
            return v >= 0 && v <= 0xFF ? (UInt8(v), row[name]) : nil
        }
    }
}

public struct EcuScanResult: Identifiable, Sendable {
    public var id: UInt8 { address }
    public let address: UInt8
    public let name: String
    public var group: String
    public var variant: String
    public var faults: [Fault]
    public var error: String?
    public var addressText: String { String(format: "0x%02X", address) }
}

/// Finds the ECUs that answer on the bus and reads their fault memories (the "Errors" page of the Android app).
public final class VehicleScanner {
    private let ediabas: Ediabas
    private let iface: ElmBmwInterface
    private let ecuDir: String
    private let map: [UInt8: [String]]
    private let names: [UInt8: String]

    public init(ediabas: Ediabas, interface: ElmBmwInterface, ecuDir: String, map: [UInt8: [String]], names: [UInt8: String]) {
        self.ediabas = ediabas
        self.iface = interface
        self.ecuDir = ecuDir
        self.map = map
        self.names = names
    }

    /// Group files of an address, best candidates first: D_<abbreviation> matches, then other D_ names, numbered D_ names, G_ / H_.
    static func rankedGroups(address: UInt8, groups: [String], name: String) -> [String] {
        let tokens = name.uppercased().split(separator: "/").map(String.init)
        func rank(_ g: String) -> Int {
            let base = g.uppercased().replacingOccurrences(of: ".GRP", with: "")
            if tokens.contains(where: { base == "D_" + $0 }) { return 0 }
            if base.hasPrefix("D_") {
                let rest = base.dropFirst(2)
                return rest.allSatisfy({ $0.isHexDigit }) && rest.count == 4 ? 3 : 1
            }
            if base.hasPrefix("G_") { return 4 }
            return 5
        }
        return groups.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// Addresses worth probing: the vehicle's ECU list when known, otherwise every address a group file talks to.
    public func candidateAddresses() -> [UInt8] {
        let known = names.keys.filter { map[$0] != nil }
        return (known.isEmpty ? Array(map.keys) : Array(known)).sorted()
    }

    /// Probes all candidate addresses and reads the fault memory of each ECU that answers.
    public func scan(progress: @escaping (Double, String) -> Void, shouldStop: @escaping () -> Bool) -> [EcuScanResult] {
        let addresses = candidateAddresses()
        var present: [UInt8] = []
        for (i, a) in addresses.enumerated() {
            if shouldStop() { return [] }
            progress(0.5 * Double(i) / Double(max(addresses.count, 1)), String(format: "Looking for ECUs… 0x%02X %@", a, names[a] ?? ""))
            if iface.probeEcu(address: a) { present.append(a) }
        }

        var results: [EcuScanResult] = []
        for (i, a) in present.enumerated() {
            if shouldStop() { break }
            let name = names[a] ?? String(format: "ECU 0x%02X", a)
            progress(0.5 + 0.5 * Double(i) / Double(max(present.count, 1)), "Reading \(name)…")
            results.append(readEcu(address: a, name: name))
        }
        progress(1, "Done")
        return results
    }

    private func openGroup(address: UInt8, name: String) -> (group: String, variant: String)? {
        Ediabas.clearSharedData()
        let groups = Self.rankedGroups(address: address, groups: map[address] ?? [], name: name)
        for g in groups.prefix(5) {
            do {
                ediabas.clearGroupMapping()
                try ediabas.resolveSgbdFile(g)
                if ediabas.sgbdFileName.lowercased().hasSuffix(".prg") {
                    let variant = ((ediabas.sgbdFileName as NSString).deletingPathExtension)
                    return (g, variant)
                }
            } catch {
                ediabas.log(.info, "scan: group \(g) failed: \(error)")
                continue
            }
        }
        return nil
    }

    private func readEcu(address: UInt8, name: String) -> EcuScanResult {
        var r = EcuScanResult(address: address, name: name, group: "", variant: "", faults: [], error: nil)
        guard let (group, variant) = openGroup(address: address, name: name) else {
            r.error = "No matching SGBD found"
            return r
        }
        r.group = group
        r.variant = variant
        do {
            ediabas.argString = ""
            ediabas.resultsRequests = ""
            try ediabas.executeJob("FS_LESEN")
            let sets = ediabas.resultSets ?? []
            r.faults = FaultReader.parse(sets)
            if !FaultReader.isOkay(sets) && r.faults.isEmpty { r.error = "The ECU did not report its fault memory" }
        } catch let e as EdiabasNetException {
            r.error = e.code.text
        } catch {
            r.error = "\(error)"
        }
        return r
    }

    /// Clears the fault memory of one ECU found by `scan`.
    public func clear(_ ecu: EcuScanResult) -> Bool {
        do {
            Ediabas.clearSharedData()
            ediabas.clearGroupMapping()
            try ediabas.resolveSgbdFile(ecu.group)
            ediabas.argString = ""
            ediabas.resultsRequests = ""
            try ediabas.executeJob("FS_LOESCHEN")
            return FaultReader.isOkay(ediabas.resultSets ?? [])
        } catch { return false }
    }

    /// Re-reads one ECU (after clearing).
    public func reread(_ ecu: EcuScanResult) -> EcuScanResult {
        readEcu(address: ecu.address, name: ecu.name)
    }
}
