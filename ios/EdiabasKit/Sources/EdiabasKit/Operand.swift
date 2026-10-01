import Foundation

public struct EdiabasFailure: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Raised EDIABAS error (EdiabasNetException).
public struct EdiabasNetException: Error, CustomStringConvertible {
    public let code: EdiabasError
    public var description: String { "Error occurred: \(code.text)" }
}

enum RegKind { case ab, i, l, f, s }

struct Register {
    let opcode: UInt8
    let kind: RegKind
    let index: Int

    var isFloat: Bool { kind == .f }
    var isString: Bool { kind == .s }
}

enum OpAddrMode: UInt8 {
    case none = 0, regS, regAb, regI, regL, imm8, imm16, imm32, immStr
    case idxImm, idxReg, idxRegImm, idxImmLenImm, idxImmLenReg, idxRegLenImm, idxRegLenReg
}

enum RawData {
    case value(UInt32)
    case float(Double)
    case bytes([UInt8])
}

let registerList: [Register] = {
    var list: [Register] = []
    for i in 0..<16 { list.append(Register(opcode: UInt8(i), kind: .ab, index: i)) }          // 0x00-0x0F
    for i in 0..<8 { list.append(Register(opcode: UInt8(0x10 + i), kind: .i, index: i)) }      // 0x10-0x17
    for i in 0..<4 { list.append(Register(opcode: UInt8(0x18 + i), kind: .l, index: i)) }      // 0x18-0x1B
    for i in 0..<8 { list.append(Register(opcode: UInt8(0x1C + i), kind: .s, index: i)) }      // 0x1C-0x23
    for i in 0..<8 { list.append(Register(opcode: UInt8(0x24 + i), kind: .f, index: i)) }      // 0x24-0x2B
    for i in 0..<8 { list.append(Register(opcode: UInt8(0x2C + i), kind: .s, index: 8 + i)) }  // 0x2C-0x33
    for i in 0..<16 { list.append(Register(opcode: UInt8(0x80 + i), kind: .ab, index: 16 + i)) } // 0x80-0x8F
    for i in 0..<8 { list.append(Register(opcode: UInt8(0x90 + i), kind: .i, index: 8 + i)) }   // 0x90-0x97
    for i in 0..<4 { list.append(Register(opcode: UInt8(0x98 + i), kind: .l, index: 4 + i)) }   // 0x98-0x9B
    return list
}()

func lookupRegister(_ opcode: UInt8) throws -> Register {
    let result: Register
    if opcode <= 0x33 {
        result = registerList[Int(opcode)]
    } else if opcode >= 0x80 {
        let index = Int(opcode) - 0x80 + 0x34
        guard index < registerList.count else { throw EdiabasFailure("GetRegister: Opcode out of range") }
        result = registerList[index]
    } else {
        throw EdiabasFailure("GetRegister: Opcode out of range")
    }
    guard result.opcode == opcode else { throw EdiabasFailure("GetRegister: Opcode mapping invalid") }
    return result
}

/// Backing store of one string register.
final class StringData {
    var length: UInt32 = 0
    var data: [UInt8]

    init(length: UInt32) { data = [UInt8](repeating: 0, count: Int(length)) }

    func newArrayLength(_ length: UInt32) {
        if Int(length) > data.count { data = [UInt8](repeating: 0, count: Int(length)) }
    }

    func getData(complete: Bool) -> [UInt8] {
        complete ? data : Array(data[0..<Int(length)])
    }

    func clear() {
        for i in data.indices { data[i] = 0 }
        length = 0
    }
}

struct Flags {
    var carry = false
    var zero = false
    var sign = false
    var overflow = false

    mutating func reset() { self = Flags() }

    mutating func update(_ value: UInt32, _ length: UInt32) throws {
        let valueMask: UInt32
        let signMask: UInt32
        switch length {
        case 1: valueMask = 0xFF; signMask = 0x80
        case 2: valueMask = 0xFFFF; signMask = 0x8000
        case 4: valueMask = 0xFFFF_FFFF; signMask = 0x8000_0000
        default: throw EdiabasFailure("Flags.UpdateFlags: Invalid length")
        }
        zero = (value & valueMask) == 0
        sign = (value & signMask) != 0
    }

    mutating func setOverflow(_ v1: UInt32, _ v2: UInt32, _ result: UInt32, _ length: UInt32) throws {
        let signMask: UInt64
        switch length {
        case 1: signMask = 0x80
        case 2: signMask = 0x8000
        case 4: signMask = 0x8000_0000
        default: throw EdiabasFailure("Flags.SetOverflow: Invalid length")
        }
        if (UInt64(v1) & signMask) != (UInt64(v2) & signMask) {
            overflow = false
        } else if (UInt64(v1) & signMask) == (UInt64(result) & signMask) {
            overflow = false
        } else {
            overflow = true
        }
    }

