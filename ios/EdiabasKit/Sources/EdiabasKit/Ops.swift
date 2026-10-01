import Foundation

typealias OpFn = (Ediabas, Operand, Operand) throws -> Void

private func argsLen(_ a0: Operand) throws -> UInt32 { try a0.getDataLen(write: true) }

private func s8(_ v: UInt32) -> Int32 { Int32(Int8(truncatingIfNeeded: v)) }
private func s16(_ v: UInt32) -> Int32 { Int32(Int16(truncatingIfNeeded: v)) }
private func s32(_ v: UInt32) -> Int32 { Int32(bitPattern: v) }
private func u32(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }

/// Truncating double -> integer conversion like an unchecked C# cast.
private func dblToU32(_ d: Double) -> UInt32 {
    if d.isNaN { return 0 }
    if d >= 0 { return d >= 4294967296.0 ? 0 : UInt32(d) }
    if d <= -2147483649.0 { return 0 }
    return u32(Int32(d))
}

private func cond(_ f: @escaping (Flags) -> Bool) -> OpFn {
    { e, a0, _ in if f(e.flags) { e.pcCounter = try a0.getValueData() } }
}

private func floatBin(_ name: String, _ op: @escaping (Double, Double) -> Double) -> OpFn {
    { e, a0, a1 in
        try a0.requireReg(name)
        let r = op(try a0.getFloatData(), try a1.getFloatData())
        if r.isInfinite || r.isNaN { try e.setError(.EDIABAS_BIP_0011) }
        try a0.setFloat(r)
    }
}

private func needIface(_ e: Ediabas, connected: Bool) throws -> EdInterface? {
    guard let i = e.interface, !connected || i.connected else {
        try e.setError(.EDIABAS_IFH_0056)
        return nil
    }
    return i
}

private func shiftOp(_ name: String, _ kind: Int) -> OpFn {
    // kind: 0 = lsl/asl, 1 = lsr, 2 = asr
    { e, a0, a1 in
        try a0.requireReg(name)
        let len = try argsLen(a0)
        var value = try a0.getValueData(len)
        let shift = Int32(bitPattern: try a1.getValueData(len))
        let bits = Int32(len) * 8
        if shift < 0 {
        } else if shift == 0 {
            e.flags.carry = false
        } else {
            switch kind {
            case 0:
                if shift > bits { e.flags.carry = false } else {
                    e.flags.carry = (value & (UInt32(1) &<< UInt32(bits - shift))) != 0
                }
                value = shift >= bits ? 0 : value << UInt32(shift)
            case 1:
                if shift > bits { e.flags.carry = false } else {
                    e.flags.carry = (value & (UInt32(1) &<< UInt32(shift - 1))) != 0
                }
                value = shift >= bits ? 0 : value >> UInt32(shift)
            default:
                if shift > bits {
                    e.flags.carry = (value & (UInt32(1) &<< UInt32(bits - 1))) != 0
                } else {
                    e.flags.carry = (value & (UInt32(1) &<< UInt32(shift - 1))) != 0
                }
                if shift >= bits {
                    value = (value & (UInt32(1) &<< UInt32(bits - 1))) != 0 ? 0xFFFF_FFFF : 0
                } else {
                    switch len {
                    case 1: value = u32(s8(value) >> shift)
                    case 2: value = u32(s16(value) >> shift)
                    case 4: value = u32(s32(value) >> shift)
                    default: throw EdiabasFailure("\(name): Invalid length")
                    }
                }
            }
        }
        try a0.setValue(value)
        e.flags.overflow = false
        try e.flags.update(value, len)
    }
}

private func logic(_ name: String, _ f: @escaping (UInt32, UInt32) -> UInt32) -> OpFn {
    { e, a0, a1 in
        try a0.requireReg(name)
        let len = try argsLen(a0)
        let v = f(try a0.getValueData(len), try a1.getValueData(len))
        try a0.setValue(v)
        e.flags.overflow = false
        try e.flags.update(v, len)
    }
}

private func ergOp(_ type: ResultType, _ conv: @escaping (Operand) throws -> ResultValue) -> OpFn {
    { e, a0, a1 in e.setResultData(ResultData(type: type, name: try a0.getStringData(), value: try conv(a1))) }
}

private func fix2str(_ name: String, signed: Bool) -> OpFn {
    { e, a0, a1 in
        try a0.requireReg(name)
        let len = !a1.isValueType ? 1 : try a1.getDataLen()
        let v = try a1.getValueData(len)
        let s: String
        switch len {
        case 1: s = signed ? "\(Int8(truncatingIfNeeded: v))" : "\(UInt8(truncatingIfNeeded: v))"
        case 2: s = signed ? "\(Int16(truncatingIfNeeded: v))" : "\(UInt16(truncatingIfNeeded: v))"
        case 4: s = signed ? "\(Int32(bitPattern: v))" : "\(v)"
        default: throw EdiabasFailure("\(name): Invalid length")
        }
        try a0.setStringData(s)
    }
}

private func idxStart(_ a0: Operand, _ vm: Ediabas, _ op: String) throws -> UInt32 {
    switch a0.mode {
    case .idxImm: return a0.idxImm
    case .idxReg:
        guard let r = a0.idxReg else { throw EdiabasFailure("\(op): Invalid mode") }
        return try vm.regValue(r)
    default: throw EdiabasFailure("\(op): Invalid mode")
    }
}

private func isoWeek(_ d: Date) -> Int {
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = .current
    return cal.component(.weekOfYear, from: d)
}

