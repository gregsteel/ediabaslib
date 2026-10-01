import Foundation

/// Windows-1252 text coding used by all EDIABAS files and job strings.
enum Cp1252 {
    static func string(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .windowsCP1252) ?? String(bytes.map { Character(UnicodeScalar($0)) })
    }

    static func bytes(_ s: String) -> [UInt8] {
        if let d = s.data(using: .windowsCP1252, allowLossyConversion: true) { return [UInt8](d) }
        return Array(s.utf8)
    }
}

/// Port of EdiabasNet.StringToValue: "0x" hex, "0y" binary, decimal (fraction cut off).
func ediParseValue(_ number: String) -> (value: Int64, valid: Bool) {
    var trimmed = number
    while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
    if trimmed.isEmpty { return (0, false) }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("0x") {
        guard lower.count > 2 else { return (0, false) }
        let first = lower[lower.index(lower.startIndex, offsetBy: 2)]
        if first.isASCII && (first.isNumber || ("a"..."f").contains(first)) {
            if let v = Int64(trimmed.dropFirst(2), radix: 16) { return (v, true) }
        }
        return (0, false)
    }
    if lower.hasPrefix("0y") {
        if let v = Int64(trimmed.dropFirst(2), radix: 2) { return (v, true) }
        return (0, false)
    }
    if lower == "-" || lower == "--" { return (0, false) }
    if let f = lower.first, f.isLetter { return (0, false) }
    var conv = Substring(trimmed)
    while let f = conv.first, f.isWhitespace { conv = conv.dropFirst() }
    if let idx = conv.firstIndex(where: { $0 == "." || $0 == "," }) { conv = conv[..<idx] }
    if let v = Int64(conv, radix: 10) { return (v, true) }
    return (0, false)
}

func ediStringToValue(_ number: String) -> Int64 { ediParseValue(number).value }

func ediStringToFloat(_ number: String) -> (value: Double, valid: Bool) {
    guard number.unicodeScalars.allSatisfy({ $0.isASCII }) else { return (0, false) }
    let s = number.replacingOccurrences(of: ",", with: ".")
    if let v = Double(s.trimmingCharacters(in: .whitespaces)) { return (v, true) }
    return (0, false)
}

func ediHexToBytes(_ s: String) -> [UInt8] {
    let chars = Array(s.utf8)
    let length = chars.count - chars.count % 2
    var out: [UInt8] = []
    var i = 0
    while i < length {
        guard let v = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return [] }
        out.append(v)
        i += 2
    }
    return out
}

func ediValueToBcd(_ value: UInt8) -> String {
    func nib(_ n: Int) -> String { n > 9 ? "*" : String(n, radix: 16, uppercase: true) }
    return nib(Int(value >> 4) & 0xF) + nib(Int(value) & 0xF)
}

func hex2(_ v: UInt32) -> String { String(format: "%02X", v) }
func hex4(_ v: UInt32) -> String { String(format: "%04X", v) }
func hex8(_ v: UInt32) -> String { String(format: "%08X", v) }

func roundToSignificantDigits(_ value: Double, _ digits: UInt32) -> Double {
    if value == 0 { return 0 }
    let scale = pow(10, (log10(abs(value))).rounded(.down) + 1)
    let factor = pow(10, Double(digits))
    return scale * ((value / scale) * factor).rounded(.toNearestOrEven) / factor
}
