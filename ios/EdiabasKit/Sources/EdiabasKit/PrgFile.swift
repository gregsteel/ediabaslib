import Foundation

/// In-memory view of a BEST/2 ".prg" or ".grp" file. Mirrors the Stream based access of EdiabasNet:
/// header words are stored plain, everything else is XOR 0xF7 encrypted.
final class PrgFile {
    let bytes: [UInt8]
    var position: Int = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    convenience init(contentsOf url: URL) throws {
        self.init(bytes: [UInt8](try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    var length: Int { bytes.count }

    private func need(_ count: Int) throws {
        guard position >= 0, position + count <= bytes.count else { throw EdiabasFailure("EndOfStream") }
    }

    /// Plain little endian Int32 (header fields).
    func readInt32() throws -> Int32 {
        try need(4)
        let v = UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8 | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
        position += 4
        return Int32(bitPattern: v)
    }

    func readInt32(at offset: Int) throws -> Int32 {
        position = offset
        return try readInt32()
    }

    func readDecrypted(_ count: Int) throws -> [UInt8] {
        try need(count)
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = bytes[position + i] ^ 0xF7 }
        position += count
        return out
    }

    func readDecryptedByte() throws -> UInt8 {
        try need(1)
        defer { position += 1 }
        return bytes[position] ^ 0xF7
    }

    static func le16(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 }
    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func trimNul(_ b: ArraySlice<UInt8>) -> String {
        var s = b
        while let l = s.last, l == 0 { s = s.dropLast() }
        return Cp1252.string(Array(s))
    }

    // MARK: header structures

    /// File type word at offset 0x10: 0 = group file (.grp), otherwise SGBD.
    func fileType() throws -> UInt32 {
        UInt32(bitPattern: try readInt32(at: 0x10))
    }

    func readUses() throws -> [UsesInfo] {
        let offset = try readInt32(at: 0x7C)
        if offset < 0 { return [] }
        position = Int(offset)
        let count = Int(try readInt32())
        var list: [UsesInfo] = []
        for _ in 0..<count {
            let b = try readDecrypted(0x100)
            list.append(UsesInfo(name: Self.trimNul(b[0..<0x100])))
        }
        return list
    }

    func readVersionInfo() throws -> VersionInfo {
        var info = VersionInfo()
        let offset = try readInt32(at: 0x94)
        if offset < 0 { return info }
        position = Int(offset)
        let b = try readDecrypted(0x6C)
        info.bipVersion = Int64(b[2]) << 16 | Int64(b[1]) << 8 | Int64(b[0])
        info.author = Self.trimNul(b[0x08..<0x48])
        let rev1 = Int16(bitPattern: UInt16(Self.le16(b, 0x06)))
        let rev2 = Int16(bitPattern: UInt16(Self.le16(b, 0x04)))
        info.revision = "\(rev1).\(rev2)"
        info.from = Self.trimNul(b[0x48..<0x68])
        info.package = Int64(Int32(bitPattern: Self.le32(b, 0x68)))
        return info
    }

    func readDescriptions() throws -> DescriptionInfo {
        var info = DescriptionInfo()
        let offset = try readInt32(at: 0x90)
        if offset < 0 { return info }
        position = Int(offset)
        let numBytes = Int(try readInt32())

        var commentList: [String] = []
        var previousJobName: String?
        var record = [UInt8](repeating: 0, count: 1100)
        var recordOffset = 0
        func flush() {
            if previousJobName == nil {
                info.globalComments = commentList
            } else if info.jobComments[previousJobName!] == nil {
                info.jobComments[previousJobName!] = commentList
            }
        }
        for _ in 0..<numBytes {
            record[recordOffset] = try readDecryptedByte()
            recordOffset += 1
            if recordOffset >= 1098 {
                record[recordOffset] = 10
                recordOffset += 1
            }
            if record[recordOffset - 1] == 10 {
                let comment = Cp1252.string(Array(record[0..<(recordOffset - 1)]))
                if comment.uppercased().hasPrefix("JOBNAME:") {
                    flush()
                    commentList = []
                    previousJobName = String(comment.dropFirst(8))
                }
                commentList.append(comment)
                recordOffset = 0
            }
        }
        flush()
        return info
    }

    /// Reads the job directory of this file. `usesInfo` is set for jobs of a base ("uses") file.
    func readJobList(usesInfo: UsesInfo?) throws -> [JobInfo] {
        position = 0x18
        var arraySize = UInt32(bitPattern: try readInt32())
        if arraySize == 0 { arraySize = 1024 }
        let listOffset = try readInt32(at: 0x88)
        if listOffset < 0 { return [] }
        position = Int(listOffset)
        let numJobs = Int(try readInt32())
        var jobStart = position
        var list: [JobInfo] = []
        list.reserveCapacity(numJobs)
        for _ in 0..<numJobs {
            position = jobStart
            let b = try readDecrypted(0x44)
            let name = Self.trimNul(b[0..<0x40])
            let address = Self.le32(b, 0x40)
            list.append(JobInfo(name: name, offset: address, arraySize: arraySize, uses: usesInfo))
            jobStart += 0x44
        }
        return list
    }

    func readTables() throws -> TableInfos {
        var infos = TableInfos()
        let offset = try readInt32(at: 0x84)
        if offset < 0 { return infos }
        position = Int(offset)
        let countBytes = try readDecrypted(4)
        let count = Int(Int32(bitPattern: Self.le32(countBytes, 0)))
        var tableStart = position
        for i in 0..<count {
            position = tableStart
            let b = try readDecrypted(0x50)
            let name = Self.trimNul(b[0..<0x40])
            let table = TableInfo(name: name,
                                  columnOffset: Self.le32(b, 0x40),
                                  columns: Self.le32(b, 0x48),
                                  rows: Self.le32(b, 0x4C))
            infos.tables.append(table)
            infos.nameDict[name.uppercased()] = i
            tableStart += 0x50
        }
        return infos
    }

    /// Reads the null terminated, encrypted string at `offset` (max 1024 bytes like the reference).
    func tableString(at offset: UInt32) throws -> String {
        position = Int(offset)
        var out: [UInt8] = []
        while out.count < 1024 {
            let b = try readDecryptedByte()
            if b == 0 { break }
            out.append(b)
        }
        return Cp1252.string(out)
    }

    func indexTable(_ table: TableInfo) throws {
        if table.entries != nil { return }
        position = Int(table.columnOffset)
        var columnNames: [String: Int] = [:]
        var entries: [[UInt32]] = []
        let cols = Int(table.columns)
        for j in 0..<(Int(table.rows) + 1) {
            var row = [UInt32](repeating: 0, count: cols)
            for k in 0..<cols {
                row[k] = UInt32(position)
                var buf: [UInt8] = []
                while buf.count < 1024 {
                    let b = try readDecryptedByte()
                    if b == 0 { break }
                    buf.append(b)
                }
                if j == 0 {
                    columnNames[Cp1252.string(buf).uppercased()] = k
                }
            }
            entries.append(row)
        }
        table.columnNames = columnNames
        table.entries = entries
    }
}

struct UsesInfo { let name: String }

struct VersionInfo {
    var bipVersion: Int64 = 0
    var author = ""
    var from = ""
    var revision = ""
    var package: Int64 = 0
}

struct DescriptionInfo {
    var globalComments: [String] = []
    var jobComments: [String: [String]] = [:]
}

struct JobInfo {
    let name: String
    let offset: UInt32
    let arraySize: UInt32
    let uses: UsesInfo?
}

final class TableInfo {
    let name: String
    let columnOffset: UInt32
    let columns: UInt32
    let rows: UInt32
    var columnNames: [String: Int] = [:]
    var entries: [[UInt32]]?
    var seekStrings: [Int: [String: UInt32]] = [:]
    var seekValues: [Int: [UInt32: UInt32]] = [:]

    init(name: String, columnOffset: UInt32, columns: UInt32, rows: UInt32) {
        self.name = name
        self.columnOffset = columnOffset
        self.columns = columns
        self.rows = rows
    }
}

struct TableInfos {
    var tables: [TableInfo] = []
    var nameDict: [String: Int] = [:]
}