extension Ediabas {
    static let ocList: [OpCode] = {
        var l: [OpCode] = []
        func add(_ name: String, _ fn: OpFn?, near: Bool = false) { l.append(OpCode(name: name, fn: fn, arg0IsNearAddress: near)) }

        add("move", opMove)
        add("clear") { e, a0, _ in
            try a0.requireReg("OpClear")
            guard let r = a0.reg else { throw EdiabasFailure("OpClear: Invalid type") }
            switch r.kind {
            case .s: try e.clearReg(r)
            case .f: e.floatRegisters[r.index] = 0
            default: try e.setRegValue(r, 0)
            }
            e.flags.carry = false; e.flags.zero = true; e.flags.sign = false; e.flags.overflow = false
        }
        add("comp") { e, a0, a1 in
            let len = try argsLen(a0)
            let v0 = try a0.getValueData(len), v1 = try a1.getValueData(len)
            let diff = UInt64(v0) &- UInt64(v1)
            try e.flags.update(UInt32(truncatingIfNeeded: diff), len)
            try e.flags.setOverflow(v0, 0 &- v1, UInt32(truncatingIfNeeded: diff), len)
            try e.flags.setCarry(diff, len)
        }
        add("subb", subOp(withCarry: false, name: "OpSubb"))
        add("adds", addOp(withCarry: false, name: "OpAdds"))
        add("mult") { e, a0, a1 in
            try a0.requireReg("OpMult")
            let len = try argsLen(a0)
            let v1 = try a0.getValueData(len), v2 = try a1.getValueData(len)
            let result: UInt32
            switch len {
            case 1: result = u32(s8(v1) &* s8(v2))
            case 2: result = u32(s16(v1) &* s16(v2))
            case 4: result = u32(s32(v1) &* s32(v2))
            default: throw EdiabasFailure("OpMult mult failure")
            }
            try a0.setValue(result)
            e.flags.overflow = false
            try e.flags.update(result, len)
            if a1.isRegBased {
                let high = UInt32(truncatingIfNeeded: UInt64(result) >> UInt64(len << 3))
                try a1.setValue(high, dataLen: len)
            }
        }
        add("divs") { e, a0, a1 in
            try a0.requireReg("OpDivs")
            let len = try argsLen(a0)
            let v1 = try a0.getValueData(len), v2 = try a1.getValueData(len)
            var result: UInt32 = 0, remainder: UInt32 = 0
            guard len == 1 || len == 2 || len == 4 else { throw EdiabasFailure("OpDivs: Invalid length") }
            let n = s32(v1), d = s32(v2)
            if d == 0 || (n == Int32.min && d == -1) {
                try e.raiseError(.EDIABAS_BIP_0007)
            }
            result = u32(n / d)
            remainder = u32(n % d)
            e.flags.overflow = false
            try e.flags.update(result, len)
            try a0.setValue(result)
            if a1.isRegBased { try a1.setValue(remainder, dataLen: len) }
        }
        add("and", logic("OpAnd") { $0 & $1 })
        add("or", logic("OpOr") { $0 | $1 })
        add("xor", logic("OpXor") { $0 ^ $1 })
        add("not") { e, a0, _ in
            try a0.requireReg("OpNot")
            try a0.setValue(~(try a0.getValueData()))
            e.flags.overflow = false
            try e.flags.update(try a0.getValueData(), try a0.getDataLen())
        }
        add("jump", { e, a0, _ in e.pcCounter = try a0.getValueData() }, near: true)
        add("jtsr", nil, near: true)
        add("ret", nil)
        add("jc", cond { $0.carry }, near: true)
        add("jae", cond { !$0.carry }, near: true)
        add("jz", cond { $0.zero }, near: true)
        add("jnz", cond { !$0.zero }, near: true)
        add("jv", cond { $0.overflow }, near: true)
        add("jnv", cond { !$0.overflow }, near: true)
        add("jmi", cond { $0.sign }, near: true)
        add("jpl", cond { !$0.sign }, near: true)
        add("clrc") { e, _, _ in e.flags.carry = false }
        add("setc") { e, _, _ in e.flags.carry = true }
        add("asr", shiftOp("OpAsr", 2))
        add("lsl", shiftOp("OpLsl", 0))
        add("lsr", shiftOp("OpLsr", 1))
        add("asl", shiftOp("OpAsl", 0))
        add("nop") { _, _, _ in }
        add("eoj") { e, a0, _ in
            if a0.mode != .none { e.resultJobStatus = try a0.getStringData() }
            e.jobEnd = true
        }
        add("push") { e, a0, _ in
            var v = try a0.getValueData()
            let len = try a0.getDataLen()
            for _ in 0..<Int(len) { e.stack.append(UInt8(truncatingIfNeeded: v)); v >>= 8 }
        }
        add("pop") { e, a0, _ in
            try a0.requireReg("OpPop")
            guard a0.isValueType else { throw EdiabasFailure("OpPop: Invalid data type") }
            var v: UInt32 = 0
            let len = try a0.getDataLen()
            if e.stack.count < Int(len) {
                try e.setError(.EDIABAS_BIP_0005)
            } else {
                for _ in 0..<Int(len) { v = (v << 8) | UInt32(e.stack.removeLast()) }
            }
            try a0.setValue(v)
            e.flags.overflow = false
            try e.flags.update(v, len)
        }
        add("scmp") { e, a0, a1 in e.flags.zero = try a0.getArrayData() == a1.getArrayData() }
        add("scat") { e, a0, a1 in
            try a0.requireReg("OpScat")
            let r = try a0.getArrayData() + a1.getArrayData()
            if r.count > Int(e.arrayMaxSize) { try e.setError(.EDIABAS_BIP_0001); return }
            try a0.setRawData(.bytes(r))
        }
        add("scut") { e, a0, a1 in
            try a0.requireReg("OpScut")
            let data = try a0.getArrayData()
            let len = try a1.getValueData()
            if Int(len) > data.count { try a0.setArrayData([]) } else {
                try a0.setArrayData(Array(data[0..<(data.count - Int(len))]))
            }
        }
        add("slen") { e, a0, a1 in
            try a0.requireReg("OpSlen")
            try a0.setValue(try a1.getDataLen())
            e.flags.overflow = false
            try e.flags.update(try a0.getValueData(), try a0.getDataLen())
        }
        add("spaste") { e, a0, a1 in
            try a0.requireReg("OpSpaste")
            let start = try idxStart(a0, e, "OpSpaste")
            guard let r = a0.reg else { return }
            let dest = try e.regArray(r, complete: false)
            let src = try a1.getArrayData()
            if start >= e.arrayMaxSize { try e.setError(.EDIABAS_BIP_0001); return }
            if Int(start) < dest.count {
                let res = Array(dest[0..<Int(start)]) + src + Array(dest[Int(start)...])
                if res.count > Int(e.arrayMaxSize) { try e.setError(.EDIABAS_BIP_0001); return }
                try e.setRegArray(r, res)
            }
        }
        add("serase") { e, a0, a1 in
            try a0.requireReg("OpSerase")
            let start = Int(try idxStart(a0, e, "OpSerase"))
            guard let r = a0.reg else { return }
            let data = try e.regArray(r, complete: false)
            let len = Int(try a1.getValueData())
            var res: [UInt8] = []
            for (i, b) in data.enumerated() where i < start || i >= start + len { res.append(b) }
            try e.setRegArray(r, res)
        }
        add("xconnect") { e, _, _ in
            guard let i = e.interface else { throw EdiabasFailure("OpXconnect: No communication class present") }
            _ = try i.interfaceConnect()
        }
        add("xhangup") { e, _, _ in
            guard let i = e.interface else { throw EdiabasFailure("OpXhangup: No communication class present") }
            _ = try i.interfaceDisconnect()
        }
        add("xsetpar") { e, a0, _ in
            guard let i = try needIface(e, connected: true) else { return }
            let data = try a0.getArrayData()
            var typeLen = 0
            if data.count >= 2 {
                switch data[1] {
                case 0x00: typeLen = 2
                case 0x01: typeLen = 4
                case 0xFF: typeLen = 1
                default: break
                }
            }
            var pars: [UInt32] = []
            if typeLen > 0 && data.count % typeLen == 0 {
                for n in 0..<(data.count / typeLen) {
                    let o = n * typeLen
                    var v = UInt32(data[o])
                    if typeLen >= 2 { v |= UInt32(data[o + 1]) << 8 }
                    if typeLen >= 4 { v |= UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24 }
                    pars.append(v)
                }
            }
            i.commParameter = pars
        }
        add("xawlen") { e, a0, _ in
            guard let i = try needIface(e, connected: true) else { return }
            let data = try a0.getArrayData()
            guard data.count & 1 == 0 else { throw EdiabasFailure("OpXawlen: Invalid data length") }
            var answer: [Int16] = []
            for n in 0..<(data.count / 2) {
                let lo = UInt16(data[n * 2])
                let hi = UInt16(data[n * 2 + 1]) << 8
                answer.append(Int16(bitPattern: lo | hi))
            }
            i.commAnswerLen = answer
        }
        add("xsend") { e, a0, a1 in
            try a0.requireReg("OpXsend")
            guard let i = try needIface(e, connected: true) else { return }
            if let resp = try i.transmitData(try a1.getArrayData()) { try a0.setRawData(.bytes(resp)) }
        }
        add("xsendf") { e, a0, _ in
            guard let i = try needIface(e, connected: true) else { return }
            _ = try i.transmitFrequent(try a0.getArrayData())
        }
        add("xrequf") { e, a0, _ in
            try a0.requireReg("OpXrequf")
            guard let i = try needIface(e, connected: true) else { return }
            if let r = try i.receiveFrequent() { try a0.setRawData(.bytes(r)) }
        }
        add("xstopf") { e, _, _ in
            guard let i = try needIface(e, connected: true) else { return }
            _ = try i.stopFrequent()
        }
        add("xkeyb") { e, a0, _ in
            try a0.requireReg("OpXkeyb")
            guard let i = try needIface(e, connected: false) else { return }
            if let k = i.keyBytes { try a0.setRawData(.bytes(k)) }
        }
        add("xstate") { e, a0, _ in
            try a0.requireReg("OpXstate")
            guard let i = try needIface(e, connected: false) else { return }
            if let s = i.state { try a0.setRawData(.bytes(s)) }
        }
        add("xboot") { e, _, _ in
            guard let i = try needIface(e, connected: false) else { return }
            _ = try i.interfaceBoot()
        }
        add("xreset") { e, _, _ in
            guard let i = try needIface(e, connected: false) else { return }
            _ = try i.interfaceReset()
        }
        add("xtype") { e, a0, _ in
            try a0.requireReg("OpXtype")
            guard let i = try needIface(e, connected: true) else { return }
            try a0.setStringData(i.interfaceType)
        }
        add("xvers") { e, a0, _ in
            try a0.requireReg("OpXvers")
            guard let i = try needIface(e, connected: true) else { return }
            try a0.setValue(i.interfaceVersion)
        }
        add("ergb", ergOp(.typeB) { .int(Int64(UInt8(truncatingIfNeeded: try $0.getValueData(1)))) })
        add("ergw", ergOp(.typeW) { .int(Int64(UInt16(truncatingIfNeeded: try $0.getValueData(2)))) })
        add("ergd", ergOp(.typeD) { .int(Int64(try $0.getValueData(4))) })
        add("ergi", ergOp(.typeI) { .int(Int64(Int16(truncatingIfNeeded: try $0.getValueData(2)))) })
        add("ergr", ergOp(.typeR) { .double(try $0.getFloatData()) })
        add("ergs", ergOp(.typeS) { .string(try $0.getStringData()) })
        add("a2flt") { e, a0, a1 in
            try a0.requireReg("OpA2flt")
            let r = ediStringToFloat(try a1.getStringData())
            if !r.valid {
                var compat: Int64 = 0
                if let p = e.getConfigProperty("CompatMode") { compat = ediStringToValue(p) }
                if compat == 0 { try e.raiseError(.EDIABAS_BIP_0011) }
            }
            try a0.setFloat(r.value)
        }
        add("fadd", floatBin("OpFadd") { $0 + $1 })
        add("fsub", floatBin("OpFsub") { $0 - $1 })
        add("fmul", floatBin("OpFmul") { $0 * $1 })
        add("fdiv", floatBin("OpFdiv") { $0 / $1 })
        add("ergy", ergOp(.typeY) { .bytes(try $0.getArrayData()) })
        add("enewset") { e, _, _ in
            if !e.resultDict.isEmpty {
                e.resultSetsTemp.append(e.resultDict)
                e.resultDict.removeAll()
            }
        }
        add("etag", { e, a0, a1 in
            if let requested = e.isResultRequested(try a1.getStringData().uppercased()), !requested {
                e.pcCounter = try a0.getValueData()
            }
        }, near: true)
        add("xreps") { e, a0, _ in
            guard let i = try needIface(e, connected: true) else { return }
            i.commRepeats = try a0.getValueData()
        }
        add("gettmr") { e, a0, _ in
            try a0.requireReg("OpGettmr")
            try a0.setValue(e.errorTrapMask)
            try e.flags.update(try a0.getValueData(), try a0.getDataLen())
        }
        add("settmr") { e, a0, _ in e.errorTrapMask = try a0.getValueData() }
        add("sett") { e, a0, _ in
            var error = try a0.getValueData()
            if error == 0 { error = 0x4000_0000 }
            e.errorTrapBitNr = Int(Int32(bitPattern: error))
        }
        add("clrt") { e, _, _ in e.errorTrapBitNr = -1 }
        add("jt", trapJump(invert: false), near: true)
        add("jnt", trapJump(invert: true), near: true)
        add("addc", addOp(withCarry: true, name: "OpAddc"))
        add("subc", subOp(withCarry: true, name: "OpSubc"))
        add("break") { e, _, _ in try e.setError(.EDIABAS_BIP_0008) }
        add("clrv") { e, _, _ in e.flags.overflow = false }
        add("eerr") { e, _, _ in
            if e.errorTrapBitNr >= 0 {
                for (key, bit) in Ediabas.trapBits where bit == e.errorTrapBitNr { try e.raiseError(key) }
                try e.raiseError(.EDIABAS_BIP_0000)
            }
        }
        add("popf") { e, _, _ in
            var v: UInt32 = 0
            if e.stack.count < 4 { try e.setError(.EDIABAS_BIP_0005) } else {
                for _ in 0..<4 { v = (v << 8) | UInt32(e.stack.removeLast()) }
            }
            e.flags.load(v)
        }
        add("pushf") { e, _, _ in
            var v = e.flags.asValue
            for _ in 0..<4 { e.stack.append(UInt8(truncatingIfNeeded: v)); v >>= 8 }
        }
        add("atsp") { e, a0, a1 in
            try a0.requireReg("OpAtsp")
            guard a0.isValueType else { throw EdiabasFailure("OpAtsp: Invalid data type") }
            var v: UInt32 = 0
            let len = try a0.getDataLen()
            let pos = try a1.getValueData()
            if e.stack.count < Int(len) { try e.setError(.EDIABAS_BIP_0005) } else {
                let arr = Array(e.stack.reversed())
                var idx = Int64(pos) - Int64(len)
                if idx < 0 { throw EdiabasFailure("OpAtsp: Invalid stack index") }
                for _ in 0..<Int(len) { v = (v << 8) | UInt32(arr[Int(idx)]); idx += 1 }
            }
            try a0.setValue(v)
            try e.flags.update(v, len)
        }
        add("swap") { e, a0, _ in
            try a0.requireReg("OpSwap")
            guard let r = a0.reg else { return }
            var data = try e.regArray(r, complete: true)
            let start = a0.idxImm, len = a0.lenImm
            if start &+ len > e.arrayMaxSize { try e.setError(.EDIABAS_BIP_0001); return }
            guard Int(start + len) <= data.count else { throw EdiabasFailure("OpSwap: range") }
            data[Int(start)..<Int(start + len)].reverse()
            let sd = e.stringRegisters[r.index]
            sd.data = data
        }
        add("setspc") { e, a0, a1 in
            e.tokenSeparator = try a0.getStringData()
            e.tokenIndex = try a1.getValueData()
        }
        add("srevrs") { e, a0, _ in
            try a0.requireReg("OpSrevrs")
            try a0.setArrayData(Array(try a0.getArrayData().reversed()))
        }
        add("stoken") { e, a0, a1 in
            try a0.requireReg("OpStoken")
            if e.tokenSeparator.isEmpty { e.flags.zero = true; return }
            let seps = CharacterSet(charactersIn: e.tokenSeparator)
            let words = try a1.getStringData().components(separatedBy: seps)
            if e.tokenIndex < 1 || Int(e.tokenIndex) > words.count { e.flags.zero = true } else {
                try a0.setStringData(words[Int(e.tokenIndex) - 1])
                e.flags.zero = false
            }
        }
        for name in ["parb", "parw", "parl"] {
            add(name) { e, a0, a1 in
                try a0.requireReg("OpParl")
                var result: UInt32 = 0
                e.flags.zero = true; e.flags.carry = false; e.flags.sign = false; e.flags.overflow = false
                let pos = Int(try a1.getValueData()) - 1
                let args = e.activeArgStrings()
                if pos >= 0, pos < args.count, !args[pos].isEmpty {
                    result = UInt32(truncatingIfNeeded: ediStringToValue(args[pos]))
                    e.flags.zero = false
                }
                try a0.setValue(result)
            }
        }
        add("pars") { e, a0, a1 in
            try a0.requireReg("OpPars")
            var result = ""
            e.flags.zero = true
            let pos = Int(try a1.getValueData()) - 1
            let args = e.activeArgStrings()
            if pos >= 0, pos < args.count, !args[pos].isEmpty { result = args[pos]; e.flags.zero = false }
            try a0.setStringData(result)
        }
        add("fclose") { e, a0, _ in
            if !e.closeUserFile(Int(try a0.getValueData(1))) { try e.setError(.EDIABAS_BIP_0006) }
        }
        add("jg", cond { $0.sign == $0.overflow && !$0.zero }, near: true)
        add("jge", cond { $0.zero || $0.sign == $0.overflow }, near: true)
        add("jl", cond { !$0.zero && $0.sign != $0.overflow }, near: true)
        add("jle", cond { $0.sign != $0.overflow || $0.zero }, near: true)
        add("ja", cond { !$0.carry && !$0.zero }, near: true)
        add("jbe", cond { $0.carry || $0.zero }, near: true)
        add("fopen") { e, a0, a1 in
            try a0.requireReg("OpFopen")
            var handle = -1
            let name = try a1.getStringData()
            if let d = FileManager.default.contents(atPath: name) {
                handle = e.storeUserFile(UserFile(data: [UInt8](d)))
                if handle < 0 { try e.setError(.EDIABAS_BIP_0006) }
            } else {
                try e.setError(.EDIABAS_BIP_0006)
            }
            try a0.setValue(UInt32(truncatingIfNeeded: handle))
            try e.flags.update(UInt32(truncatingIfNeeded: handle), 1)
        }
        add("fread") { e, a0, a1 in
            try a0.requireReg("OpFread")
            var value = -1
            if let f = e.userFile(Int(try a1.getValueData(1))) { value = f.readByte() } else { try e.setError(.EDIABAS_BIP_0006) }
            if value < 0 { value = 0; e.flags.carry = true } else { e.flags.carry = false }
            try a0.setValue(UInt32(value))
        }
        add("freadln") { e, a0, a1 in
            try a0.requireReg("OpFreadln")
            var line: String?
            if let f = e.userFile(Int(try a1.getValueData(1))) { line = f.readLine() } else { try e.setError(.EDIABAS_BIP_0006) }
            if line == nil { line = ""; e.flags.carry = true } else { e.flags.carry = false }
            try a0.setArrayData(Cp1252.bytes(line!))
        }
        add("fseek") { e, a0, a1 in
            let pos = try a1.getValueData()
            if let f = e.userFile(Int(try a0.getValueData(1))) { f.position = Int(pos) } else { try e.setError(.EDIABAS_BIP_0006) }
        }
        add("fseekln") { e, a0, a1 in
            let line = try a1.getValueData()
            if let f = e.userFile(Int(try a0.getValueData(1))) {
                f.position = 0
                for _ in 0..<Int(line) where f.readLineLength() < 0 { break }
            } else { try e.setError(.EDIABAS_BIP_0006) }
        }
        add("ftell") { e, a0, a1 in
            try a0.requireReg("OpFtell")
            var pos: UInt32 = 0
            if let f = e.userFile(Int(try a1.getValueData(1))) { pos = UInt32(f.position) } else { try e.setError(.EDIABAS_BIP_0006) }
            try a0.setValue(pos)
            try e.flags.update(pos, 4)
        }
        add("ftellln") { e, a0, a1 in
            try a0.requireReg("OpFtellln")
            var line: UInt32 = 0
            if let f = e.userFile(Int(try a1.getValueData(1))) {
                let current = f.position
                f.position = 0
                while true {
                    if f.readLineLength() < 0 { break }
                    if f.position >= current {
                        if f.position == current { line += 1 }
                        break
                    }
                    line += 1
                }
                f.position = current
            } else { try e.setError(.EDIABAS_BIP_0006) }
            try a0.setValue(line)
            try e.flags.update(line, 4)
        }
        add("a2fix") { e, a0, a1 in
            try a0.requireReg("OpA2fix")
            var v = ediStringToValue(try a1.getStringData())
            if v < Int64(Int32.min) { v = Int64(Int32.min) }
            if v > Int64(Int32.max) { v = 0xFFFF_FFFF }
            try a0.setValue(UInt32(truncatingIfNeeded: v))
            e.flags.zero = false; e.flags.sign = false; e.flags.overflow = false
        }
        add("fix2flt") { e, a0, a1 in
            try a0.requireReg("OpFix2flt")
            let v = try a1.getValueData()
            let r: Double
            switch try a1.getDataLen() {
            case 1: r = Double(s8(v))
            case 2: r = Double(s16(v))
            case 4: r = Double(s32(v))
            default: throw EdiabasFailure("OpFix2flt: Invalid length")
            }
            try a0.setFloat(r)
        }
        add("parr") { e, a0, a1 in
            try a0.requireReg("OpParr")
            var result = 0.0
            e.flags.zero = true; e.flags.carry = false; e.flags.sign = false; e.flags.overflow = false
            let pos = Int(try a1.getValueData()) - 1
            let args = e.activeArgStrings()
            if pos >= 0, pos < args.count, !args[pos].isEmpty {
                result = ediStringToFloat(args[pos]).value
                e.flags.zero = false
            }
            try a0.setFloat(result)
        }
        add("test") { e, a0, a1 in
            let len = try argsLen(a0)
            let v = try a0.getValueData(len) & a1.getValueData(len)
            e.flags.overflow = false
            try e.flags.update(v, len)
        }
        add("wait") { _, a0, _ in Thread.sleep(forTimeInterval: Double(try a0.getValueData())) }
        add("date") { _, a0, _ in
            try a0.requireReg("OpDate")
            let now = Date()
            let c = Calendar.current.dateComponents([.day, .month, .year, .weekday], from: now)
            var dow = (c.weekday ?? 1) - 1
            if dow == 0 { dow = 7 }
            try a0.setArrayData([UInt8(c.day ?? 0), UInt8(c.month ?? 0), UInt8((c.year ?? 0) % 100), UInt8(isoWeek(now)), UInt8(dow)])
        }
        add("time") { _, a0, _ in
            try a0.requireReg("OpTime")
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            try a0.setArrayData([UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)])
        }
        add("xbatt") { e, a0, _ in
            try a0.requireReg("OpXbat")
            guard let i = try needIface(e, connected: false) else { return }
            let v = i.batteryVoltage
            if v != Int64.min { try a0.setValue(UInt32(truncatingIfNeeded: v)) }
        }
        add("tosp", nil)
        add("xdownl", nil)
        add("xgetport") { e, a0, a1 in
            try a0.requireReg("OpXgetport")
            guard let i = try needIface(e, connected: false) else { return }
            try a0.setValue(UInt32(truncatingIfNeeded: i.getPort(try a1.getValueData() & 0xFF)))
        }
        add("xignit") { e, a0, _ in
            try a0.requireReg("OpXignit")
            guard let i = try needIface(e, connected: false) else { return }
            let v = i.ignitionVoltage
            if v != Int64.min { try a0.setValue(UInt32(truncatingIfNeeded: v)) }
        }
        add("xloopt") { e, a0, _ in
            try a0.requireReg("OpXloopt")
            guard let i = try needIface(e, connected: false) else { return }
            try a0.setValue(i.loopTest)
        }
        add("xprog") { e, a0, _ in
            guard let i = try needIface(e, connected: false) else { return }
            i.setProgramVoltage(try a0.getValueData())
        }
        add("xraw") { e, a0, a1 in
            try a0.requireReg("OpXraw")
            guard let i = try needIface(e, connected: true) else { return }
            if let r = try i.rawData(try a1.getArrayData()) { try a0.setRawData(.bytes(r)) }
        }
        add("xsetport") { e, a0, a1 in
            guard let i = try needIface(e, connected: false) else { return }
            let port = try a0.getArrayData()
            i.setPort(port.first.map { UInt32($0) } ?? 0, try a1.getValueData())
        }
        add("xsireset") { e, a0, _ in
            guard let i = try needIface(e, connected: false) else { return }
            i.switchSiRelais(try a0.getValueData())
        }
        add("xstoptr", nil)
        add("fix2hex") { e, a0, a1 in
            try a0.requireReg("OpFix2hex")
            let len = !a1.isValueType ? 1 : try a1.getDataLen()
            let v = try a1.getValueData(len)
            switch len {
            case 1: try a0.setStringData("0x" + hex2(v))
            case 2: try a0.setStringData("0x" + hex4(v))
            case 4: try a0.setStringData("0x" + hex8(v))
            default: throw EdiabasFailure("OpFix2hex: Invalid length")
            }
        }
        add("fix2dez", fix2str("OpFix2dez", signed: true))
        add("tabset") { e, a0, _ in
            let lastIdx = e.tableIndex, lastRow = e.tableRowIndex
            e.closeTableFs()
            if let base = e.sgbdBaseFs { try e.setTableFs(base) }
            guard var fs = e.currentTableFs else { throw EdiabasFailure("OpTabset: no file") }
            var (addr, found) = try e.getTableIndex(fs, try a0.getStringData())
            if !found && e.sgbdBaseFs != nil {
                e.closeTableFs()
                fs = e.currentTableFs!
                (addr, found) = try e.getTableIndex(fs, try a0.getStringData())
            }
            if !found { try e.setError(.EDIABAS_BIP_0010) }
            e.tableIndex = addr
            e.tableRowIndex = -1
            if e.tableIndex == lastIdx { e.tableRowIndex = lastRow }
        }
        add("tabseek") { e, a0, a1 in
            if e.tableIndex < 0 { try e.setError(.EDIABAS_BIP_0010); return }
            guard let fs = e.currentTableFs else { return }
            let r = try e.seekTable(fs, e.tableIndex, column: try a0.getStringData(), value: try a1.getStringData())
            if r.row < 0 { try e.setError(.EDIABAS_BIP_0010); return }
            e.tableRowIndex = r.row
            e.flags.zero = !r.found
        }
        add("tabget") { e, a0, a1 in
            if e.tableIndex < 0 { try e.setError(.EDIABAS_BIP_0010); return }
            guard let fs = e.currentTableFs else { return }
            let r = try e.tableEntry(fs, e.tableIndex, row: e.tableRowIndex, column: try a1.getStringData())
            guard let entry = r.entry else {
                if e.tableRowIndex < 0 && !r.columnInvalid { try a0.setStringData(""); return }
                try e.setError(.EDIABAS_BIP_0010)
                return
            }
            try a0.setStringData(entry)
        }
        add("strcat") { e, a0, a1 in
            try a0.requireReg("OpStrcat")
            let len1 = try a0.getDataLen()
            let s1 = try a0.getStringData()
            var s2 = try a1.getStringData()
            if Int(len1) + s2.count > Int(e.arrayMaxSize) {
                s2 = String(s2.prefix(max(0, Int(e.arrayMaxSize) - Int(len1))))
            }
            try a0.setStringData(s1 + s2)
        }
        add("pary") { e, a0, _ in
            try a0.requireReg("OpPary")
            var result: [UInt8] = []
            e.flags.zero = true
            let bin = e.activeArgBinary()
            if !bin.isEmpty { result = bin; e.flags.zero = false }
            try a0.setArrayData(result)
        }
        add("parn") { e, a0, _ in
            try a0.requireReg("OpParn")
            try a0.setValue(UInt32(e.activeArgStrings().count))
            e.flags.overflow = false
            try e.flags.update(try a0.getValueData(), try a0.getDataLen())
        }
        add("ergc", ergOp(.typeC) { .int(Int64(Int8(truncatingIfNeeded: try $0.getValueData(1)))) })
        add("ergl", ergOp(.typeL) { .int(Int64(Int32(bitPattern: try $0.getValueData(4)))) })
        add("tabline") { e, a0, _ in
            if e.tableIndex < 0 { try e.setError(.EDIABAS_BIP_0010); return }
            let r = e.tableLine(e.currentTableFs, e.tableIndex, try a0.getValueData())
            if r.row < 0 { try e.setError(.EDIABAS_BIP_0010) }
            e.tableRowIndex = r.row
            e.flags.zero = !r.found
        }
        add("xsendr", nil)
        add("xrecv", nil)
        add("xinfo", nil)
        add("flt2a") { e, a0, a1 in
            try a0.requireReg("OpFlt2a")
            let value = try a1.getFloatData()
            let conv = roundToSignificantDigits(value, e.floatPrecision)
            var result = dotNetDouble(conv)
            var digits = 0
            var pos = 0
            for ch in result {
                if ch.isASCII && ch.isNumber {
                    digits += 1
                    if digits >= Int(e.floatPrecision) {
                        result = String(result.prefix(pos + 1))
                        break
                    }
                }
                pos += 1
            }
            try a0.setStringData(result)
        }
        add("setflt") { e, a0, _ in e.floatPrecision = try a0.getValueData() }
        add("cfgig") { e, a0, a1 in
            try a0.requireReg("OpCfgig")
            if let v = e.getConfigProperty(try a1.getStringData()) {
                try a0.setValue(UInt32(truncatingIfNeeded: ediStringToValue(v)))
            }
        }
        add("cfgsg") { e, a0, a1 in
            try a0.requireReg("OpCfgsg")
            if let v = e.getConfigProperty(try a1.getStringData()) { try a0.setArrayData(Cp1252.bytes(v)) }
        }
        add("cfgis") { e, a0, a1 in e.setConfigProperty(try a0.getStringData(), "\(try a1.getValueData())") }
        add("a2y") { _, a0, a1 in
            try a0.requireReg("OpA2y")
            try a0.setArrayData(a2y(try a1.getStringData()))
        }
        add("xparraw", nil)
        add("hex2y") { e, a0, a1 in
            try a0.requireReg("OpHex2y")
            try a0.setArrayData(ediHexToBytes(try a1.getStringData()))
            e.flags.carry = false
        }
        add("strcmp") { e, a0, a1 in
            e.flags.zero = (try a0.getStringData()) != (try a1.getStringData())
        }
        add("strlen") { e, a0, a1 in
            try a0.requireReg("OpStrlen")
            let r = UInt32(try a1.getStringData().count)
            try a0.setValue(r)
            e.flags.overflow = false
            try e.flags.update(r, try a0.getDataLen())
        }
        add("y2bcd") { _, a0, a1 in
            try a0.requireReg("OpY2bcd")
            try a0.setStringData(try a1.getArrayData().map(ediValueToBcd).joined())
        }
        add("y2hex") { _, a0, a1 in
            try a0.requireReg("OpY2hex")
            try a0.setStringData(try a1.getArrayData().map { hex2(UInt32($0)) }.joined())
        }
        add("shmset") { _, a0, a1 in
            let key = try a0.getStringData().uppercased()
            let data = try a1.getArrayData()
            Ediabas.sharedLock.withLock { Ediabas.sharedData[key] = data }
        }
        add("shmget") { e, a0, a1 in
            try a0.requireReg("OpShmget")
            let key = try a1.getStringData().uppercased()
            let data = Ediabas.sharedLock.withLock { Ediabas.sharedData[key] }
            e.flags.carry = data == nil
            try a0.setArrayData(data ?? [])
        }
        add("ergsysi") { e, a0, a1 in
            let name = try a0.getStringData()
            let v = try a1.getValueData(2)
            if name == "!INITIALISIERUNG" {
                if v != 0 { e.requestInit = true }
            } else {
                e.setSysResultData(ResultData(type: .typeI, name: name, value: .int(Int64(v))))
            }
        }
        add("flt2fix") { e, a0, a1 in
            try a0.requireReg("OpFlt2fix")
            let r = dblToU32(try a1.getFloatData())
            try a0.setValue(r)
            e.flags.overflow = false
            try e.flags.update(r, 4)
        }
        add("iupdate") { e, a0, _ in
            e.infoProgressText = try a0.getStringData()
            e.jobProgressInform()
        }
        add("irange") { e, a0, _ in
            e.infoProgressPos = -1
            e.infoProgressRange = Int64(try a0.getValueData())
            e.jobProgressInform()
        }
        add("iincpos") { e, a0, _ in
            let inc = Int64(try a0.getValueData())
            var nv = e.infoProgressPos < 0 ? inc : e.infoProgressPos + inc
            if nv > e.infoProgressRange { nv = e.infoProgressRange }
            e.infoProgressPos = nv
            e.jobProgressInform()
        }
        add("tabseeku") { e, a0, a1 in
            if e.tableIndex < 0 { try e.setError(.EDIABAS_BIP_0010); return }
            guard let fs = e.currentTableFs else { return }
            let r = try e.seekTable(fs, e.tableIndex, column: try a0.getStringData(), value: try a1.getValueData())
            if r.row < 0 { try e.setError(.EDIABAS_BIP_0010); return }
            e.tableRowIndex = r.row
            e.flags.zero = !r.found
        }
        add("flt2y4") { e, a0, a1 in
            try floatToBytes(e, a0, a1, 4)
        }
        add("flt2y8") { e, a0, a1 in
            try floatToBytes(e, a0, a1, 8)
        }
        add("y42flt") { _, a0, a1 in
            try a0.requireReg("Opy42flt")
            let d = try a1.getArrayData()
            guard d.count >= 4 else { throw EdiabasFailure("Opy42flt: short") }
            let bits = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
            try a0.setFloat(Double(Float(bitPattern: bits)))
        }
        add("y82flt") { _, a0, a1 in
            try a0.requireReg("OpY82flt")
            let d = try a1.getArrayData()
            guard d.count >= 8 else { throw EdiabasFailure("OpY82flt: short") }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(d[i]) << UInt64(i * 8) }
            try a0.setFloat(Double(bitPattern: bits))
        }
        add("plink") { _, _, _ in }
        add("pcall", nil)
        add("fcomp") { e, a0, a1 in
            let v0 = try a0.getFloatData(), v1 = try a1.getFloatData()
            let diff = v0 - v1
            if diff.isInfinite || diff.isNaN { e.flags.carry = true }
            e.flags.zero = v0 == v1
            e.flags.sign = v0 < v1
            e.flags.overflow = false
        }
        add("plinkv") { _, _, _ in }
        add("ppush") { _, _, _ in }
        add("ppop") { e, a0, _ in
            try a0.setValue(0)
            e.flags.overflow = false
            try e.flags.update(0, try a0.getDataLen())
        }
        add("ppushflt") { _, _, _ in }
        add("ppopflt") { e, a0, _ in
            try a0.setFloat(0)
            e.flags.overflow = false
        }
        add("ppushy") { _, _, _ in }
        add("ppopy") { _, a0, _ in try a0.setArrayData([]) }
        add("pjtsr") { _, _, _ in }
        add("tabsetex") { e, a0, a1 in
            let lastIdx = e.tableIndex, lastRow = e.tableRowIndex
            let base = try a1.getStringData()
            if !base.isEmpty {
                guard let path = e.prgFileExists(named: base) else {
                    e.log(.error, "OpTabsetex: File not found \(base)")
                    try e.setError(.EDIABAS_SYS_0002)
                    return
                }
                do {
                    e.closeTableFs()
                    try e.setTableFs(try e.openPrgFile(path))
                } catch {
                    try e.setError(.EDIABAS_SYS_0002)
                    return
                }
            }
            guard let fs = e.currentTableFs else { return }
            let (addr, found) = try e.getTableIndex(fs, try a0.getStringData())
            if !found { try e.setError(.EDIABAS_BIP_0010) }
            e.tableIndex = addr
            e.tableRowIndex = -1
            if e.tableIndex == lastIdx { e.tableRowIndex = lastRow }
        }
        add("ufix2dez", fix2str("OpUfix2dez", signed: false))
        add("generr") { e, a0, _ in
            let raw = try a0.getValueData()
            if raw < EdiabasError.EDIABAS_RUN_0000.rawValue || raw > EdiabasError.EDIABAS_ERROR_LAST.rawValue {
                try e.raiseError(.EDIABAS_BIP_0001)
            } else {
                try e.raiseError(EdiabasError(rawValue: raw) ?? .EDIABAS_BIP_0001)
            }
        }
        add("ticks") { _, a0, _ in
            try a0.requireReg("OpTicks")
            let ms = Date().timeIntervalSince1970 * 1000 + 62_135_596_800_000
            try a0.setValue(UInt32(truncatingIfNeeded: Int64(ms)))
        }
        add("waitex") { _, a0, _ in Thread.sleep(forTimeInterval: Double(try a0.getValueData()) / 1000) }
        add("xopen", nil)
        add("xclose", nil)
        add("xcloseex", nil)
        add("xswitch", nil)
        add("xsendex", nil)
        add("xrecvex", nil)
        add("ssize") { e, a0, _ in
            try a0.requireReg("OpSsize")
            try a0.setValue(e.arrayMaxBufSize)
        }
        add("tabcols") { e, a0, _ in
            try a0.setValue(e.tableIndex < 0 ? 0 : e.tableColumns(e.currentTableFs, e.tableIndex))
        }
        add("tabrows") { e, a0, _ in
            try a0.setValue(e.tableIndex < 0 ? 0 : e.tableRows(e.currentTableFs, e.tableIndex) + 1)
        }
        return l
    }()
}

