import Foundation

public enum ResultType: UInt8, Sendable {
    case typeB, typeW, typeD, typeQ, typeC, typeI, typeL, typeLL, typeR, typeS, typeY
}

public enum ResultValue: Sendable {
    case int(Int64)
    case double(Double)
    case string(String)
    case bytes([UInt8])

    public var asInt: Int64? { if case .int(let v) = self { return v }; return nil }
    public var asDouble: Double? { if case .double(let v) = self { return v }; return nil }
    public var asString: String? { if case .string(let v) = self { return v }; return nil }
    public var asBytes: [UInt8]? { if case .bytes(let v) = self { return v }; return nil }
}

public struct ResultData: Sendable {
    public let type: ResultType
    public let name: String
    public let value: ResultValue
    public init(type: ResultType, name: String, value: ResultValue) {
        self.type = type; self.name = name; self.value = value
    }
}

public typealias ResultSet = [String: ResultData]

public enum EdLogLevel: Int, Sendable { case off = 0, ifh, error, info }

struct OpCode {
    let name: String
    let fn: ((Ediabas, Operand, Operand) throws -> Void)?
    var arg0IsNearAddress = false
}

private final class ArgInfo {
    var binData: [UInt8]? { didSet { stringList = nil } }
    var stringList: [String]?
}

/// Swift port of the EDIABAS interpreter (EdiabasNet): loads BEST/2 .prg/.grp files and executes jobs.
public final class Ediabas {
    public static let version = 0x773
    static let prgExt = ".prg"
    static let groupExt = ".grp"
    static let maxFiles = 5
    static let jobInit = "INITIALISIERUNG"
    static let jobExit = "ENDE"
    static let jobIdent = "IDENTIFIKATION"
    static let minVersion760 = version >= 0x760
    static let minVersion770 = version >= 0x770

    static var versionString: String {
        "\((version >> 8) & 0xF).\((version >> 4) & 0xF).\(version & 0xF)"
    }

    // trap bit numbers for errors
    static let trapBits: [EdiabasError: Int] = {
        var d: [EdiabasError: Int] = [
            .EDIABAS_BIP_0002: 2, .EDIABAS_BIP_0006: 6, .EDIABAS_BIP_0009: 9, .EDIABAS_BIP_0010: 10,
            .EDIABAS_IFH_0001: 11, .EDIABAS_IFH_0002: 12, .EDIABAS_IFH_0003: 13, .EDIABAS_IFH_0004: 14,
            .EDIABAS_IFH_0005: 15, .EDIABAS_IFH_0006: 16, .EDIABAS_IFH_0007: 17, .EDIABAS_IFH_0008: 18,
            .EDIABAS_IFH_0009: 19, .EDIABAS_IFH_0010: 20, .EDIABAS_IFH_0011: 21, .EDIABAS_IFH_0012: 22,
            .EDIABAS_IFH_0013: 23, .EDIABAS_IFH_0014: 24, .EDIABAS_IFH_0015: 25, .EDIABAS_IFH_0016: 26,
        ]
        if minVersion760 { d[.EDIABAS_BIP_0011] = 8; d[.EDIABAS_IFH_0069] = 28 }
        if minVersion770 { d[.EDIABAS_IFH_0074] = 29 }
        return d
    }()

    static let sharedLock = NSLock()
    nonisolated(unsafe) static var sharedData: [String: [UInt8]] = [:]

    /// Clears the EDIABAS shared memory (shmset/shmget data that SGBDs leave for each other).
    public static func clearSharedData() {
        sharedLock.withLock { sharedData.removeAll() }
    }

    // MARK: state

    private let apiLock = NSRecursiveLock()
    private var _jobRunning = false
    var jobStd = false
    var jobStdExit = false
    private var closeSgbdFs = false
    var stack: [UInt8] = []
    private let argInfo = ArgInfo()
    private let argInfoStd = ArgInfo()
    var resultDict: [String: ResultData] = [:]
    var resultSysDict: [String: ResultData] = [:]
    private var resultsRequest: [String: Bool] = [:]
    private var _resultSets: [ResultSet]?
    var resultSetsTemp: [ResultSet] = []
    private var config: [String: String] = [:]
    private var groupMapping: [String: (variant: String, family: String)] = [:]
    var resultJobStatus = ""
    private var _groupName = ""
    private var _familyName = ""
    private var _sgbdFileName = ""
    private var sgbdFileResolveLast = ""
    private var _ecuPath: String
    private var _interface: EdInterface?

    var infoProgressRange: Int64 = -1
    var infoProgressPos: Int64 = -1
    var infoProgressText = ""

    public var abortJobFunc: (() -> Bool)?
    public var progressJobFunc: ((Ediabas) -> Void)?
    public var errorRaisedFunc: ((EdiabasError) -> Void)?
    public var logHandler: ((EdLogLevel, String) -> Void)?
    public var noInitForVJobs = false

    var arrayMaxBufSize: UInt32 = 1024
    var arrayMaxSize: UInt32 { arrayMaxBufSize &- 1 }
    var errorTrapMask: UInt32 = 0
    var errorTrapBitNr: Int = -1
    private var errorCodeLast: EdiabasError = .EDIABAS_ERR_NONE
    var byteRegisters = [UInt8](repeating: 0, count: 32)
    var floatRegisters = [Double](repeating: 0, count: 16)
    var stringRegisters: [StringData]
    var flags = Flags()
    private var sgbdFs: PrgFile?
    var sgbdBaseFs: PrgFile?
    var pcCounter: UInt32 = 0
    private var jobInfos: [JobInfo] = []
    private var jobNameDict: [String: Int] = [:]
    private var usesInfos: [UsesInfo] = []
    private var versionInfo = VersionInfo()
    private var descriptionInfo: DescriptionInfo?
    private var tableInfos = TableInfos()
    private var tableInfosExt: TableInfos?
    private var tableFs: PrgFile?
    var tableIndex = -1
    var tableRowIndex = -1
    var userFiles = [UserFile?](repeating: nil, count: Ediabas.maxFiles)
    var tokenSeparator = ""
    var tokenIndex: UInt32 = 0
    var floatPrecision: UInt32 = 4
    var jobEnd = false
    var requestInit = true
    private let opArgBuffer = 5

