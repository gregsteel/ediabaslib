import Foundation
import SwiftUI
import EdiabasKit

public struct JobEntry: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public var comment: String
}

public struct ResultRow: Identifiable {
    public let id = UUID()
    public let name: String
    public let type: String
    public let text: String
}

public struct ResultSection: Identifiable {
    public let id = UUID()
    public let title: String
    public let rows: [ResultRow]
}

public enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting(String)
    case connected(String)
}

private final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Owns the BLE link, the EDIABAS engine and the worker queue that runs jobs.
@MainActor
public final class DiagnosticSession: ObservableObject {
    @Published public var devices: [BleDevice] = []
    @Published public var state: ConnectionState = .disconnected
    @Published public var ecuFolder: URL?
    @Published public var sgbdFiles: [String] = []
    @Published public var selectedSgbd: String?
    @Published public var jobs: [JobEntry] = []
    @Published public var sections: [ResultSection] = []
    @Published public var busy = false
    @Published public var errorMessage: String?
    @Published public var logText = ""
    @Published public var traceEnabled = true
    @Published public var showSystemResults = false

    public let translator = TranslationStore()

    // recently used tools (SGBD names), most recent first
    @Published public var recentSgbd: [String] = []

    private func noteRecent(_ name: String) {
        var list = recentSgbd.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        list.insert(name, at: 0)
        recentSgbd = Array(list.prefix(8))
        UserDefaults.standard.set(recentSgbd, forKey: recentKey)
    }

    private var central: BleCentral?
    private var transport: BleSerialTransport?
    private var iface: ElmBmwInterface?
    private var ediabas: Ediabas?
    private let worker = DispatchQueue(label: "ediabas.worker", qos: .userInitiated)
    private let abort = AbortFlag()
    private var scopedURL: URL?
    private var logBuffer: [String] = []
    private var logFlushScheduled = false

    public init() {
        loadProfiles()
    }

    // MARK: log