private func opMove(_ e: Ediabas, _ a0: Operand, _ a1: Operand) throws {
    try a0.requireReg("OpMove")
    if a0.isValueType {
        let len = try argsLen(a0)
        let v = try a1.getValueData(len)
        try a0.setValue(v)
        e.flags.carry = false; e.flags.overflow = false
        try e.flags.update(v, len)
    } else {
        if a1.isValueType {
            let len = try argsLen(a0)
            let v = try a1.getValueData(len)
            try a0.setValue(v)
            e.flags.carry = false; e.flags.overflow = false
            try e.flags.update(v, 1)
        } else {
            let src = try a1.getRawData()
            if a0.mode == .regS, case .bytes(let s) = src, let r = a0.reg {
                var dest = try a0.getArrayData()
                if dest.count < s.count { dest += [UInt8](repeating: 0, count: s.count - dest.count) }
                for (i, b) in s.enumerated() { dest[i] = b }
                try e.setRegRaw(r, .bytes(dest))
            } else {
                try a0.setRawData(src)
            }
            e.flags.carry = false; e.flags.zero = false; e.flags.sign = false; e.flags.overflow = false
        }
    }
}

private func addOp(withCarry: Bool, name: String) -> OpFn {
    { e, a0, a1 in
        try a0.requireReg(name)
        let len = try argsLen(a0)
        let v0 = try a0.getValueData(len)
        var v1 = try a1.getValueData(len)
        if withCarry && e.flags.carry { v1 = v1 &+ 1 }
        let sum = UInt64(v0) &+ UInt64(v1)
        let s32v = UInt32(truncatingIfNeeded: sum)
        try a0.setValue(s32v)
        try e.flags.update(s32v, len)
        try e.flags.setOverflow(v0, v1, s32v, len)
        try e.flags.setCarry(sum, len)
    }
}

