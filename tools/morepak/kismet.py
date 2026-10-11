"""Kismet (UE5) bytecode disassembler for cooked legacy assets.
Usage: python -I kismet.py <asset.json from UAssetGUI> <asset.uexp> [function name ...] [--at 0xOFF ...]
Reads export offsets, name map and import map from the JSON and the raw bytes from the .uexp.
"""
import json, struct, sys

OPS = {
 0x00:'LocalVariable',0x01:'InstanceVariable',0x02:'DefaultVariable',0x04:'Return',0x06:'Jump',0x07:'JumpIfNot',
 0x09:'Assert',0x0B:'Nothing',0x0C:'NothingInt32',0x0F:'Let',0x11:'BitFieldConst',0x12:'ClassContext',0x13:'MetaCast',
 0x14:'LetBool',0x15:'EndParmValue',0x16:'EndFunctionParms',0x17:'Self',0x18:'Skip',0x19:'Context',0x1A:'Context_FailSilent',
 0x1B:'VirtualFunction',0x1C:'FinalFunction',0x1D:'IntConst',0x1E:'FloatConst',0x1F:'StringConst',0x20:'ObjectConst',
 0x21:'NameConst',0x22:'RotationConst',0x23:'VectorConst',0x24:'ByteConst',0x25:'IntZero',0x26:'IntOne',0x27:'True',0x28:'False',
 0x29:'TextConst',0x2A:'NoObject',0x2B:'TransformConst',0x2C:'IntConstByte',0x2D:'NoInterface',0x2E:'DynamicCast',0x2F:'StructConst',
 0x30:'EndStructConst',0x31:'SetArray',0x32:'EndArray',0x33:'PropertyConst',0x34:'UnicodeStringConst',0x35:'Int64Const',
 0x36:'UInt64Const',0x37:'DoubleConst',0x38:'Cast',0x39:'SetSet',0x3A:'EndSet',0x3B:'SetMap',0x3C:'EndMap',0x3D:'SetConst',
 0x3E:'EndSetConst',0x3F:'MapConst',0x40:'EndMapConst',0x41:'Vector3fConst',0x42:'StructMemberContext',0x43:'LetMulticastDelegate',
 0x44:'LetDelegate',0x45:'LocalVirtualFunction',0x46:'LocalFinalFunction',0x48:'LocalOutVariable',0x4A:'DeprecatedOp4A',
 0x4B:'InstanceDelegate',0x4C:'PushExecutionFlow',0x4D:'PopExecutionFlow',0x4E:'ComputedJump',0x4F:'PopExecutionFlowIfNot',
 0x50:'Breakpoint',0x51:'InterfaceContext',0x52:'ObjToInterfaceCast',0x53:'EndOfScript',0x54:'CrossInterfaceCast',
 0x55:'InterfaceToObjCast',0x5A:'WireTracepoint',0x5B:'SkipOffsetConst',0x5C:'AddMulticastDelegate',0x5D:'ClearMulticastDelegate',
 0x5E:'Tracepoint',0x5F:'LetObj',0x60:'LetWeakObjPtr',0x61:'BindDelegate',0x62:'RemoveMulticastDelegate',0x63:'CallMulticastDelegate',
 0x64:'LetValueOnPersistentFrame',0x65:'ArrayConst',0x66:'EndArrayConst',0x67:'SoftObjectConst',0x68:'CallMath',0x69:'SwitchValue',
 0x6A:'InstrumentationEvent',0x6B:'ArrayGetByRef',0x6C:'ClassSparseDataVariable',0x6D:'FieldPathConst',
 0x70:'AutoRtfmTransact',0x71:'AutoRtfmStopTransact',0x72:'AutoRtfmAbortIfNot',
}

NOARG = {0x0B, 0x15, 0x16, 0x17, 0x25, 0x26, 0x27, 0x28, 0x2A, 0x2D, 0x30, 0x32, 0x3A, 0x3C, 0x3E, 0x40, 0x4A, 0x4D, 0x50, 0x53, 0x5A, 0x5E, 0x66}