    mutating func setCarry(_ value: UInt64, _ length: UInt32) throws {
        let carryMask: UInt64
        switch length {
        case 1: carryMask = 0x100
        case 2: carryMask = 0x1_0000
        case 4: carryMask = 0x1_0000_0000
        default: throw EdiabasFailure("Flags.SetCarry: Invalid length")
        }
        carry = (value & carryMask) != 0
    }

    var asValue: UInt32 {
        (carry ? 1 : 0) | (zero ? 2 : 0) | (sign ? 4 : 0) | (overflow ? 8 : 0)
    }

    mutating func load(_ value: UInt32) {
        carry = value & 1 != 0
        zero = value & 2 != 0
        sign = value & 4 != 0
        overflow = value & 8 != 0
    }
}

/// One decoded instruction operand (port of EdiabasNet.Operand).
final class Operand {
    unowned let vm: Ediabas
    var mode: OpAddrMode = .none
    var reg: Register?        // OpData1 for register based modes
    var imm: UInt32 = 0       // OpData1 for Imm8/16/32
    var str: [UInt8] = []     // OpData1 for ImmStr
    var idxImm: UInt32 = 0    // OpData2 as immediate
    var idxReg: Register?     // OpData2 as register
    var lenImm: UInt32 = 0    // OpData3 as immediate
    var lenReg: Register?     // OpData3 as register

    init(vm: Ediabas) { self.vm = vm }

    func reset(_ mode: OpAddrMode) {
        self.mode = mode
        reg = nil; imm = 0; str = []; idxImm = 0; idxReg = nil; lenImm = 0; lenReg = nil
    }

    /// OpData1 is a register (all but None/Imm*).
    var isRegBased: Bool {
        switch mode {
        case .none, .imm8, .imm16, .imm32, .immStr: return false
        default: return true
        }
    }

    func requireReg(_ op: String) throws {
        if !isRegBased { throw EdiabasFailure("\(op): Invalid type") }
    }

    var isByteArrayType: Bool {
        switch mode {
        case .regS, .immStr, .idxImm, .idxReg, .idxRegImm, .idxImmLenImm, .idxImmLenReg, .idxRegLenImm, .idxRegLenReg:
            return true
        default: return false
        }
    }

    var isValueType: Bool { !isByteArrayType }

    func valueMask(_ dataLen: UInt32 = 0) throws -> UInt32 {
        let len = dataLen == 0 ? try getDataLen() : dataLen
        switch len {
        case 1: return 0xFF
        case 2: return 0xFFFF
        case 4: return 0xFFFF_FFFF
        default: throw EdiabasFailure("Operand.GetValueMask: Invalid length")
        }
    }

    func getDataLen(write: Bool = false) throws -> UInt32 {
        switch mode {
        case .regS, .immStr: return UInt32(try getArrayData().count)
        case .regAb, .imm8: return 1
        case .regI, .imm16: return 2
        case .regL, .imm32: return 4
        case .idxImm, .idxReg, .idxRegImm:
            return write ? 1 : UInt32(try getArrayData().count)
        case .idxImmLenImm, .idxImmLenReg, .idxRegLenImm, .idxRegLenReg:
            return UInt32(try getArrayData().count)
        case .none: return 0
        }
    }

    private func indexValue() throws -> UInt32 {
        switch mode {
        case .idxImm, .idxImmLenImm, .idxImmLenReg: return idxImm
        default:
            guard let r = idxReg else { throw EdiabasFailure("Operand: Invalid index") }
            return try vm.regValue(r)
        }
    }

