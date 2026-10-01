import Foundation

/// One entry of a BMW fault memory as returned by the standard `FS_LESEN` job.
public struct Fault: Identifiable, Hashable, Sendable {
    public var id: String { "\(code)-\(hex.map { String(format: "%02X", $0) }.joined())" }
    public let code: Int64
    public let location: String
    public let symptom: String
    public let presence: String
    public let warning: String
    public let ready: String
    public let hex: [UInt8]

    public var codeText: String { String(format: "0x%04X", code) }
}

public enum FaultReader {
    /// Extracts the faults from the result sets of `FS_LESEN` (set 0 is the system set).
    public static func parse(_ sets: [ResultSet]) -> [Fault] {
        var out: [Fault] = []
        for set in sets.dropFirst() {
            guard let nr = set["F_ORT_NR"]?.value.asInt else { continue }
            func text(_ key: String) -> String { set[key]?.value.asString ?? "" }
            out.append(Fault(code: nr,
                             location: text("F_ORT_TEXT"),
                             symptom: text("F_SYMPTOM_TEXT"),
                             presence: text("F_VORHANDEN_TEXT"),
                             warning: text("F_WARNUNG_TEXT"),
                             ready: text("F_READY_TEXT"),
                             hex: set["F_HEX_CODE"]?.value.asBytes ?? []))
        }
        return out
    }

    /// True if the job finished with JOB_STATUS = OKAY.
    public static func isOkay(_ sets: [ResultSet]) -> Bool {
        sets.dropFirst().contains { $0["JOB_STATUS"]?.value.asString?.uppercased() == "OKAY" }
    }
}