    public init(ecuPath: String = "") {
        _ecuPath = ecuPath
        stringRegisters = (0..<16).map { _ in StringData(length: 1024) }
        setConfigProperty("EdiabasVersion", Ediabas.versionString)
        setConfigProperty("Simulation", "0")
        setConfigProperty("BipDebugLevel", "0")
        setConfigProperty("ApiTrace", "0")
        setConfigProperty("IfhTrace", "0")
        setConfigProperty("CompatMode", "1")
        setConfigProperty("UbattHandling", "0")
        setConfigProperty("IgnitionHandling", "0")
        setConfigProperty("ClampHandling", "0")
        setConfigProperty("RetryComm", "1")
        setConfigProperty("SystemResults", "1")
        setConfigProperty("TaskPriority", "0")
        setConfigProperty("EcuPath", ecuPath)
    }



    // MARK: properties

    public var jobRunning: Bool { apiLock.withLock { _jobRunning } }
    private func setJobRunning(_ v: Bool) { apiLock.withLock { _jobRunning = v } }

    public var groupName: String { apiLock.withLock { _groupName } }
    public var familyName: String { apiLock.withLock { _familyName } }
    public var ecuPath: String { apiLock.withLock { _ecuPath } }
    public var lastError: EdiabasError { apiLock.withLock { errorCodeLast } }

    public var sgbdFileName: String {
        get { apiLock.withLock { _sgbdFileName } }
        set {
            precondition(!jobRunning, "SgbdFileName: Job is running")
            let changed = apiLock.withLock { _sgbdFileName.caseInsensitiveCompare(newValue) != .orderedSame }
            if changed {
                closeSgbdFs = true
                apiLock.withLock { _sgbdFileName = newValue }
            }
        }
    }

    public var interface: EdInterface? {
        get { apiLock.withLock { _interface } }
        set {
            apiLock.withLock {
                _interface = newValue
                newValue?.ediabas = self
            }
            if let i = newValue {
                setConfigProperty("Interface", i.interfaceName)
            }
        }
    }

    public var argString: String {
        get {
            apiLock.withLock { argInfo.binData.map { Cp1252.string($0) } ?? "" }
        }
        set {
            apiLock.withLock { argInfo.binData = newValue.isEmpty ? nil : Cp1252.bytes(newValue) }
        }
    }

    public var argBinary: [UInt8] {
        get { apiLock.withLock { argInfo.binData ?? [] } }
        set { apiLock.withLock { argInfo.binData = newValue } }
    }

    public var argStringStd: String {
        get { apiLock.withLock { argInfoStd.binData.map { Cp1252.string($0) } ?? "" } }
        set { apiLock.withLock { argInfoStd.binData = newValue.isEmpty ? nil : Cp1252.bytes(newValue) } }
    }

    public var argBinaryStd: [UInt8] {
        get { apiLock.withLock { argInfoStd.binData ?? [] } }
        set { apiLock.withLock { argInfoStd.binData = newValue } }
    }

    func activeArgBinary() -> [UInt8] { jobStd ? argBinaryStd : argBinary }

    func activeArgStrings() -> [String] {
        let args = jobStd ? argStringStd : argString
        let info = jobStd ? argInfoStd : argInfo
        if info.stringList == nil {
            info.stringList = args.isEmpty ? [] : args.components(separatedBy: ";")
        }
        return info.stringList ?? []
    }

    public var resultSets: [ResultSet]? { apiLock.withLock { _resultSets } }

    /// Semicolon separated list of requested result names (empty = all).
    public var resultsRequests: String {
        get { apiLock.withLock { resultsRequest.keys.joined(separator: ";") } }
        set {
            apiLock.withLock {
                resultsRequest.removeAll()
                for w in newValue.components(separatedBy: ";") where !w.isEmpty {
                    resultsRequest[w.uppercased()] = true
                }
            }
        }
    }

    func isResultRequested(_ name: String) -> Bool? {
        apiLock.withLock { resultsRequest.isEmpty ? nil : (resultsRequest[name] != nil) }
    }

    public var infoProgressPercent: Int {
        apiLock.withLock {
            if infoProgressPos < 0 || infoProgressRange <= 0 { return -1 }
            return Int(infoProgressPos * 100 / infoProgressRange)
        }
    }

    public var progressText: String { apiLock.withLock { infoProgressText } }

    // MARK: config

    public func getConfigProperty(_ name: String) -> String? {
        apiLock.withLock { config[name.uppercased()] }
    }

    public func setConfigProperty(_ name: String, _ value: String?) {
        let key = name.uppercased()
        apiLock.withLock {
            if let v = value, !v.isEmpty {
                config[key] = v
            } else {
                config.removeValue(forKey: key)
            }
        }
        if key == "ECUPATH" {
            let newPath = (value?.isEmpty == false) ? value! : ""
            let changed = apiLock.withLock { () -> Bool in
                let c = _ecuPath.caseInsensitiveCompare(newPath) != .orderedSame
                if c { _ecuPath = newPath }
                return c
            }
            if changed {
                closeSgbdFs = true
                groupMapping.removeAll()
            }
        }
    }

    // MARK: logging

    var logLevel: EdLogLevel {
        EdLogLevel(rawValue: Int(ediStringToValue(getConfigProperty("BipDebugLevel") ?? "0"))) ?? .off
    }

    func log(_ level: EdLogLevel, _ message: @autoclosure () -> String) {
        guard let h = logHandler, level.rawValue <= logLevel.rawValue else { return }
        h(level, message())
    }

    // MARK: registers