    func getRawData() throws -> RawData {
        switch mode {
        case .regS, .regAb, .regI, .regL:
            guard let r = reg else { throw EdiabasFailure("Operand.GetRawData RegX: Invalid data type") }
            return try vm.regRaw(r)
        case .imm8, .imm16, .imm32:
            return .value(imm)
        case .immStr:
            return .bytes(str)
        case .idxImm, .idxReg, .idxRegImm:
            guard let r = reg else { throw EdiabasFailure("Operand.GetRawData IdxX: Invalid data type") }
            let dataArray = try vm.regArray(r, complete: true)
            var index = try indexValue()
            if mode == .idxRegImm { index = index &+ lenImm }
            let required = Int64(index) + 1
            if required > Int64(vm.arrayMaxSize) {
                try vm.setError(.EDIABAS_BIP_0001)
                return .bytes([])
            }
            if Int64(dataArray.count) < required { return .bytes([]) }
            return .bytes(Array(dataArray[Int(index)...]))
        case .idxImmLenImm, .idxImmLenReg, .idxRegLenImm, .idxRegLenReg:
            guard let r = reg else { throw EdiabasFailure("Operand.GetRawData IdxXLenX: Invalid data type") }
            let dataArray = try vm.regArray(r, complete: true)
            let index = try indexValue()
            var len: UInt32
            if mode == .idxImmLenImm || mode == .idxRegLenImm {
                len = lenImm
            } else {
                guard let lr = lenReg else { throw EdiabasFailure("Operand.GetRawData IdxXLenX: Invalid data type") }
                len = try vm.regValue(lr)
            }
            let required = UInt64(index) + UInt64(len)
            if required > UInt64(vm.arrayMaxSize) {
                try vm.setError(.EDIABAS_BIP_0001)
                return .bytes([])
            }
            if Int64(dataArray.count) < Int64(required) {
                if dataArray.count <= Int(index) { return .bytes([]) }
                len = UInt32(dataArray.count) - index
            }
            return .bytes(Array(dataArray[Int(index)..<Int(index + len)]))
        case .none:
            throw EdiabasFailure("Operand.GetRawData: Invalid address mode")
        }
    }

    func getValueData(_ dataLen: UInt32 = 0) throws -> UInt32 {
        switch try getRawData() {
        case .value(let v):
            return v & (try valueMask())
        case .float:
            throw EdiabasFailure("Operand.GetValueData: Invalid data type")
        case .bytes(var arr):
            if dataLen == 0 { throw EdiabasFailure("Operand.GetValueData: Invalid data length") }
            if arr.count < Int(dataLen) { arr += [UInt8](repeating: 0, count: Int(dataLen) - arr.count) }
            var value: UInt32 = 0
            for i in stride(from: Int(dataLen) - 1, through: 0, by: -1) {
                value = (value << 8) | UInt32(arr[i])
            }
            return value
        }
    }

    func getFloatData() throws -> Double {
        if case .float(let f) = try getRawData() { return f }
        throw EdiabasFailure("Operand.GetFloatData: Invalid data type")
    }

    func getArrayData() throws -> [UInt8] {
        if case .bytes(let b) = try getRawData() { return b }
        throw EdiabasFailure("Operand.GetArrayData: Invalid data type")
    }

    func getStringData() throws -> String {
        let data = try getArrayData()
        let end = data.firstIndex(of: 0) ?? data.count
        return Cp1252.string(Array(data[0..<end]))
    }

    func setRawData(_ data: RawData, dataLen: UInt32 = 1) throws {
        switch mode {
        case .regS, .regAb, .regI, .regL:
            guard let r = reg else { throw EdiabasFailure("Operand.SetRawData RegX: Invalid data type") }
            try vm.setRegRaw(r, data)
        case .idxImm, .idxReg, .idxRegImm:
            if case .float = data { throw EdiabasFailure("Operand.SetRawData IdxX: Invalid input data type") }
            guard let r = reg else { throw EdiabasFailure("Operand.SetRawData IdxX: Invalid data type") }
            var dataArray = try vm.regArray(r, complete: false)
            var index = try indexValue()
            if mode == .idxRegImm { index = index &+ lenImm }
            let len: UInt32
            let source: [UInt8]
            switch data {
            case .value(let v):
                len = dataLen
                source = (0..<Int(len)).map { UInt8(truncatingIfNeeded: v >> UInt32($0 << 3)) }
            case .bytes(let b):
                source = b
                len = UInt32(b.count)
            case .float:
                throw EdiabasFailure("Operand.SetRawData IdxX: Invalid input data type")
            }
            let required = index &+ len
            if required > vm.arrayMaxSize {
                try vm.setError(.EDIABAS_BIP_0001)
                return
            }
            if dataArray.count < Int(required) {
                dataArray += [UInt8](repeating: 0, count: Int(required) - dataArray.count)
            }
            for i in 0..<Int(len) { dataArray[Int(index) + i] = source[i] }
            try vm.setRegRaw(r, .bytes(dataArray))
        default:
            throw EdiabasFailure("Operand.SetRawData: Invalid address mode")
        }
    }

    func setValue(_ v: UInt32, dataLen: UInt32 = 1) throws { try setRawData(.value(v), dataLen: dataLen) }
    func setFloat(_ f: Double) throws { try setRawData(.float(f)) }

    func setArrayData(_ data: [UInt8]) throws {
        guard let r = reg, mode == .regS else { throw EdiabasFailure("Operand.SetArrayData: Invalid address mode") }
        try vm.setRegRaw(r, .bytes(data))
    }

    func setStringData(_ s: String) throws {
        var data = Cp1252.bytes(s)
        if let last = data.last, last != 0 { data.append(0) }
        try setArrayData(data)
    }
}