private func subOp(withCarry: Bool, name: String) -> OpFn {
    { e, a0, a1 in
        try a0.requireReg(name)
        let len = try argsLen(a0)
        let v0 = try a0.getValueData(len)
        var v1 = try a1.getValueData(len)
        if withCarry && e.flags.carry { v1 = v1 &+ 1 }
        let diff = UInt64(v0) &- UInt64(v1)
        let d32 = UInt32(truncatingIfNeeded: diff)
        try a0.setValue(d32)
        try e.flags.update(d32, len)
        try e.flags.setOverflow(v0, 0 &- v1, d32, len)
        try e.flags.setCarry(diff, len)
    }
}

private func trapJump(invert: Bool) -> OpFn {
    { e, a0, a1 in
        var detected = false
        if a1.mode != .none {
            let bit = try a1.getValueData(1)
            if bit > 0 {
                if e.errorTrapBitNr == Int(bit) { detected = true }
                if e.errorTrapBitNr == 0 && bit == 32 { detected = true }
            } else if e.errorTrapBitNr >= 0x4000_0000 {
                detected = true
            }
        } else {
            // OpJnt without argument deliberately differs from OpJt (EDIABAS behaviour)
            detected = invert ? e.errorTrapBitNr >= 0x4000_0000 : e.errorTrapBitNr >= 0
        }
        if detected != invert { e.pcCounter = try a0.getValueData() }
    }
}