class Asset:
    def __init__(self, jpath, uexp_path):
        self.j = json.load(open(jpath, encoding='utf-8-sig'))
        self.names = [n if isinstance(n, str) else n.get('Name', str(n)) for n in self.j['NameMap']]
        self.imports = self.j['Imports']
        self.exports = self.j['Exports']
        self.uexp = open(uexp_path, 'rb').read()
        self.header_size = min(e['SerialOffset'] for e in self.exports)

    def name(self, idx, num):
        s = self.names[idx] if 0 <= idx < len(self.names) else '<name#%d>' % idx
        return s + ('_%d' % (num - 1) if num else '')

    def obj(self, pidx):
        if pidx > 0:
            return self.exports[pidx - 1].get('ObjectName', '?')
        if pidx < 0:
            return self.imports[-pidx - 1].get('ObjectName', '?')
        return 'null'

    def export_bytes(self, e):
        start = e['SerialOffset'] - self.header_size
        return self.uexp[start:start + e['SerialSize']], start


def script_candidates(data):
    """UFunction export tail: [BytecodeBufferSize i32][SerializedScriptSize i32][script][FunctionFlags u32][(RPC u16 u16)][EventGraphFunction i32][EventGraphCallOffset i32].
    The in-memory size can be smaller or larger than the serialized one, so only the serialized size is trusted;
    every position whose size field matches is a candidate, nearest the end first."""
    n = len(data)
    out = []
    for trailing in (12, 16):
        if n < trailing + 8:
            continue
        flags = struct.unpack_from('<I', data, n - trailing)[0]
        is_net = bool(flags & 0x40)
        if (trailing == 16) != is_net:
            continue
        script_end = n - trailing
        for s in range(script_end, 7, -1):
            size = struct.unpack_from('<i', data, s - 4)[0]
            if size == script_end - s and data[script_end - 1] == 0x53:
                out.append((s, script_end, flags))
    return out