    nonisolated private func appendLog(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logBuffer.append(line)
            if self.logBuffer.count > 4000 { self.logBuffer.removeFirst(1000) }
            if !self.logFlushScheduled {
                self.logFlushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.logFlushScheduled = false
                    self.logText = self.logBuffer.joined(separator: "\n")
                }
            }
        }
    }

    public func clearLog() {
        logBuffer.removeAll()
        logText = ""
    }

    // MARK: ECU sets (named SGBD folders)

    public struct EcuProfile: Codable, Identifiable, Equatable {
        public var id = UUID()
        public var name: String
        var bookmark: Data
    }

    @Published public var profiles: [EcuProfile] = []
    @Published public var activeProfileID: UUID?

    private static let profilesKey = "ecuProfiles"
    private static let activeKey = "ecuActiveProfile"
    private static let legacyBookmarkKey = "ecuFolderBookmark"

    public var activeProfile: EcuProfile? { profiles.first { $0.id == activeProfileID } }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Self.profilesKey) }
        UserDefaults.standard.set(activeProfileID?.uuidString, forKey: Self.activeKey)
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let list = try? JSONDecoder().decode([EcuProfile].self, from: data) {
            profiles = list
        }
        // migrate the single folder of earlier versions
        if profiles.isEmpty, let legacy = UserDefaults.standard.data(forKey: Self.legacyBookmarkKey),
           let url = Self.resolve(legacy)?.url {
            profiles = [EcuProfile(name: url.lastPathComponent, bookmark: legacy)]
            UserDefaults.standard.removeObject(forKey: Self.legacyBookmarkKey)
        }
        if let id = UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:)),
           profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        } else {
            activeProfileID = profiles.first?.id
        }
        saveProfiles()
        if let p = activeProfile { activate(p, clearTool: false) }
        recentSgbd = loadRecents()
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        #if os(iOS)
        let options: URL.BookmarkResolutionOptions = []
        #else
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Adds a folder as a new named ECU set and makes it the active one.
    public func addProfile(url: URL, name: String) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? url.bookmarkData() else {
            errorMessage = "Cannot remember that folder."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = EcuProfile(name: trimmed.isEmpty ? url.lastPathComponent : trimmed, bookmark: data)
        profiles.append(profile)
        saveProfiles()
        activate(profile)
    }

    public func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = trimmed
        saveProfiles()
    }

    public func deleteProfile(_ id: UUID) {
        guard !busy else { return }
        let wasActive = id == activeProfileID
        profiles.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: "recentSgbd." + id.uuidString)
        if wasActive {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            ecuFolder = nil
            sgbdFiles = []
            jobs = []
            selectedSgbd = nil
            activeProfileID = profiles.first?.id
            saveProfiles()
            if let p = activeProfile { activate(p) }
            else { recentSgbd = [] }
        } else {
            saveProfiles()
        }
    }

    public func activate(_ profile: EcuProfile, clearTool: Bool = true) {
        guard !busy else { return }
        guard var resolved = Self.resolve(profile.bookmark) else {
            errorMessage = "The folder for \"\(profile.name)\" is no longer available. Remove it and add it again."
            return
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        _ = resolved.url.startAccessingSecurityScopedResource()
        scopedURL = resolved.url
        if resolved.stale, let fresh = try? resolved.url.bookmarkData(),
           let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i].bookmark = fresh
        }
        activeProfileID = profile.id
        saveProfiles()
        if clearTool {
            selectedSgbd = nil
            jobs = []
            sections = []
            resetFaults()
        }
        applyFolder(resolved.url)
        recentSgbd = loadRecents()
    }

    private func applyFolder(_ url: URL) {
        ecuFolder = url
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        sgbdFiles = names
            .filter { $0.lowercased().hasSuffix(".prg") || $0.lowercased().hasSuffix(".grp") }
            .sorted { $0.lowercased() < $1.lowercased() }
        if let e = ediabas, !e.jobRunning { e.setConfigProperty("EcuPath", url.path) }
    }

    private var recentKey: String { "recentSgbd." + (activeProfileID?.uuidString ?? "none") }
    private func loadRecents() -> [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    // MARK: BLE

    public func startScan() async {
        errorMessage = nil
        devices = []
        if central == nil {
            central = BleCentral()
            central?.log = { [weak self] in self?.appendLog($0) }
        }
        do {
            try await central!.waitUntilReady()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        state = .scanning
        central!.startScan { [weak self] device in
            DispatchQueue.main.async {
                guard let self else { return }
                if let i = self.devices.firstIndex(of: device) {
                    var d = device
                    d.looksLikeAdapter = device.looksLikeAdapter || self.devices[i].looksLikeAdapter
                    if device.name == "(unnamed)" { d.name = self.devices[i].name }
                    self.devices[i] = d
                } else { self.devices.append(device) }
                self.devices.sort {
                    if $0.looksLikeAdapter != $1.looksLikeAdapter { return $0.looksLikeAdapter }
                    return $0.rssi > $1.rssi
                }
            }
        }
    }

    public func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .disconnected }
    }

    public func connect(_ device: BleDevice) async {
        errorMessage = nil
        central?.stopScan()
        state = .connecting(device.name)
        appendLog("Connecting to \(device.name)")
        do {
            let t = try await central!.connect(device)
            t.onDisconnect = { [weak self] in
                DispatchQueue.main.async { self?.linkLost(t) }
            }
            transport = t
            let i = ElmBmwInterface(transport: t)
            iface = i
            let e = Ediabas(ecuPath: ecuFolder?.path ?? "")
            e.setConfigProperty("BipDebugLevel", traceEnabled ? "3" : "0")
            e.logHandler = { [weak self] level, text in
                guard let self else { return }
                self.appendLog(text)
            }
            e.interface = i
            ediabas = e
            state = .connected(device.name)
            appendLog("Connected: \(device.name) via \(t.profileName)")
        } catch {
            state = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    private func linkLost(_ lost: BleSerialTransport) {
        guard transport === lost else { return }
        appendLog("Adapter link lost")
        let e = ediabas
        let i = iface
        worker.async {
            try? e?.closeAll()
            _ = try? i?.interfaceDisconnect()
        }
        ediabas = nil
        iface = nil
        transport = nil
        jobs = []
        selectedSgbd = nil
        busy = false
        state = .disconnected
        errorMessage = "The adapter disconnected. Reconnect on the Adapter tab."
    }

    public func disconnect() {
        let e = ediabas
        let i = iface
        let t = transport
        worker.async {
            try? e?.closeAll()
            _ = try? i?.interfaceDisconnect()
            t?.close()
        }
        ediabas = nil
        iface = nil
        transport = nil
        jobs = []
        selectedSgbd = nil
        state = .disconnected
    }

    public var isConnected: Bool { if case .connected = state { return true } else { return false } }

    // MARK: worker helpers

    private func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            worker.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func cancelJob() {
        abort.set(true)
    }

    // MARK: jobs

    public func selectSgbd(_ name: String) async {
        guard let e = ediabas else { errorMessage = "Not connected"; return }
        guard let folder = ecuFolder else { errorMessage = "Choose the ECU folder first"; return }
        errorMessage = nil
        busy = true
        defer { busy = false }
        selectedSgbd = name
        jobs = []
        sections = []
        let flag = abort
        flag.set(false)
        do {
            let list: [JobEntry] = try await onWorker {
                e.abortJobFunc = { flag.isSet }
                e.setConfigProperty("EcuPath", folder.path)
                try e.resolveSgbdFile(name)
                try e.executeJob("_JOBS")
                let names = (e.resultSets ?? []).dropFirst().compactMap { $0["JOBNAME"]?.value.asString }
                return names.sorted().map { JobEntry(name: $0, comment: e.jobComments($0).first ?? "") }
            }
            jobs = list
            noteRecent(name)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Loads the description of one job (comment, arguments, results) from the SGBD.
    public func jobInfo(_ job: String) async -> [String] {
        guard let e = ediabas, selectedSgbd != nil else { return [] }
        do {
            return try await onWorker {
                var lines: [String] = []
                e.argString = job
                try e.executeJob("_JOBCOMMENTS")
                for set in (e.resultSets ?? []).dropFirst() {
                    for key in set.keys.sorted() { if let s = set[key]?.value.asString { lines.append(s) } }
                }
                e.argString = job
                try e.executeJob("_ARGUMENTS")
                for set in (e.resultSets ?? []).dropFirst() {
                    let arg = set["ARG"]?.value.asString ?? ""
                    let type = set["ARGTYPE"]?.value.asString ?? ""
                    let comments = set.keys.filter { $0.hasPrefix("ARGCOMMENT") }.sorted().compactMap { set[$0]?.value.asString }
                    lines.append("Arg: \(arg) (\(type)) \(comments.joined(separator: " "))")
                }
                e.argString = job
                try e.executeJob("_RESULTS")
                for set in (e.resultSets ?? []).dropFirst() {
                    let r = set["RESULT"]?.value.asString ?? ""
                    let type = set["RESULTTYPE"]?.value.asString ?? ""
                    let comments = set.keys.filter { $0.hasPrefix("RESULTCOMMENT") }.sorted().compactMap { set[$0]?.value.asString }
                    lines.append("Result: \(r) (\(type)) \(comments.joined(separator: " "))")
                }
                return lines
            }
        } catch {
            return ["Error: \(describe(error))"]
        }
    }

    // MARK: fault memory

    @Published public var faults: [Fault] = []
    @Published public var faultsRead = false
    @Published public var faultStatus = ""

    public var canReadFaults: Bool { jobs.contains { $0.name.uppercased() == "FS_LESEN" } }
    public var canClearFaults: Bool { jobs.contains { $0.name.uppercased() == "FS_LOESCHEN" } }

    public func readFaults() async {
        guard let e = ediabas else { errorMessage = "Not connected"; return }
        errorMessage = nil
        busy = true
        faultStatus = "Reading…"
        defer { busy = false }
        let flag = abort
        flag.set(false)
        do {
            let sets: [ResultSet] = try await onWorker {
                e.abortJobFunc = { flag.isSet }
                e.argString = ""
                e.resultsRequests = ""
                try e.executeJob("FS_LESEN")
                return e.resultSets ?? []
            }
            faults = FaultReader.parse(sets)
            faultsRead = true
            faultStatus = FaultReader.isOkay(sets) ? "" : "The ECU reported an error while reading."
        } catch {
            faultStatus = ""
            errorMessage = describe(error)
        }
    }

    public func clearFaults() async {
        guard let e = ediabas else { errorMessage = "Not connected"; return }
        errorMessage = nil
        busy = true
        faultStatus = "Clearing…"
        defer { busy = false }
        let flag = abort
        flag.set(false)
        do {
            let sets: [ResultSet] = try await onWorker {
                e.abortJobFunc = { flag.isSet }
                e.argString = ""
                e.resultsRequests = ""
                try e.executeJob("FS_LOESCHEN")
                return e.resultSets ?? []
            }
            faultStatus = FaultReader.isOkay(sets) ? "Fault memory cleared." : "The ECU did not accept the clear command."
        } catch {
            faultStatus = ""
            errorMessage = describe(error)
            return
        }
        await readFaults()
    }

    public func resetFaults() {
        faults = []
        faultsRead = false
        faultStatus = ""
    }

    // MARK: vehicle scan

    @Published public var scanResults: [EcuScanResult] = []
    @Published public var scanProgress = 0.0
    @Published public var scanMessage = ""
    @Published public var scanning = false
    @Published public var scanFinished = false
    private var scanner: VehicleScanner?
    private var mapCache: [UUID: (map: [UInt8: [String]], names: [UInt8: String])] = [:]

    public var scanFaultCount: Int { scanResults.reduce(0) { $0 + $1.faults.count } }

    public func startVehicleScan() async {
        guard let e = ediabas, let i = iface, let folder = ecuFolder else { errorMessage = "Not connected"; return }
        guard !busy else { return }
        errorMessage = nil
        busy = true
        scanning = true
        scanFinished = false
        scanResults = []
        scanProgress = 0
        scanMessage = "Preparing ECU list…"
        defer { busy = false; scanning = false }
        let flag = abort
        flag.set(false)
        let key = activeProfileID ?? UUID()
        let cached = mapCache[key]
        do {
            let maps: (map: [UInt8: [String]], names: [UInt8: String]) = try await onWorker {
                if let c = cached { return c }
                return (EcuMap.build(ecuDir: folder.path), EcuMap.ecuNames(ecuDir: folder.path))
            }
            mapCache[key] = maps
            let sc = VehicleScanner(ediabas: e, interface: i, ecuDir: folder.path, map: maps.map, names: maps.names)
            scanner = sc
            scanMessage = "Connecting to the adapter…"
            let results: [EcuScanResult] = try await onWorker { [weak self] in
                e.abortJobFunc = { flag.isSet }
                e.setConfigProperty("EcuPath", folder.path)
                _ = try i.interfaceConnect()
                return sc.scan(progress: { f, m in
                    DispatchQueue.main.async { self?.scanProgress = f; self?.scanMessage = m }
                }, shouldStop: { flag.isSet })
            }
            scanResults = Self.sortScan(results)
            scanFinished = !flag.isSet
            scanMessage = flag.isSet ? "Cancelled" : "Done"
        } catch {
            errorMessage = describe(error)
        }
    }

    private static func sortScan(_ r: [EcuScanResult]) -> [EcuScanResult] {
        r.sorted {
            if ($0.faults.isEmpty) != ($1.faults.isEmpty) { return !$0.faults.isEmpty }
            return $0.address < $1.address
        }
    }

    /// Clears one ECU of the scan and reads it again.
    public func clearScanned(_ ecu: EcuScanResult) async {
        guard let e = ediabas, let sc = scanner, !busy else { return }
        busy = true
        defer { busy = false }
        let flag = abort
        flag.set(false)
        let updated: EcuScanResult = await withCheckedContinuation { cont in
            worker.async {
                e.abortJobFunc = { flag.isSet }
                let ok = sc.clear(ecu)
                var r = sc.reread(ecu)
                if !ok && r.error == nil { r.error = "The ECU did not accept the clear command." }
                cont.resume(returning: r)
            }
        }
        if let i = scanResults.firstIndex(where: { $0.address == ecu.address }) { scanResults[i] = updated }
        scanResults = Self.sortScan(scanResults)
    }

    public func clearAllScanned() async {
        for ecu in scanResults where !ecu.faults.isEmpty {
            await clearScanned(ecu)
        }
    }

    public func run(job: String, args: String, results: String) async {
        guard let e = ediabas else { errorMessage = "Not connected"; return }
        errorMessage = nil
        busy = true
        defer { busy = false }
        let flag = abort
        flag.set(false)
        do {
            let sets: [ResultSet] = try await onWorker {
                e.abortJobFunc = { flag.isSet }
                e.argString = args
                e.resultsRequests = results
                try e.executeJob(job)
                return e.resultSets ?? []
            }
            sections = Self.makeSections(sets, includeSystem: showSystemResults)
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? EdiabasNetException { return e.code.text }
        if let e = error as? EdiabasFailure { return e.message }
        return error.localizedDescription
    }

    // MARK: result formatting

    static func makeSections(_ sets: [ResultSet], includeSystem: Bool) -> [ResultSection] {
        var out: [ResultSection] = []
        for (index, set) in sets.enumerated() {
            if index == 0 && !includeSystem { continue }
            let rows = set.values.sorted { $0.name < $1.name }.map { r in
                ResultRow(name: r.name, type: "\(r.type)".dropFirst(4).uppercased(), text: Self.text(r.value))
            }
            out.append(ResultSection(title: index == 0 ? "System" : "Set \(index)", rows: rows))
        }
        return out
    }

    static func text(_ v: ResultValue) -> String {
        switch v {
        case .int(let i): return "\(i)"
        case .double(let d): return String(format: "%g", d)
        case .string(let s): return s
        case .bytes(let b): return b.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}