    func regValue(_ r: Register) throws -> UInt32 {
        switch r.kind {
        case .ab: return UInt32(byteRegisters[r.index])
        case .i:
            let o = r.index << 1
            return UInt32(byteRegisters[o]) | UInt32(byteRegisters[o + 1]) << 8
        case .l:
            let o = r.index << 2
            return UInt32(byteRegisters[o]) | UInt32(byteRegisters[o + 1]) << 8 |
                UInt32(byteRegisters[o + 2]) << 16 | UInt32(byteRegisters[o + 3]) << 24
        default: throw EdiabasFailure("Register.GetValueData: Invalid data type")
        }
    }

    func regFloat(_ r: Register) throws -> Double {
        guard r.kind == .f else { throw EdiabasFailure("Register.GetFloatData: Invalid data type") }
        return floatRegisters[r.index]
    }

    func regArray(_ r: Register, complete: Bool) throws -> [UInt8] {
        guard r.kind == .s else { throw EdiabasFailure("Register.GetArrayData: Invalid data type") }
        return stringRegisters[r.index].getData(complete: complete)
    }

    func regRaw(_ r: Register) throws -> RawData {
        switch r.kind {
        case .ab, .i, .l: return .value(try regValue(r))
        case .f: return .float(try regFloat(r))
        case .s: return .bytes(try regArray(r, complete: false))
        }
    }

    func setRegValue(_ r: Register, _ value: UInt32) throws {
        switch r.kind {
        case .ab: byteRegisters[r.index] = UInt8(truncatingIfNeeded: value)
        case .i:
            let o = r.index << 1
            byteRegisters[o] = UInt8(truncatingIfNeeded: value)
            byteRegisters[o + 1] = UInt8(truncatingIfNeeded: value >> 8)
        case .l:
            let o = r.index << 2
            byteRegisters[o] = UInt8(truncatingIfNeeded: value)
            byteRegisters[o + 1] = UInt8(truncatingIfNeeded: value >> 8)
            byteRegisters[o + 2] = UInt8(truncatingIfNeeded: value >> 16)
            byteRegisters[o + 3] = UInt8(truncatingIfNeeded: value >> 24)
        default: throw EdiabasFailure("Register.SetValueData: Invalid data type")
        }
    }

    func setRegArray(_ r: Register, _ value: [UInt8], keepLength: Bool = false) throws {
        guard r.kind == .s else { throw EdiabasFailure("Register.SetArrayData: Invalid data type") }
        let sd = stringRegisters[r.index]
        if value.count > sd.data.count {
            try setError(.EDIABAS_BIP_0001)
            return
        }
        for (i, b) in value.enumerated() { sd.data[i] = b }
        if !keepLength { sd.length = UInt32(value.count) }
    }

    func setRegRaw(_ r: Register, _ value: RawData) throws {
        switch r.kind {
        case .s:
            guard case .bytes(let b) = value else { throw EdiabasFailure("Register.SetRawData: Invalid type") }
            try setRegArray(r, b)
        case .f:
            guard case .float(let f) = value else { throw EdiabasFailure("Register.SetRawData: Invalid type") }
            floatRegisters[r.index] = f
        default:
            guard case .value(let v) = value else { throw EdiabasFailure("Register.SetRawData: Invalid type") }
            try setRegValue(r, v)
        }
    }

    func clearReg(_ r: Register) throws {
        guard r.kind == .s else { throw EdiabasFailure("Register.ClearData: Invalid data type") }
        stringRegisters[r.index].clear()
    }

    // MARK: errors

    /// Records an error in the trap register and raises it unless it is masked (SetError).
    func setError(_ error: EdiabasError) throws {
        log(.error, "SetError: \(error)")
        if error != .EDIABAS_ERR_NONE {
            if let bit = Ediabas.trapBits[error] {
                errorTrapBitNr = bit
            } else {
                errorTrapBitNr = 0
            }
            sgbdFileResolveLast = ""
            let active = (UInt32(1) &<< UInt32(truncatingIfNeeded: errorTrapBitNr)) & ~errorTrapMask
            if active != 0 {
                try raiseError(error)
            }
        } else {
            errorTrapBitNr = -1
        }
    }

    func raiseError(_ error: EdiabasError) throws -> Never {
        var code = error
        if jobStdExit { code = .EDIABAS_SYS_0018 }
        apiLock.withLock { errorCodeLast = code }
        errorRaisedFunc?(code)
        throw EdiabasNetException(code: code)
    }

    func raiseErrorThrows(_ error: EdiabasError) throws {
        try raiseError(error)
    }

    // MARK: files