class Dis:
    def __init__(self, asset, code, base):
        self.a, self.c, self.base = asset, code, base
        self.p = 0
        self.lines = []

    def u8(self):
        v = self.c[self.p]; self.p += 1; return v
    def i32(self):
        v = struct.unpack_from('<i', self.c, self.p)[0]; self.p += 4; return v
    def u32(self):
        v = struct.unpack_from('<I', self.c, self.p)[0]; self.p += 4; return v
    def u16(self):
        v = struct.unpack_from('<H', self.c, self.p)[0]; self.p += 2; return v
    def f32(self):
        v = struct.unpack_from('<f', self.c, self.p)[0]; self.p += 4; return v
    def f64(self):
        v = struct.unpack_from('<d', self.c, self.p)[0]; self.p += 8; return v
    def i64(self):
        v = struct.unpack_from('<q', self.c, self.p)[0]; self.p += 8; return v
    def fname(self):
        idx, num = struct.unpack_from('<ii', self.c, self.p); self.p += 8
        return self.a.name(idx, num)
    def ptr(self):
        return self.a.obj(self.i32())
    def prop(self):
        cnt = self.i32()
        names = [self.fname() for _ in range(cnt)]
        owner = self.i32()
        return '.'.join(names) + '@' + self.a.obj(owner)
    def cstr(self):
        s = bytearray()
        while True:
            b = self.u8()
            if b == 0:
                break
            s.append(b)
        return s.decode('latin-1')
    def wstr(self):
        s = bytearray()
        while True:
            w = self.c[self.p:self.p + 2]; self.p += 2
            if w == b'\0\0':
                break
            s += w
        return s.decode('utf-16-le')

    def note(self, depth, s):
        self.lines.append('%6s %s%s' % ('', '  ' * depth, s))

    def until(self, end_op, depth):
        while self.c[self.p] != end_op:
            self.expr(depth)
        self.p += 1

    def expr(self, depth=0):
        at = self.p
        op = self.u8()
        nm = OPS.get(op, 'OP_%02X' % op)
        ind = '  ' * depth

        def out(s):
            self.lines.append('%06X %s%s' % (self.base + at, ind, s))

        if op in (0x00, 0x01, 0x02, 0x48, 0x6C, 0x33):
            out(nm + ' ' + self.prop())
        elif op == 0x11:
            p = self.prop(); out('BitFieldConst %s = %d' % (p, self.u8()))
        elif op == 0x04:
            out('Return'); self.expr(depth + 1)
        elif op == 0x06:
            out('Jump -> %06X' % (self.base + self.u32()))
        elif op == 0x07:
            out('JumpIfNot -> %06X' % (self.base + self.u32())); self.expr(depth + 1)
        elif op == 0x09:
            out('Assert line=%d dbg=%d' % (self.u16(), self.u8())); self.expr(depth + 1)
        elif op == 0x0C:
            out('NothingInt32 %d' % self.i32())
        elif op == 0x0F:
            out('Let ' + self.prop()); self.expr(depth + 1); self.expr(depth + 1)
        elif op in (0x14, 0x43, 0x44, 0x5F, 0x60, 0x5C, 0x62, 0x6B):
            out(nm); self.expr(depth + 1); self.expr(depth + 1)
        elif op == 0x64:
            out('LetValueOnPersistentFrame ' + self.prop()); self.expr(depth + 1)
        elif op in (0x12, 0x19, 0x1A):
            out(nm); self.expr(depth + 1)
            skip = self.u32(); rv = self.prop()
            self.note(depth + 1, '[skip->%06X rvalue=%s]' % (self.base + self.p + skip, rv))
            self.expr(depth + 1)
        elif op == 0x51:
            out(nm); self.expr(depth + 1)
        elif op == 0x42:
            out('StructMemberContext ' + self.prop()); self.expr(depth + 1)
        elif op in (0x1B, 0x45):
            out('%s %s(' % (nm, self.fname())); self.until(0x16, depth + 1)
        elif op in (0x1C, 0x46, 0x68):
            fi = self.i32(); out('%s %s(' % (nm, self.a.obj(fi))); self.until(0x16, depth + 1)
        elif op == 0x63:
            out('CallMulticastDelegate ' + self.ptr()); self.expr(depth + 1); self.until(0x16, depth + 1)
        elif op == 0x1D: out('IntConst %d' % self.i32())
        elif op == 0x1E: out('FloatConst %g' % self.f32())
        elif op == 0x1F: out('StringConst "%s"' % self.cstr())
        elif op == 0x34: out('UnicodeStringConst "%s"' % self.wstr())
        elif op == 0x20: out('ObjectConst ' + self.ptr())
        elif op == 0x21: out('NameConst ' + self.fname())
        elif op in (0x22, 0x23): out('%s (%.3f, %.3f, %.3f)' % (nm, self.f64(), self.f64(), self.f64()))
        elif op == 0x41: out('Vector3fConst (%.3f, %.3f, %.3f)' % (self.f32(), self.f32(), self.f32()))
        elif op == 0x2B: out('TransformConst ' + ', '.join('%.3f' % self.f64() for _ in range(10)))
        elif op in (0x24, 0x2C): out('%s %d' % (nm, self.u8()))
        elif op in (0x35, 0x36): out('%s %d' % (nm, self.i64()))
        elif op == 0x37: out('DoubleConst %g' % self.f64())
        elif op == 0x29:
            t = self.u8(); out('TextConst type=%d' % t)
            if t == 1:
                self.expr(depth + 1); self.expr(depth + 1); self.expr(depth + 1)
            elif t in (2, 3):
                self.expr(depth + 1)
            elif t in (4, 5):  # string table entry (5.8 numbers it 5)
                self.note(depth + 1, 'table=' + self.ptr()); self.expr(depth + 1); self.expr(depth + 1)
        elif op in (0x13, 0x2E, 0x52, 0x54, 0x55):
            out('%s %s' % (nm, self.ptr())); self.expr(depth + 1)
        elif op == 0x38:
            out('Cast type=%d' % self.u8()); self.expr(depth + 1)
        elif op == 0x2F:
            st = self.ptr(); sz = self.i32(); out('StructConst %s size=%d' % (st, sz)); self.until(0x30, depth + 1)
        elif op == 0x31:
            out('SetArray'); self.expr(depth + 1); self.until(0x32, depth + 1)
        elif op in (0x39, 0x3B):
            out(nm); self.expr(depth + 1); n = self.i32(); self.note(depth + 1, 'count=%d' % n)
            self.until(0x3A if op == 0x39 else 0x3C, depth + 1)
        elif op == 0x65:
            pr = self.prop(); n = self.i32(); out('ArrayConst inner=%s n=%d' % (pr, n)); self.until(0x66, depth + 1)
        elif op == 0x3D:
            pr = self.prop(); n = self.i32(); out('SetConst inner=%s n=%d' % (pr, n)); self.until(0x3E, depth + 1)
        elif op == 0x3F:
            k = self.prop(); v = self.prop(); n = self.i32(); out('MapConst %s -> %s n=%d' % (k, v, n)); self.until(0x40, depth + 1)
        elif op == 0x18:
            out('Skip -> %06X' % (self.base + self.u32())); self.expr(depth + 1)
        elif op == 0x4C: out('PushExecutionFlow %06X' % (self.base + self.u32()))
        elif op in (0x4E, 0x4F, 0x5D, 0x67, 0x6D, 0x72): out(nm); self.expr(depth + 1)
        elif op == 0x5B: out('SkipOffsetConst %06X' % (self.base + self.u32()))
        elif op == 0x61:
            out('BindDelegate ' + self.fname()); self.expr(depth + 1); self.expr(depth + 1)
        elif op == 0x4B: out('InstanceDelegate ' + self.fname())
        elif op == 0x69:
            n = self.u16(); end = self.u32()
            out('SwitchValue cases=%d end->%06X' % (n, self.base + end))
            self.expr(depth + 1)
            for i in range(n):
                self.note(depth + 1, 'case %d:' % i)
                self.expr(depth + 2); nxt = self.u32()
                self.note(depth + 2, '[next->%06X] =>' % (self.base + nxt))
                self.expr(depth + 2)
            self.note(depth + 1, 'default:'); self.expr(depth + 2)
        elif op == 0x6A:
            t = self.u8(); out('InstrumentationEvent %d' % t)
            if t == 7:
                self.fname()
        elif op == 0x70:
            tid = self.i32(); lbl = self.u32(); out('AutoRtfmTransact id=%d ->%06X' % (tid, self.base + lbl))
            self.until(0x71, depth + 1); self.i32(); self.u8()
        elif op == 0x71:
            out('AutoRtfmStopTransact id=%d mode=%d' % (self.i32(), self.u8()))
        elif op in NOARG:
            out(nm)
        else:
            out('?? unknown opcode 0x%02X' % op)
            raise ValueError('unknown opcode 0x%02X at %06X' % (op, self.base + at))

    def run(self):
        while self.p < len(self.c):
            self.expr(0)
        return self.lines