private func floatToBytes(_ e: Ediabas, _ a0: Operand, _ a1: Operand, _ size: Int) throws {
    try a0.requireReg("OpFlt2y")
    guard let r = a0.reg, a0.mode == .idxImm else { throw EdiabasFailure("OpFlt2y: Invalid mode") }
    var dest = try e.regArray(r, complete: false)
    let start = a0.idxImm
    if start &+ UInt32(size) > e.arrayMaxSize { try e.setError(.EDIABAS_BIP_0001); return }
    if dest.count < Int(start) + size { dest += [UInt8](repeating: 0, count: Int(start) + size - dest.count) }
    let value = try a1.getFloatData()
    let bits: UInt64 = size == 4 ? UInt64(Float(value).bitPattern) : value.bitPattern
    for i in 0..<size { dest[Int(start) + i] = UInt8(truncatingIfNeeded: bits >> UInt64(i * 8)) }
    try e.setRegArray(r, dest)
}

private func a2y(_ input: String) -> [UInt8] {
    var s = input
    var result: [UInt8] = []
    guard !s.isEmpty else { return result }
    let lower = Array(s.lowercased())
    for (i, ch) in lower.enumerated() {
        let ok = (ch.isASCII && ch.isNumber) || ("a"..."f").contains(ch) || ch == " " || ch == ";" || ch == ","
        if !ok { s = String(Array(s)[0..<i]); break }
    }
    var exit = false
    for part in s.components(separatedBy: CharacterSet(charactersIn: ",;")) {
        if part.trimmingCharacters(in: .whitespaces).isEmpty {
            result += [UInt8](repeating: 0, count: part.count + 1)
        } else {
            for sub in part.trimmingCharacters(in: .whitespaces).components(separatedBy: " ") where !sub.isEmpty {
                if let b = UInt8(sub, radix: 16) { result.append(b) } else { exit = true; break }
            }
        }
        if exit { break }
    }
    return result
}

/// Mimics .NET Double.ToString() ("R"-like shortest round trip, no trailing zeros).
func dotNetDouble(_ d: Double) -> String {
    if d == 0 { return "0" }
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    let a = abs(d)
    if a >= 1e15 || a < 1e-5 {
        var s = "\(d)"   // Swift gives e.g. 1e+16 / 1e-05
        if let r = s.range(of: "e") {
            let mant = String(s[..<r.lowerBound])
            var exp = String(s[r.upperBound...])
            var sign = "+"
            if exp.hasPrefix("-") { sign = "-"; exp.removeFirst() } else if exp.hasPrefix("+") { exp.removeFirst() }
            if exp.count < 2 { exp = "0" + exp }
            s = mant.replacingOccurrences(of: ".0", with: "") + "E" + sign + exp
        }
        return s
    }
    var s = "\(d)"
    if s.hasSuffix(".0") { s.removeLast(2) }
    return s
}