    private func openPrg(_ path: String) throws -> PrgFile {
        if let f = try? PrgFile(contentsOf: URL(fileURLWithPath: path)) { return f }
        // case insensitive fallback
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        if let list = try? FileManager.default.contentsOfDirectory(atPath: dir),
           let match = list.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return try PrgFile(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(match))
        }
        throw EdiabasFailure("File not found: \(path)")
    }

    private func prgExists(_ path: String) -> Bool { (try? openPrg(path)) != nil }

    private func ecuFilePath(_ name: String) -> String {
        (ecuPath as NSString).appendingPathComponent(name)
    }

    private var openSgbdError = ""

    private func openSgbdFs() -> Bool {
        if sgbdFs != nil { return true }
        let fileName = ecuFilePath(sgbdFileName)
        let fs: PrgFile
        do {
            fs = try PrgFile(contentsOf: URL(fileURLWithPath: fileName))
        } catch {
            // case insensitive fallback for case sensitive file systems
            guard let f = try? openPrg(fileName) else {
                let dir = (fileName as NSString).deletingLastPathComponent
                let exists = FileManager.default.fileExists(atPath: dir)
                openSgbdError = "cannot open '\(fileName)': \(error.localizedDescription) (folder \(exists ? "exists" : "missing"))"
                log(.error, "OpenSgbdFs \(openSgbdError)")
                return false
            }
            fs = f
        }
        do {
            sgbdFs = fs
            usesInfos = try fs.readUses()
            versionInfo = try fs.readVersionInfo()
            descriptionInfo = nil
            try readAllJobs(fs)
            tableInfos = try fs.readTables()
            requestInit = true
        } catch {
            openSgbdError = "cannot read '\(fileName)': \(error)"
            log(.error, "OpenSgbdFs \(openSgbdError)")
            sgbdFs = nil
            return false
        }
        return true
    }

    private func readAllJobs(_ fs: PrgFile) throws {
        var all = try fs.readJobList(usesInfo: nil)
        for uses in usesInfos {
            let fileName = ecuFilePath(uses.name.lowercased() + Ediabas.prgExt)
            guard let tmp = try? openPrg(fileName) else {
                log(.error, "ReadAllJobs file not found: \(fileName)")
                continue
            }
            do { all += try tmp.readJobList(usesInfo: uses) } catch {
                log(.error, "ReadAllJobs exception: \(error)")
            }
        }
        jobInfos = all
        jobNameDict = [:]
        for (index, job) in all.enumerated() {
            let key = job.name.uppercased()
            var add = true
            if job.uses != nil, key == Ediabas.jobInit || key == Ediabas.jobExit { add = false }
            if add && jobNameDict[key] == nil { jobNameDict[key] = index }
        }
    }

    private func closeSgbd() throws {
        if sgbdFs != nil {
            defer { sgbdFs = nil }
            if !requestInit { try executeExitJob() }
        }
    }

    public func closeSgbdRequest() { closeSgbdFs = true }

    func closeTableFs() {
        tableFs = nil
        tableInfosExt = nil
        tableIndex = -1
        tableRowIndex = -1
    }

    var currentTableFs: PrgFile? { tableFs ?? sgbdFs }

    func setTableFs(_ fs: PrgFile) throws {
        tableFs = fs
        tableInfosExt = try fs.readTables()
    }

    func tableInfosFor(_ fs: PrgFile?) -> TableInfos? {
        if let t = tableFs, t === fs { return tableInfosExt }
        return tableInfos
    }

    func storeUserFile(_ f: UserFile) -> Int {
        for i in userFiles.indices where userFiles[i] == nil {
            userFiles[i] = f
            return i
        }
        return -1
    }

    func userFile(_ index: Int) -> UserFile? {
        guard index >= 0, index < userFiles.count else { return nil }
        return userFiles[index]
    }

    func closeUserFile(_ index: Int) -> Bool {
        guard index >= 0, index < userFiles.count else { return false }
        userFiles[index] = nil
        return true
    }

    func closeAllUserFiles() {
        for i in userFiles.indices { userFiles[i] = nil }
    }

    func prgFileExists(named base: String) -> String? {
        let prg = ecuFilePath(base + Ediabas.prgExt)
        let grp = ecuFilePath(base + Ediabas.groupExt)
        if prgExists(prg) { return prg }
        if prgExists(grp) { return grp }
        return nil
    }

    func openPrgFile(_ path: String) throws -> PrgFile { try openPrg(path) }

    // MARK: tables

    func getTableIndex(_ fs: PrgFile, _ tableName: String) throws -> (index: Int, found: Bool) {
        guard let infos = tableInfosFor(fs) else { return (0, false) }
        if let idx = infos.nameDict[tableName.uppercased()] {
            try fs.indexTable(infos.tables[idx])
            return (idx, true)
        }
        return (infos.tables.count - 1, false)
    }

    func tableColumns(_ fs: PrgFile?, _ tableIdx: Int) -> UInt32 {
        guard let t = tableInfosFor(fs)?.tables, tableIdx >= 0, tableIdx < t.count else { return 0 }
        return t[tableIdx].columns
    }

    func tableRows(_ fs: PrgFile?, _ tableIdx: Int) -> UInt32 {
        guard let t = tableInfosFor(fs)?.tables, tableIdx >= 0, tableIdx < t.count else { return 0 }
        return t[tableIdx].rows
    }

    func tableLine(_ fs: PrgFile?, _ tableIdx: Int, _ line: UInt32) -> (row: Int, found: Bool) {
        guard let t = tableInfosFor(fs)?.tables, tableIdx >= 0, tableIdx < t.count else { return (-1, false) }
        let table = t[tableIdx]
        if line >= table.rows { return (Int(table.rows) - 1, false) }
        return (Int(line), true)
    }

    func seekTable(_ fs: PrgFile, _ tableIdx: Int, column: String, value: String) throws -> (row: Int, found: Bool) {
        guard let t = tableInfosFor(fs)?.tables, tableIdx >= 0, tableIdx < t.count else { return (-1, false) }
        let table = t[tableIdx]
        guard let colIdx = table.columnNames[column.uppercased()] else { return (-1, false) }
        if table.seekStrings[colIdx] == nil {
            var dict: [String: UInt32] = [:]
            if let entries = table.entries {
                for i in 1..<max(entries.count, 1) {
                    let s = try fs.tableString(at: entries[i][colIdx]).uppercased()
                    if dict[s] == nil { dict[s] = UInt32(i - 1) }
                }
            }
            table.seekStrings[colIdx] = dict
        }
        if let row = table.seekStrings[colIdx]?[value.uppercased()] { return (Int(row), true) }
        return (Int(table.rows) - 1, false)
    }

    func seekTable(_ fs: PrgFile, _ tableIdx: Int, column: String, value: UInt32) throws -> (row: Int, found: Bool) {
        guard let t = tableInfosFor(fs)?.tables, tableIdx >= 0, tableIdx < t.count else { return (-1, false) }
        let table = t[tableIdx]
        guard let colIdx = table.columnNames[column.uppercased()] else { return (-1, false) }
        if table.seekValues[colIdx] == nil {
            var dict: [UInt32: UInt32] = [:]
            if let entries = table.entries {
                for i in 1..<max(entries.count, 1) {
                    let s = try fs.tableString(at: entries[i][colIdx])
                    let v = UInt32(truncatingIfNeeded: ediStringToValue(s))
                    if dict[v] == nil { dict[v] = UInt32(i - 1) }
                }
            }
            table.seekValues[colIdx] = dict
        }
        if let row = table.seekValues[colIdx]?[value] { return (Int(row), true) }
        return (Int(table.rows) - 1, false)
    }

    func tableEntry(_ fs: PrgFile, _ tableIdx: Int, row: Int, column: String) throws -> (entry: String?, columnInvalid: Bool) {
        guard let t = tableInfosFor(fs)?.tables, tableIdx >= 0, tableIdx < t.count else { return (nil, false) }
        let table = t[tableIdx]
        guard let colIdx = table.columnNames[column.uppercased()] else { return (nil, true) }
        if row < 0 || row >= Int(table.rows) { return (nil, false) }
        guard let entries = table.entries else { return (nil, false) }
        return (try fs.tableString(at: entries[row + 1][colIdx]), false)
    }

    /// All lines of a table of the loaded SGBD (first line is the header).
    public func tableLines(_ tableName: String) throws -> [[String]]? {
        guard let fs = sgbdFs, let idx = tableInfos.nameDict[tableName.uppercased()] else { return nil }
        let table = tableInfos.tables[idx]
        try fs.indexTable(table)
        var out: [[String]] = []
        for row in table.entries ?? [] {
            out.append(try row.map { try fs.tableString(at: $0) })
        }
        return out
    }

    public func tableColumn(_ lines: [[String]]?, _ columnName: String) -> [String]? {
        guard let lines, let header = lines.first,
              let idx = header.firstIndex(where: { $0.caseInsensitiveCompare(columnName) == .orderedSame }) else { return nil }
        return lines.dropFirst().map { $0[idx] }
    }

    // MARK: file type / group resolution

    public func fileType(_ fileName: String) throws -> UInt32 {
        let base = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = (fileName as NSString).deletingLastPathComponent
        var local: String?
        let prg = (dir as NSString).appendingPathComponent(base + Ediabas.prgExt)
        let grp = (dir as NSString).appendingPathComponent(base + Ediabas.groupExt)
        if prgExists(prg) { local = prg } else if prgExists(grp) { local = grp }
        guard let path = local else {
            log(.error, "GetFileType file not found: '\(fileName)'")
            throw EdiabasFailure("GetFileType: File not found")
        }
        do { return try openPrg(path).fileType() } catch {
            throw EdiabasFailure("GetFileType: Unable to read file")
        }
    }

    /// Maps a group file (.grp) to the SGBD variant of the connected ECU, or selects the SGBD directly.
    public func resolveSgbdFile(_ fileName: String) throws {
        precondition(!jobRunning, "ResolveSgbdFile: Job is running")
        let baseFileName = ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent.lowercased()
        if sgbdFileResolveLast == baseFileName { return }
        do {
            let type = try fileType((ecuPath as NSString).appendingPathComponent(fileName))
            if type == 0 {
                let key = baseFileName
                var variantName = ""
                var family = ""
                apiLock.withLock {
                    if let v = groupMapping[key] { variantName = v.variant; family = v.family }
                }
                if variantName.isEmpty {
                    sgbdFileName = baseFileName + Ediabas.groupExt
                    let ident = try executeIdentJob()
                    variantName = ident.variant.lowercased()
                    if !ident.family.isEmpty { family = ident.family.lowercased() }
                    if variantName.isEmpty {
                        log(.error, "ResolveSgbdFile: No variant found")
                        throw EdiabasFailure("ResolveSgbdFile: No variant found")
                    }
                    apiLock.withLock { groupMapping[key] = (variantName, fileName) }
                }
                apiLock.withLock { _groupName = baseFileName; _familyName = family }
                sgbdFileName = variantName + Ediabas.prgExt
            } else {
                apiLock.withLock { _groupName = ""; _familyName = "" }
                sgbdFileName = baseFileName + Ediabas.prgExt
            }
            sgbdFileResolveLast = baseFileName
        } catch {
            apiLock.withLock { _groupName = ""; _familyName = ""; _sgbdFileName = "" }
            sgbdFileResolveLast = ""
            throw error
        }
    }

    public func clearGroupMapping() { apiLock.withLock { groupMapping.removeAll() } }

    // MARK: job execution

    public func isJobExisting(_ jobName: String) -> Bool {
        sgbdFs != nil && jobNameDict[jobName.uppercased()] != nil
    }

    private func jobInfo(_ name: String) -> JobInfo? {
        jobNameDict[name.uppercased()].map { jobInfos[$0] }
    }

    /// Description lines (JOBCOMMENT) of a job of the loaded SGBD file; empty when none are present.
    public func jobComments(_ job: String) -> [String] {
        guard let fs = sgbdFs else { return [] }
        if descriptionInfo == nil { descriptionInfo = try? fs.readDescriptions() }
        let lines = descriptionInfo?.jobComments[job.uppercased()] ?? []
        var out: [String] = []
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            if l[..<colon].caseInsensitiveCompare("JOBCOMMENT") == .orderedSame {
                let v = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { out.append(v) }
            }
        }
        return out
    }

    /// Names of all jobs of the loaded SGBD (own jobs only unless `all`).
    public var jobNames: [String] {
        jobInfos.filter { $0.uses == nil }.map { $0.name }
    }

    /// Executes a job synchronously. Results are available in `resultSets` afterwards.
    public func executeJob(_ jobName: String) throws {
        precondition(!jobRunning, "ExecuteJob: Job is running")
        setJobRunning(true)
        jobStd = false
        jobStdExit = false
        defer {
            argInfo.binData = nil
            argInfoStd.binData = nil
            jobStd = false
            jobStdExit = false
            setJobRunning(false)
        }
        try executeJobPrivate(jobName)
    }

    private func executeInitJob() throws {
        let runningOld = jobRunning
        let stdOld = jobStd
        setJobRunning(true)
        jobStd = true
        defer { jobStd = stdOld; setJobRunning(runningOld) }
        do {
            try executeJobPrivate(Ediabas.jobInit, recursive: true)
        } catch {
            log(.error, "executeInitJob Exception: \(error)")
            sgbdFs = nil
            throw error
        }
        if let sets = resultSets, sets.count > 1, let done = sets[1]["DONE"], done.value.asInt == 1 {
            requestInit = false
            log(.info, "executeInitJob ok")
            return
        }
        log(.error, "executeInitJob failed")
        sgbdFs = nil
        try setError(.EDIABAS_SYS_0010)
    }

    private func executeExitJob() throws {
        let runningOld = jobRunning
        let stdOld = jobStd
        setJobRunning(true)
        jobStd = true
        jobStdExit = true
        defer { jobStd = stdOld; jobStdExit = false; setJobRunning(runningOld) }
        if isJobExisting(Ediabas.jobExit) {
            try executeJobPrivate(Ediabas.jobExit)
        }
    }

    private func executeIdentJob() throws -> (variant: String, family: String) {
        let runningOld = jobRunning
        let stdOld = jobStd
        setJobRunning(true)
        jobStd = true
        defer { jobStd = stdOld; setJobRunning(runningOld) }
        resultDict.removeAll()
        try executeJobPrivate(Ediabas.jobIdent)
        var family = ""
        if let sets = resultSets, sets.count > 1 {
            if let f = sets[1]["FAMILIE"]?.value.asString { family = f }
            if let v = sets[1]["VARIANTE"]?.value.asString { return (v, family) }
        }
        log(.error, "executeIdentJob failed")
        return ("", family)
    }

    private func executeJobPrivate(_ jobName: String, recursive: Bool = false) throws {
        log(.ifh, "executeJob(\(sgbdFileName)): \(jobName) \(activeArgStrings().joined(separator: ", "))")

        if closeSgbdFs {
            closeSgbdFs = false
            try closeSgbd()
        }
        guard openSgbdFs(), let sgbd = sgbdFs else {
            throw EdiabasFailure("Open SGBD failed: \(openSgbdError)")
        }

        let ediabasBipVersion = Int64((((Ediabas.version >> 8) & 0xF) << 16) | (((Ediabas.version >> 4) & 0xF) << 8) | (Ediabas.version & 0xF))
        if versionInfo.bipVersion > ediabasBipVersion {
            try setError(.EDIABAS_BIP_0009)
            return
        }

        guard let job = jobInfo(jobName) else {
            for v in Ediabas.vjobs where v.name.caseInsensitiveCompare(jobName) == .orderedSame {
                try executeVJob(sgbd, v)
                return
            }
            try setError(.EDIABAS_SYS_0008)
            return
        }

        if let uses = job.uses {
            let fileName = ecuFilePath(uses.name.lowercased() + Ediabas.prgExt)
            guard let tmp = try? openPrg(fileName) else {
                log(.error, "ExecuteJobPrivate file not found: \(fileName)")
                throw EdiabasFailure("ExecuteJobPrivate: SGBD not found: \(fileName)")
            }
            sgbdBaseFs = tmp
            defer { closeTableFs(); sgbdBaseFs = nil }
            try executeJobPrivate(tmp, job, recursive: recursive)
        } else {
            try executeJobPrivate(sgbd, job, recursive: recursive)
        }
    }

    private func executeJobPrivate(_ fs: PrgFile, _ job: JobInfo, recursive: Bool) throws {
        if requestInit && !recursive { try executeInitJob() }

        let iface = interface
        _ = try iface?.transmitCancel(false)

        resultSetsTemp = []
        apiLock.withLock { _resultSets = nil }
        resultDict.removeAll()
        resultSysDict.removeAll()
        stack.removeAll()
        setConfigProperty("BipEcuFile", ((sgbdFileName as NSString).deletingPathExtension as NSString).lastPathComponent)
        flags.reset()
        for sd in stringRegisters { sd.clear() }
        errorTrapBitNr = -1
        errorTrapMask = 0
        apiLock.withLock { errorCodeLast = .EDIABAS_ERR_NONE }
        infoProgressRange = -1
        infoProgressPos = -1
        infoProgressText = ""
        resultJobStatus = ""

        arrayMaxBufSize = job.arraySize
        for sd in stringRegisters { sd.newArrayLength(arrayMaxBufSize) }
        pcCounter = job.offset
        closeTableFs()
        closeAllUserFiles()
        jobEnd = false

        let arg0 = Operand(vm: self)
        let arg1 = Operand(vm: self)

        defer {
            closeTableFs()
            closeAllUserFiles()
            let sys = createSystemResultDict(job, setCount: resultSetsTemp.count)
            resultSetsTemp.insert(sys, at: 0)
            apiLock.withLock { _resultSets = resultSetsTemp }
            setConfigProperty("BipEcuFile", nil)
        }

        while !jobEnd {
            fs.position = Int(pcCounter)
            let head = try fs.readDecrypted(2)
            let opCodeVal = Int(head[0])
            let mode0 = OpAddrMode(rawValue: (head[1] & 0xF0) >> 4)
            let mode1 = OpAddrMode(rawValue: head[1] & 0x0F)
            guard opCodeVal < Ediabas.ocList.count else {
                throw EdiabasFailure("executeJob: Opcode out of range")
            }
            guard let m0 = mode0, let m1 = mode1 else { throw EdiabasFailure("opAddrMode: Unsupported OpAddrMode") }
            let oc = Ediabas.ocList[opCodeVal]
            try readOpArg(fs, m0, arg0)
            try readOpArg(fs, m1, arg1)
            pcCounter = UInt32(fs.position)

            if oc.arg0IsNearAddress && m0 == .imm32 {
                arg0.imm = pcCounter &+ arg0.imm
            }

            if let abort = abortJobFunc, abort() {
                _ = try iface?.transmitCancel(true)
                throw EdiabasFailure("executeJob aborted")
            }

            guard let fn = oc.fn else {
                throw EdiabasFailure("executeJob: Function not implemented (\(oc.name))")
            }
            try fn(self, arg0, arg1)
        }
        if !resultDict.isEmpty { resultSetsTemp.append(resultDict) }
        resultDict.removeAll()
    }

    private func readOpArg(_ fs: PrgFile, _ mode: OpAddrMode, _ op: Operand) throws {
        op.reset(mode)
        switch mode {
        case .none: return
        case .regS, .regAb, .regI, .regL:
            op.reg = try lookupRegister(try fs.readDecryptedByte())
        case .imm8:
            op.imm = UInt32(try fs.readDecryptedByte())
        case .imm16:
            op.imm = PrgFile.le16(try fs.readDecrypted(2), 0)
        case .imm32:
            op.imm = PrgFile.le32(try fs.readDecrypted(4), 0)
        case .immStr:
            let l = try fs.readDecrypted(2)
            let slen = Int(Int16(bitPattern: UInt16(PrgFile.le16(l, 0))))
            guard slen >= 0 else { throw EdiabasFailure("opAddrMode: invalid string length") }
            op.str = try fs.readDecrypted(slen)
        case .idxImm:
            let b = try fs.readDecrypted(3)
            op.reg = try lookupRegister(b[0])
            op.idxImm = PrgFile.le16(b, 1)
        case .idxReg:
            let b = try fs.readDecrypted(2)
            op.reg = try lookupRegister(b[0])
            op.idxReg = try lookupRegister(b[1])
        case .idxRegImm:
            let b = try fs.readDecrypted(4)
            op.reg = try lookupRegister(b[0])
            op.idxReg = try lookupRegister(b[1])
            op.lenImm = PrgFile.le16(b, 2)
        case .idxImmLenImm:
            let b = try fs.readDecrypted(5)
            op.reg = try lookupRegister(b[0])
            op.idxImm = PrgFile.le16(b, 1)
            op.lenImm = PrgFile.le16(b, 3)
        case .idxImmLenReg:
            let b = try fs.readDecrypted(4)
            op.reg = try lookupRegister(b[0])
            op.idxImm = PrgFile.le16(b, 1)
            op.lenReg = try lookupRegister(b[3])
        case .idxRegLenImm:
            let b = try fs.readDecrypted(4)
            op.reg = try lookupRegister(b[0])
            op.idxReg = try lookupRegister(b[1])
            op.lenImm = PrgFile.le16(b, 2)
        case .idxRegLenReg:
            let b = try fs.readDecrypted(3)
            op.reg = try lookupRegister(b[0])
            op.idxReg = try lookupRegister(b[1])
            op.lenReg = try lookupRegister(b[2])
        }
    }

    // MARK: results

    func setResultData(_ r: ResultData) { resultDict[r.name.uppercased()] = r }
    func setSysResultData(_ r: ResultData) { resultSysDict[r.name.uppercased()] = r }

    func jobProgressInform() { progressJobFunc?(self) }

    private func createSystemResultDict(_ job: JobInfo, setCount: Int) -> ResultSet {
        var d: ResultSet = [:]
        var objectName = ((sgbdFileName as NSString).deletingPathExtension as NSString).lastPathComponent
        if let u = job.uses { objectName = u.name }
        let sysResults = getConfigProperty("SystemResults").map { ediStringToValue($0) } ?? 0

        func add(_ type: ResultType, _ name: String, _ v: ResultValue) { d[name] = ResultData(type: type, name: name, value: v) }
        add(.typeS, "VARIANTE", .string(((sgbdFileName as NSString).deletingPathExtension as NSString).lastPathComponent.uppercased()))
        if Ediabas.minVersion760 {
            add(.typeS, "GRUPPE", .string(groupName.lowercased()))
            add(.typeS, "FAMILIE", .string(familyName.lowercased()))
        }
        add(.typeS, "OBJECT", .string(objectName))
        add(.typeS, "JOBNAME", .string(job.name))
        add(.typeW, "SAETZE", .int(Int64(setCount)))
        if sysResults != 0 {
            add(.typeS, "JOBSTATUS", .string(resultJobStatus))
            add(.typeI, "UBATTCURRENT", .int(-1))
            add(.typeI, "UBATTHISTORY", .int(-1))
            add(.typeI, "IGNITIONCURRENT", .int(-1))
            add(.typeI, "IGNITIONHISTORY", .int(-1))
        }
        for (k, v) in resultSysDict where d[k] == nil { d[k] = v }
        return d
    }

    // MARK: virtual jobs

    struct VJob {
        let name: String
        let fn: (Ediabas, PrgFile, inout [ResultSet]) throws -> Void
    }

    static let vjobs: [VJob] = [
        VJob(name: "_JOBS") { e, _, sets in
            let args = e.activeArgStrings()
            let all = args.first.map { $0.caseInsensitiveCompare("ALL") == .orderedSame } ?? false
            var seen = Set<String>()
            for job in e.jobInfos {
                let key = job.name.uppercased()
                if (all && !seen.contains(key)) || job.uses == nil {
                    sets.append(["JOBNAME": ResultData(type: .typeS, name: "JOBNAME", value: .string(job.name))])
                    seen.insert(key)
                }
            }
        },
        VJob(name: "_JOBCOMMENTS") { e, fs, sets in
            guard let jc = try e.jobComments(fs) else { return }
            var dict: ResultSet = [:]
            var count = 0
            for desc in jc {
                guard let colon = desc.firstIndex(of: ":") else { continue }
                var key = String(desc[..<colon])
                let value = String(desc[desc.index(after: colon)...])
                if key.caseInsensitiveCompare("JOBCOMMENT") == .orderedSame {
                    key += String(count); count += 1
                    if dict[key] == nil { dict[key] = ResultData(type: .typeS, name: key, value: .string(value)) }
                }
            }
            if !dict.isEmpty { sets.append(dict) }
        },
        VJob(name: "_ARGUMENTS") { e, fs, sets in
            try e.vjobSplit(fs, &sets, start: "ARG", others: ["ARGTYPE"], comment: "ARGCOMMENT")
        },
        VJob(name: "_RESULTS") { e, fs, sets in
            try e.vjobSplit(fs, &sets, start: "RESULT", others: ["RESULTTYPE"], comment: "RESULTCOMMENT")
        },
        VJob(name: "_VERSIONINFO") { e, fs, sets in
            if e.descriptionInfo == nil { e.descriptionInfo = try fs.readDescriptions() }
            var d: ResultSet = [:]
            func add(_ type: ResultType, _ name: String, _ v: ResultValue) { d[name] = ResultData(type: type, name: name, value: v) }
            let bip = e.versionInfo.bipVersion
            add(.typeS, "BIP_VERSION", .string("\((bip >> 16) & 0xFF).\((bip >> 8) & 0xFF).\(bip & 0xFF)"))
            add(.typeS, "AUTHOR", .string(e.versionInfo.author))
            add(.typeS, "REVISION", .string(e.versionInfo.revision))
            add(.typeS, "FROM", .string(e.versionInfo.from))
            add(.typeL, "PACKAGE", .int(e.versionInfo.package))
            var descCount = 0, usesCount = 0
            for desc in e.descriptionInfo?.globalComments ?? [] {
                guard let colon = desc.firstIndex(of: ":") else { continue }
                var key = String(desc[..<colon])
                let value = String(desc[desc.index(after: colon)...])
                if key.caseInsensitiveCompare("ECUCOMMENT") == .orderedSame { key += String(descCount); descCount += 1 }
                if key.caseInsensitiveCompare("USES") == .orderedSame { key += String(usesCount); usesCount += 1 }
                if d[key] == nil { add(.typeS, key, .string(value)) }
            }
            sets.append(d)
        },
        VJob(name: "_TABLES") { e, _, sets in
            for t in e.tableInfos.tables {
                sets.append(["TABLE": ResultData(type: .typeS, name: "TABLE", value: .string(t.name))])
            }
        },
        VJob(name: "_TABLE") { e, fs, sets in
            guard let name = e.activeArgStrings().first, let idx = e.tableInfos.nameDict[name.uppercased()] else { return }
            let table = e.tableInfos.tables[idx]
            try fs.indexTable(table)
            for row in table.entries ?? [] {
                var d: ResultSet = [:]
                for j in 0..<Int(table.columns) {
                    let s = try fs.tableString(at: row[j])
                    let n = "COLUMN\(j)"
                    d[n] = ResultData(type: .typeS, name: n, value: .string(s))
                }
                if !d.isEmpty { sets.append(d) }
            }
        },
    ]

    private func jobComments(_ fs: PrgFile) throws -> [String]? {
        guard let first = activeArgStrings().first else { return nil }
        if descriptionInfo == nil { descriptionInfo = try fs.readDescriptions() }
        return descriptionInfo?.jobComments[first.uppercased()]
    }

    private func vjobSplit(_ fs: PrgFile, _ sets: inout [ResultSet], start: String, others: [String], comment: String) throws {
        guard let jc = try jobComments(fs) else { return }
        var dict: ResultSet?
        var count = 0
        for desc in jc {
            guard let colon = desc.firstIndex(of: ":") else { continue }
            var key = String(desc[..<colon])
            let value = String(desc[desc.index(after: colon)...])
            if key.caseInsensitiveCompare(start) == .orderedSame {
                if let d = dict, !d.isEmpty { sets.append(d) }
                dict = [:]
                count = 0
            }
            guard dict != nil else { continue }
            if key.caseInsensitiveCompare(start) == .orderedSame ||
                others.contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                if dict![key] == nil { dict![key] = ResultData(type: .typeS, name: key, value: .string(value)) }
            }
            if key.caseInsensitiveCompare(comment) == .orderedSame {
                key += String(count); count += 1
                if dict![key] == nil { dict![key] = ResultData(type: .typeS, name: key, value: .string(value)) }
            }
        }
        if let d = dict, !d.isEmpty { sets.append(d) }
    }

    private func executeVJob(_ fs: PrgFile, _ vjob: VJob) throws {
        if requestInit && !noInitForVJobs { try executeInitJob() }
        resultSetsTemp = []
        apiLock.withLock { _resultSets = nil }
        setConfigProperty("BipEcuFile", ((sgbdFileName as NSString).deletingPathExtension as NSString).lastPathComponent)
        defer {
            let sys = createSystemResultDict(JobInfo(name: vjob.name, offset: 0, arraySize: 0, uses: nil), setCount: resultSetsTemp.count)
            resultSetsTemp.insert(sys, at: 0)
            apiLock.withLock { _resultSets = resultSetsTemp }
            setConfigProperty("BipEcuFile", nil)
        }
        var sets = resultSetsTemp
        try vjob.fn(self, fs, &sets)
        resultSetsTemp = sets
    }

    // MARK: lifecycle

    /// Runs the SGBD exit job (if needed) and releases all open files.
    public func closeAll() throws {
        try closeSgbd()
        closeAllUserFiles()
        closeTableFs()
    }
}

/// Simple byte stream for the fopen/fread opcodes.
final class UserFile {
    let data: [UInt8]
    var position = 0
    init(data: [UInt8]) { self.data = data }

    func readByte() -> Int {
        guard position < data.count else { return -1 }
        defer { position += 1 }
        return Int(data[position])
    }

    func readLine() -> String? {
        var out: [UInt8] = []
        var cur = -1
        while true {
            cur = readByte()
            if cur < 0 || cur == 13 || cur == 10 { break }
            out.append(UInt8(cur))
        }
        if cur < 0 { return nil }
        if cur == 13 {
            let next = readByte()
            if next >= 0 && next != 10 { position -= 1 }
        }
        return Cp1252.string(out)
    }

    func readLineLength() -> Int {
        var len = 0
        var cur = -1
        while true {
            cur = readByte()
            if cur < 0 || cur == 13 || cur == 10 { break }
            len += 1
        }
        if cur < 0 { return -1 }
        if cur == 13 {
            let next = readByte()
            if next >= 0 && next != 10 { position -= 1 }
        }
        return len
    }
}