def disassemble_export(asset, e):
    data, start = asset.export_bytes(e)
    cands = script_candidates(data)
    if not cands:
        return None, ['%s: script not located' % e['ObjectName']]
    best = None
    cands.sort(key=lambda c: c[1] - c[0], reverse=True)  # longest first: the real script, shorter ones are false hits inside it
    for s, end, flags in cands:
        d = Dis(asset, data[s:end], start + s)
        try:
            lines = d.run()
            if d.p == len(d.c):
                return (start + s, start + end, flags), lines
        except Exception as ex:
            if best is None:
                best = ((start + s, start + end, flags), d.lines + ['  !! %s' % ex])
    return best if best else (None, ['%s: no candidate parsed' % e['ObjectName']])


def function_exports(asset):
    for e in asset.exports:
        if asset.obj(e.get('ClassIndex', 0)) == 'Function':
            yield e


def main():
    args = sys.argv[1:]
    jpath, upath = args[0], args[1]
    want, ats = [], []
    i = 2
    while i < len(args):
        if args[i] == '--at':
            ats.append(int(args[i + 1], 16)); i += 2
        else:
            want.append(args[i]); i += 1
    a = Asset(jpath, upath)
    for e in function_exports(a):
        nm = e['ObjectName']
        data, start = a.export_bytes(e)
        hit = any(start <= x < start + len(data) for x in ats)
        if (want or ats) and nm not in want and not hit:
            continue
        info, lines = disassemble_export(a, e)
        head = '===== %s  export@%06X+%X' % (nm, start, len(data))
        if info:
            head += ' script %06X-%06X flags=%08X' % info
        print(head)
        for ln in lines:
            mark = ''
            try:
                off = int(ln[:6], 16)
                if any(off <= x < off + 48 for x in ats):
                    mark = '   <<<'
            except ValueError:
                pass
            print(ln + mark)


if __name__ == '__main__':
    main()
