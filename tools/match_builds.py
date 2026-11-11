#!/usr/bin/env python3
"""Find the Mac27 values for a new build of FM's game_plugin, starting from the old build's.

    python3 -I tools/match_builds.py OLD NEW [name=value ...] [--rules FILE] [--class NAME ...]

OLD and NEW are game_plugin files, fat or arm64 slices: a copy kept from the old build, since Steam replaces it, and the
new one. They are only read, and the tool writes nothing. It takes about half a minute.

Without name=value arguments, the old values come from Mac27 in Sources/StarshipCore/Emu/RulesEngine.swift, which still
holds the old build's on patch day. Running it with the same build twice is a quick test: everything pairs with itself.

A patch adds and removes functions, so they can't be paired by their index. Each function's code is normalised instead:
branch targets, adrp pages and the offsets that complete them are blanked, so a function that only moved looks the same.
Functions whose code is unique in both builds, in the same order, pair first. The same is repeated inside each gap
between pairs, and a gap left with as many functions on each side pairs by position. Then each value is checked on its
own, by what it is (KINDS below):

  function   Paired with the same code, the constants it loads are the same, and its calls pair. Callers whose own
             code is unchanged must call the new address too, which also finds a function whose code changed. A call
             to a function whose code changed is only a note: the rules engine runs FM's new code as it is.
  global     The address the same instruction uses, in every unchanged function that used the old one.
  slot       The class's vtables, from RTTI: the slot's function pairs with the same slot's, with the same code.
  callslot   The vtable slots FM calls on the object a global holds, counted in both builds.
  constant   Still built in the function it's used in.

Each value ends FOUND (unchanged code says so), CHECK (found, but its code changed, so check it by hand, as README's
"After an FM patch" says) or MISSING. The reader's classes get a lighter check: their base-class offsets and the
functions that build their vtables. That's a good sign but not proof, since Load Save's self-check is the test.

Exit status: 0 when every value is FOUND, 3 when one needs checking or is missing.
"""
import argparse
import bisect
import collections
import hashlib
import os
import re
import struct
import sys
from array import array

# What each Mac27 value is, so it can be checked the right way. A new value in Mac27 needs a line here.
KINDS = {
    'fingerprint': ('fingerprint',),
    'interestManagerGlobal': ('global',),
    'statusFunction': ('function',),
    'interestSlot': ('slot', 'GAME_ACTUAL_PLAYER', 0),
    'staffRuleSlot': ('slot', 'PERSON_NON_PLAYER_INTERESTED_FILTER_RULE', 0),
    'statFunction': ('function',),
    'statsContainerSlot': ('slot', 'GAME_ACTUAL_PLAYER', 0),
    'personStatsSlot': ('slot', 'ACTUAL_PLAYER', -0x388),  # the player's identity part, MacLayout.Player.identity
    'statFallback': ('value',),
    'roleInPossession': ('function',),
    'roleOutOfPossession': ('function',),
    'roleBand': ('function',),
    'roleListInPossession': ('function',),
    'roleListOutOfPossession': ('function',),
    'preferredJob': ('function',),
    'staffNumbersGlobal': ('global',),
    'staffAllowedSlot': ('callslot', 'staffNumbersGlobal'),
    'staffCurrentSlot': ('callslot', 'staffNumbersGlobal'),
    'staffModeFlags': ('global',),
    'injuryInfo': ('function',),
    'bagSet': ('function',),
    'bagClear': ('function',),
    'injuryDaysKey': ('constant', 'injuryInfo'),
    'shapeName': ('function',),
}

# The classes GameReader finds by name (its vt(...) calls).
READER_CLASSES = ['ACTUAL_PLAYER', 'ACTUAL_NON_PLAYER', 'CLUB_HUMAN_MANAGER_DETAILS', 'CURRENCY_RECORD', 'TEAM',
                  'TRANSFER_MANAGER', 'HUMAN_NON_PLAYER', 'TACTIC_EDIT_SESSION', 'PREPARED_TACTICS_CREATOR_ARRAY',
                  'LOAN_CONTRACT', 'B_CLUB_CONTRACT']

RULES = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Sources', 'StarshipCore', 'Emu', 'RulesEngine.swift')


def sx(value, bits):
    return value - (1 << bits) if (value >> (bits - 1)) & 1 else value


def adrp_page(w, pc):
    return (pc & ~0xFFF) + (sx(((w >> 5) & 0x7FFFF) << 2 | (w >> 29) & 3, 21) << 12)


def branch_target(w, pc):
    return pc + 4 * sx(w & 0x3FFFFFF, 26)


# Instruction classes, by the top byte.
ADRP, ADR, BIMM, LIT, COND, IND, ADDI, LDSTU, LDSTP = range(1, 10)
TOP = bytearray(256)
for _t in range(256):
    if _t & 0x9F == 0x90: TOP[_t] = ADRP            # adrp
    elif _t & 0x9F == 0x10: TOP[_t] = ADR           # adr
    elif _t & 0x7C == 0x14: TOP[_t] = BIMM          # b, bl
    elif _t & 0x3B == 0x18: TOP[_t] = LIT           # ldr (literal)
    elif _t == 0x91: TOP[_t] = ADDI                 # add (immediate)
    elif _t & 0x3B == 0x39: TOP[_t] = LDSTU         # ldr, str (unsigned offset)
    elif _t & 0x3A == 0x28: TOP[_t] = LDSTP         # ldp, stp
    elif _t & 0x7E == 0x34 or _t == 0x54 or _t & 0x7E == 0x36: TOP[_t] = COND  # cbz, cbnz, b.cond, tbz, tbnz
    elif _t == 0xD6: TOP[_t] = IND                  # br, blr, ret
CALLER_SAVED = frozenset(list(range(19)) + [30])


def written(w, t):
    """The general registers an instruction may write, roughly: enough to know when one stops holding an adrp page.
    Saying too many only blanks less."""
    op0 = (w >> 25) & 0xF
    if op0 & 0xE == 0xA:                                    # branches, exceptions, system
        if w & 0xFFFFFC1F == 0xD63F0000: return CALLER_SAVED    # blr
        if w & 0xFFF00000 == 0xD5300000: return (w & 31,)       # mrs
        return ()
    if t == LIT: return () if (w >> 26) & 1 else (w & 31,)
    if op0 & 0x5 == 0x4:                                    # loads and stores
        out = []
        if t == LDSTP:
            if (w >> 23) & 1: out.append((w >> 5) & 31)     # pre- or post-index writes the base back
            if (w >> 22) & 1 and not (w >> 26) & 1: out += [w & 31, (w >> 10) & 31]
            return out
        if t != LDSTU and (w >> 27) & 7 == 7 and not (w >> 21) & 1 and (w >> 10) & 1:
            out.append((w >> 5) & 31)                       # pre- or post-index
        if not (w >> 26) & 1 and (w >> 22) & 3: out.append(w & 31)
        return out
    if op0 & 0x7 == 0x7:                                    # floating point and SIMD: only these write a general one
        if w & 0x7F20FC00 == 0x1E200000: return (w & 31,)       # fmov, fcvt* and the like, to or from one
        if w & 0xBFE0EC00 == 0x0E002C00: return (w & 31,)       # smov, umov
        return ()
    return (w & 31,)                                        # data processing


class Image:
    """An arm64 Mach-O: its sections, function starts and chained fixups."""

    def __init__(self, path):
        data = open(path, 'rb').read()
        if len(data) < 32: sys.exit(f'{path}: not a Mach-O')
        data = self.arm64_slice(data, path)
        self.path = path
        self.data = data
        self.fingerprint = hashlib.sha256(data).hexdigest()[:16]
        magic, cputype, _, _, ncmds = struct.unpack_from('<5I', data, 0)
        if magic != 0xFEEDFACF or cputype != 0x0100000C:
            sys.exit(f'{path}: not an arm64 Mach-O')
        self.segments, self.sections = [], []
        starts_cmd = fixups_cmd = None
        p = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<2I', data, p)
            if cmd == 0x19:                                 # LC_SEGMENT_64
                name = data[p + 8:p + 24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', data, p + 24)
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize))
                for s in range(struct.unpack_from('<I', data, p + 64)[0]):
                    q = p + 72 + 80 * s
                    sect = data[q:q + 16].rstrip(b'\0').decode()
                    seg = data[q + 16:q + 32].rstrip(b'\0').decode()
                    addr, ssize = struct.unpack_from('<2Q', data, q + 32)
                    self.sections.append((f'{seg},{sect}', addr, ssize, struct.unpack_from('<I', data, q + 64)[0]))
            elif cmd == 0x26:                               # LC_FUNCTION_STARTS
                starts_cmd = struct.unpack_from('<2I', data, p + 8)
            elif cmd == 0x80000034:                         # LC_DYLD_CHAINED_FIXUPS
                fixups_cmd = struct.unpack_from('<2I', data, p + 8)
            p += size
        if not starts_cmd or not fixups_cmd:
            sys.exit(f'{path}: no function starts or chained fixups')
        self.sections.sort(key=lambda s: s[1])
        self.section_starts = [s[1] for s in self.sections]
        self.base = next(s[1] for s in self.segments if s[0] == '__TEXT')
        text = next(s for s in self.sections if s[0] == '__TEXT,__text')
        self.ta, self.tend = text[1], text[1] + text[2]
        off = self.file_offset(self.ta)
        self.text = data[off:off + text[2]]
        self.words = memoryview(self.text).cast('I')
        self.starts = self.function_starts(*starts_cmd)
        self.n = len(self.starts) - 1
        self.rebases, self.binds = {}, {}
        self.read_fixups(*fixups_cmd)

    @staticmethod
    def arm64_slice(data, path):
        magic = struct.unpack_from('>I', data, 0)[0]
        if magic not in (0xCAFEBABE, 0xCAFEBABF):
            return data
        wide = magic == 0xCAFEBABF
        for i in range(struct.unpack_from('>I', data, 4)[0]):
            if wide:
                cputype, _, offset, size = struct.unpack_from('>IIQQ', data, 8 + 32 * i)
            else:
                cputype, _, offset, size = struct.unpack_from('>IIII', data, 8 + 20 * i)
            if cputype == 0x0100000C:
                return data[offset:offset + size]
        sys.exit(f'{path}: no arm64 slice')

    def function_starts(self, dataoff, datasize):
        data, starts, p, addr, end = self.data, [], dataoff, self.base, dataoff + datasize
        while p < end:
            value = shift = 0
            while True:
                c = data[p]; p += 1
                value |= (c & 0x7F) << shift; shift += 7
                if not c & 0x80: break
            if value == 0: break
            addr += value
            if self.ta <= addr < self.tend: starts.append(addr)
        starts.append(self.tend)
        return starts

    def read_fixups(self, dataoff, datasize):
        data = self.data
        _, starts_off, imports_off, symbols_off, count, imports_format, symbols_format = struct.unpack_from('<7I', data, dataoff)
        if symbols_format != 0:
            sys.exit(f'{self.path}: compressed fixup symbols')
        names = []
        for i in range(count):
            if imports_format == 1:
                name_off = struct.unpack_from('<I', data, dataoff + imports_off + 4 * i)[0] >> 9
            elif imports_format == 2:
                name_off = struct.unpack_from('<I', data, dataoff + imports_off + 8 * i)[0] >> 9
            elif imports_format == 3:
                name_off = struct.unpack_from('<Q', data, dataoff + imports_off + 16 * i)[0] >> 32
            else:
                sys.exit(f'{self.path}: unknown import format {imports_format}')
            s = dataoff + symbols_off + name_off
            names.append(data[s:data.index(b'\0', s)].decode('latin1'))
        image = dataoff + starts_off
        for s in range(struct.unpack_from('<I', data, image)[0]):
            info = struct.unpack_from('<I', data, image + 4 + 4 * s)[0]
            if not info: continue
            p = image + info
            _, page_size, pointer_format, segment_offset, _, page_count = struct.unpack_from('<IHHQIH', data, p)
            if pointer_format not in (2, 6):                # DYLD_CHAINED_PTR_64, DYLD_CHAINED_PTR_64_OFFSET
                sys.exit(f'{self.path}: unknown pointer format {pointer_format}')
            seg_vm = self.base + segment_offset
            seg = next(x for x in self.segments if x[1] == seg_vm)
            for page, start in enumerate(struct.unpack_from(f'<{page_count}H', data, p + 22)):
                if start == 0xFFFF: continue
                at = page * page_size + start
                while True:
                    raw = struct.unpack_from('<Q', data, seg[3] + at)[0]
                    if raw >> 63:
                        self.binds[seg_vm + at] = names[raw & 0xFFFFFF]
                    else:
                        target = raw & 0xFFFFFFFFF
                        if pointer_format == 6: target += self.base
                        self.rebases[seg_vm + at] = target | ((raw >> 36) & 0xFF) << 56
                    step = (raw >> 51) & 0xFFF
                    if not step: break
                    at += 4 * step

    def file_offset(self, addr):
        for _, vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= addr < vmaddr + vmsize:
                return fileoff + addr - vmaddr if addr - vmaddr < filesize else None
        return None

    def read(self, addr, n):
        off = self.file_offset(addr)
        return self.data[off:off + n] if off is not None else bytes(n)

    def cstring(self, addr):
        off = self.file_offset(addr)
        return self.data[off:self.data.index(b'\0', off)] if off is not None else b''

    def section(self, addr):
        i = bisect.bisect_right(self.section_starts, addr) - 1
        if i >= 0 and addr < self.sections[i][1] + self.sections[i][2]:
            return self.sections[i]
        for name, vmaddr, vmsize, _, _ in self.segments:
            if vmaddr <= addr < vmaddr + vmsize:
                return (f'{name} (no section)', vmaddr, vmsize, 0)      # such as the header, the dso handle
        return ('?', 0, 0, 0)

    def function(self, addr):
        """The index of the function holding addr, or None."""
        i = bisect.bisect_right(self.starts, addr) - 1
        return i if 0 <= i < self.n else None

    def function_at(self, addr):
        """The index of the function starting at addr, or None."""
        i = self.function(addr)
        return i if i is not None and self.starts[i] == addr else None

    def word(self, addr):
        return self.words[(addr - self.ta) >> 2]

    def stub_name(self, addr):
        """The import a __stubs entry jumps to: adrp x16, ldr x16, br x16."""
        if self.section(addr)[0] != '__TEXT,__stubs': return None
        off = self.file_offset(addr)
        w0, w1 = struct.unpack_from('<2I', self.data, off)
        if TOP[w0 >> 24] != ADRP or TOP[w1 >> 24] != LDSTU: return None
        return self.binds.get(adrp_page(w0, addr) + (((w1 >> 10) & 0xFFF) << (w1 >> 30)))


def page_use(w, t, page):
    """For an instruction whose base register holds an adrp page: (the address it uses, the access size, 0 for an
    address taken, and the instruction with its offset blanked), or None."""
    if t == ADDI:
        imm = (w >> 10) & 0xFFF
        return page + (imm << 12 if w & 0x400000 else imm), 0, w & ~0x3FFC00
    if t == LDSTU:
        scale = 4 if (w >> 26) & 1 and (w >> 23) & 1 else w >> 30
        return page + (((w >> 10) & 0xFFF) << scale), 1 << scale, w & ~0x3FFC00
    if t == LDSTP and not (w >> 23) & 1:
        opc = w >> 30
        scale = 2 + opc if (w >> 26) & 1 else 2 + (opc >> 1)
        return page + (sx((w >> 15) & 0x7F, 7) << scale), 2 << scale, w & ~(0x7F << 15)
    return None


def only_adrp(B, k0, k1, regs):
    """Those of regs that nothing but an adrp writes between words k0 and k1 (calls aside: nothing reads a register a
    call may have changed)."""
    regs = set(regs)
    for w in B.words[k0:k1]:
        t = TOP[w >> 24]
        if t == ADRP or t == BIMM or w & 0xFFFFFC1F == 0xD63F0000: continue
        for r in written(w, t):
            regs.discard(r)
        if not regs: break
    return regs


def blocks(ws):
    """A function's basic blocks: their first instructions, and the blocks each can be reached from. A block that
    nothing known reaches, such as a switch's case, gets no predecessors."""
    n = len(ws)
    lead, stops, jumps = bytearray(n + 1), bytearray(n), []
    lead[0] = 1
    for k, w in enumerate(ws):
        t = TOP[w >> 24]
        if t == BIMM:
            if w >> 31: continue                                                    # bl
            stops[k] = lead[k + 1] = 1
            to = k + sx(w & 0x3FFFFFF, 26)
        elif t == COND:
            lead[k + 1] = 1
            to = k + (sx((w >> 5) & 0x3FFF, 14) if w & 0x7E000000 == 0x36000000 else sx((w >> 5) & 0x7FFFF, 19))
        elif t == IND and w & 0xFFFFFC1F in (0xD61F0000, 0xD65F0000):              # br, ret
            stops[k] = lead[k + 1] = 1
            continue
        else:
            continue
        if 0 <= to < n:
            lead[to] = 1
            jumps.append((k, to))
    starts = [k for k in range(n) if lead[k]]
    index = {k: b for b, k in enumerate(starts)}
    preds = [[] for _ in starts]
    for b in range(1, len(starts)):
        if not stops[starts[b] - 1]: preds[b].append(b - 1)
    for k, to in jumps:
        preds[index[to]].append(bisect.bisect_right(starts, k) - 1)
    return starts, preds


def walk(B, i, refs=None, watch=None, found=None):
    """Normalise function i's code, so that a function that only moved looks the same as before: branch targets, adrp
    pages and the immediates that complete an adrp (add, ldr, str, ldp, stp) are blanked.

    Which registers hold which adrp page is followed through the function's blocks: a block starts with the pages its
    predecessors all agree on. A register that only adrp instructions of one page ever write holds that page wherever
    it's used, which covers blocks nothing known reaches.

    refs, a list, gets each data reference as (offset in the function, address, access size, 0 for an address taken).
    found, a dict, gets the pc and function of each branch or data reference to an address in watch."""
    s = B.starts[i]
    k0, k1 = (s - B.ta) >> 2, (B.starts[i + 1] - B.ta) >> 2
    ws = B.words[k0:k1]
    out = array('I', B.text[4 * k0:4 * k1])
    adrps, misses = {}, []

    def run(pages, a, b, final):
        """Follow the pages through instructions a to b. With final, blank and record what they're used for."""
        for k in range(a, b):
            w = ws[k]
            t = TOP[w >> 24]
            if t == ADRP:
                page = pages[w & 31] = adrp_page(w, s + 4 * k)
                if final:
                    out[k] = w & 0x9F00001F
                    adrps.setdefault(w & 31, set()).add(page)
                continue
            if t == BIMM:
                if final:
                    out[k] = w & 0xFC000000
                    if watch:
                        target = branch_target(w, s + 4 * k)
                        if target in watch: found[target].append((s + 4 * k, i))
                if w >> 31 and pages:
                    for r in [r for r in pages if r in CALLER_SAVED]: del pages[r]
                continue
            if t == ADR or t == LIT:
                if final:
                    out[k] = w & (0x9F00001F if t == ADR else 0xFF00001F)
                    if refs is not None:
                        if t == ADR: refs.append((4 * k, s + 4 * k + sx(((w >> 5) & 0x7FFFF) << 2 | (w >> 29) & 3, 21), 0))
                        else: refs.append((4 * k, s + 4 * k + 4 * sx((w >> 5) & 0x7FFFF, 19), 4 << (w >> 30 & 1)))
                if t == ADR or not (w >> 26) & 1: pages.pop(w & 31, None)
                continue
            if final and t >= ADDI:
                rn = (w >> 5) & 31
                if rn in pages: use(k, w, t, pages[rn])
                elif 9 <= rn <= 28: misses.append((k, w, t, rn))
            if pages:
                for r in written(w, t):
                    pages.pop(r, None)
        return pages

    def use(k, w, t, page):
        hit = page_use(w, t, page)
        if hit:
            target, size, out[k] = hit
            if refs is not None: refs.append((4 * k, target, size))
            if watch and target in watch: found[target].append((s + 4 * k, i))

    starts, preds = blocks(ws)
    ends = starts[1:] + [len(ws)]
    entry = [None] * len(starts)
    if len(starts) > 1 and any(TOP[w >> 24] == ADRP for w in ws):
        # Pages each block starts with: what all its known predecessors end with, until nothing changes.
        exits = [None] * len(starts)
        changed = True
        while changed:
            changed = False
            for b in range(len(starts)):
                if b == 0 or not preds[b]:
                    state = {}
                else:
                    state = None
                    for p in preds[b]:
                        o = exits[p]
                        if o is None: continue
                        state = dict(o) if state is None else {r: v for r, v in state.items() if o.get(r) == v}
                    if state is None: continue
                if exits[b] is not None and state == entry[b]: continue
                entry[b] = state
                o = run(dict(state), starts[b], ends[b], False)
                if o != exits[b]:
                    exits[b] = o
                    changed = True
    for b in range(len(starts)):
        run(dict(entry[b] or {}), starts[b], ends[b], True)
    wide = {r for _, _, _, r in misses if len(adrps.get(r, ())) == 1}
    if wide:
        wide = only_adrp(B, k0, k1, wide)
        for k, w, t, rn in misses:
            if rn in wide: use(k, w, t, next(iter(adrps[rn])))
    if refs is not None: refs.sort()
    return out


def code_hash(out):
    return hashlib.blake2b(out, digest_size=16).digest()


def scan(B, watch=()):
    """Every function's normalised hash, and where the watched addresses are branched to or referred to."""
    found = collections.defaultdict(list)
    watch = set(watch)
    hashes = [code_hash(walk(B, i, watch=watch, found=found)) for i in range(B.n)]
    return hashes, found


def in_order(pairs):
    """The longest run of (old, new) pairs, sorted by old, whose new indexes also increase."""
    tails, tails_at, prev = [], [], [-1] * len(pairs)
    for k, (_, b) in enumerate(pairs):
        p = bisect.bisect_left(tails, b)
        if p == len(tails): tails.append(b); tails_at.append(k)
        else: tails[p] = b; tails_at[p] = k
        prev[k] = tails_at[p - 1] if p else -1
    out, k = [], tails_at[-1] if tails_at else -1
    while k >= 0:
        out.append(pairs[k]); k = prev[k]
    return out[::-1]


def pair(ho, hn):
    """Old function index -> new, and how each pair was made: 'unique' (its code is unique in both builds), 'gap' (unique
    within the gap between two pairs) or 'position' (a gap with as many functions on each side)."""
    m, how = {}, {}
    work = [(0, len(ho), 0, len(hn), 'unique')]
    while work:
        a0, a1, b0, b1, label = work.pop()
        co, cn = collections.Counter(ho[a0:a1]), collections.Counter(hn[b0:b1])
        at = {h: j for j, h in enumerate(hn[b0:b1], b0) if cn[h] == 1}
        anchors = in_order([(i, at[h]) for i, h in enumerate(ho[a0:a1], a0) if co[h] == 1 and h in at])
        if not anchors:
            if a1 - a0 == b1 - b0:
                for k in range(a1 - a0):
                    m[a0 + k], how[a0 + k] = b0 + k, 'position'
            continue
        for i, j in anchors:
            m[i], how[i] = j, label
        bounds = [(a0 - 1, b0 - 1)] + anchors + [(a1, b1)]
        for (pi, pj), (qi, qj) in zip(bounds, bounds[1:]):
            if qi - pi > 1 and qj - pj > 1:
                work.append((pi + 1, qi, pj + 1, qj, 'gap'))
    return m, how


def ngrams(words, n=4):
    return collections.Counter(tuple(words[k:k + n]) for k in range(len(words) - n + 1))


def similarity(a, b):
    A, Bc = ngrams(a), ngrams(b)
    union = sum((A | Bc).values())
    return sum((A & Bc).values()) / union if union else 0.0


def loose(words):
    """Normalised code with every branch offset blanked too, sorted: the same instructions in any order."""
    out = []
    for w in words:
        if w & 0xFF000010 == 0x54000000 or w & 0x7E000000 == 0x34000000: w &= 0xFF00001F    # b.cond, cbz, cbnz
        elif w & 0x7E000000 == 0x36000000: w &= 0xFFF8001F                                  # tbz, tbnz
        out.append(w)
    return sorted(out)


def change(a, b):
    """How the normalised code of a function changed."""
    extra = sum((collections.Counter(loose(a)) - collections.Counter(loose(b))).values())
    extra = max(extra, sum((collections.Counter(loose(b)) - collections.Counter(loose(a))).values()))
    return (f'{4 * len(a)} -> {4 * len(b)} bytes, similarity {similarity(a, b):.2f}, '
            + ('the same instructions in another order' if not extra else f'{extra} instructions differ in any order'))


def mangled(name):
    """Class names as RTTI spells them, as Rtti.mangled does."""
    return [f'N2db{len(name)}{name}E', f'N7simatch{len(name)}{name}E', f'{len(name)}{name}']


def vtables(B):
    """Class name, as RTTI spells it -> [(offset to top, address point, slots)], from the chained fixups. A slot is a
    function's address, or None for a pure virtual one."""
    names = {}
    for loc, symbol in B.binds.items():
        if 'type_info' in symbol and loc + 8 in B.rebases:
            names[loc] = B.cstring(B.rebases[loc + 8] & ((1 << 56) - 1)).decode('latin1')
    out = collections.defaultdict(list)
    for loc, target in B.rebases.items():
        if target not in names or loc - 8 in B.rebases or loc - 8 in B.binds: continue
        top = struct.unpack('<q', B.read(loc - 8, 8))[0]
        if not -0x100000 < top <= 0: continue
        slots, p = [], loc + 8
        while True:
            value = B.rebases.get(p)
            if value is not None and B.ta <= value < B.tend: slots.append(value)
            elif B.binds.get(p, '').endswith(('__cxa_pure_virtual', '__cxa_deleted_virtual')): slots.append(None)
            else: break
            p += 8
        if slots:
            out[names[target]].append((top, loc + 8, slots))
    for v in out.values():
        v.sort(key=lambda x: (-x[0], x[1]))
    return out


def class_vtables(V, name):
    return sorted((v for spelling in mangled(name) for v in V.get(spelling, [])), key=lambda x: (-x[0], x[1]))


def parse_value(text):
    text = text.strip().replace('_', '')
    if text.startswith('"'): return text.strip('"')
    if re.fullmatch(r'-?\d+\.\d*', text): return float(text)
    m = re.fullmatch(r'(-?0x[0-9a-fA-F]+|-?\d+)(?:\s*([/*])\s*(0x[0-9a-fA-F]+|\d+))?', text)
    if not m: return text
    value = int(m[1], 0)
    if m[2] == '/': value //= int(m[3], 0)
    elif m[2] == '*': value *= int(m[3], 0)
    return value


def mac27_values(path):
    """Mac27's values in RulesEngine.swift, in their order."""
    source = open(path).read()
    block = re.search(r'enum Mac27 \{\n(.*?)\n    \}', source, re.S)
    if not block: sys.exit(f'{path}: no Mac27')
    values = {}
    for line in block[1].splitlines():
        m = re.match(r'\s*static let (\w+)(?:\s*:\s*\w+)?\s*=\s*(.+?)\s*(?://.*)?$', line)
        if m: values[m[1]] = parse_value(m[2])
    return values


def show(name, value):
    if isinstance(value, int) and KINDS.get(name, ('',))[0] in ('function', 'global', 'constant'): return hex(value)
    return str(value)


class Matcher:
    """Two builds with their functions paired, and the checks for each kind of value."""

    def __init__(self, O, N, old):
        self.O, self.N, self.old = O, N, old
        self.VO, self.VN = vtables(O), vtables(N)
        self.reader_points = {}
        watch_old = {v for k, v in old.items() if KINDS.get(k, ('',))[0] in ('function', 'global')}
        watch_new = set()
        for name in READER_CLASSES:
            po = [ap for _, ap, _ in class_vtables(self.VO, name)]
            pn = [ap for _, ap, _ in class_vtables(self.VN, name)]
            self.reader_points[name] = (po, pn)
            watch_old.update(po); watch_new.update(pn)
        self.ho, self.found_old = scan(O, watch_old)
        self.hn, self.found_new = scan(N, watch_new)
        self.m, self.how = pair(self.ho, self.hn)
        self.refs_cache = {}
        self.new = {}

    def same(self, i):
        j = self.m.get(i)
        return j is not None and self.ho[i] == self.hn[j]

    def refs(self, B, i):
        key = (id(B), i)
        if key not in self.refs_cache:
            out = []
            walk(B, i, refs=out)
            self.refs_cache[key] = out
        return self.refs_cache[key]

    # Comparing what an unchanged function uses.

    def same_pointer(self, a, b):
        """Whether two addresses, one from each build, are the same thing."""
        O, N = self.O, self.N
        if O.ta <= a < O.tend:
            i, j = O.function(a), N.function(b)
            return i is not None and j is not None and self.m.get(i) == j and a - O.starts[i] == b - N.starts[j]
        sa, sb = O.section(a), N.section(b)
        if sa[0] != sb[0]: return False
        if sa[3] & 0xFF == 2: return O.cstring(a) == N.cstring(b)
        return True

    def same_content(self, a, b, n):
        """Whether n bytes at a in the old build hold the same as at b in the new one. Pointers count as the same when
        they point at the same thing."""
        O, N = self.O, self.N
        ra, rb = bytearray(O.read(a, n)), bytearray(N.read(b, n))
        for loc in range(a - a % 8, a + n, 8):
            fo, fn_ = O.rebases.get(loc, O.binds.get(loc)), N.rebases.get(loc + b - a, N.binds.get(loc + b - a))
            if fo is None and fn_ is None: continue
            if type(fo) is not type(fn_): return False
            if isinstance(fo, str): ok = fo == fn_
            else: ok = self.same_pointer(fo & ((1 << 56) - 1), fn_ & ((1 << 56) - 1))
            if not ok: return False
            lo, hi = max(loc, a) - a, min(loc + 8, a + n) - a
            ra[lo:hi] = rb[lo:hi] = bytes(hi - lo)
        return ra == rb

    def check_data(self, i, j):
        """Each data reference of an unchanged function, against its new one. Returns (problems, moves)."""
        O, N = self.O, self.N
        ro, rn = self.refs(O, i), self.refs(N, j)
        problems, moves = [], collections.Counter()
        if [r[0] for r in ro] != [r[0] for r in rn]:
            return [f'{len(ro)} data references, now {len(rn)}'], moves
        for (off, a, size), (_, b, _) in zip(ro, rn):
            sa, sb = O.section(a), N.section(b)
            where = f'{hex(O.starts[i] + off)}: {hex(a)} {sa[0]} -> {hex(b)} {sb[0]}'
            if sa[0] != sb[0]:
                problems.append(f'{where}, another section'); continue
            if sa[0] == '__TEXT,__text':
                if not self.same_pointer(a, b): problems.append(f'{where}, code that doesn\'t pair')
                continue
            moves[(sa[0], b - a)] += 1
            if sa[3] & 0xFF in (1, 0x0C, 0x12):  # zero fill: nothing to compare
                continue
            if sa[3] & 0xFF == 2:
                if O.cstring(a) != N.cstring(b): problems.append(f'{where}, another string')
                continue
            if not self.same_content(a, b, size or 8):
                problems.append(f'{where}, other content: {O.read(a, size or 8).hex()} / {N.read(b, size or 8).hex()}')
        return problems, moves

    def slot_pairs(self, a, b):
        """Whether old function a pairs with new function b."""
        i, j = self.O.function_at(a), self.N.function_at(b)
        return i is not None and j is not None and self.m.get(i) == j

    def compare_slots(self, a, b):
        """Two vtables' slots: how many pair, how many hold a function whose code changed and didn't pair, and how
        many pair with something else."""
        pairs = changed = other = 0
        for x, y in zip(a, b):
            i, j = (self.O.function_at(x) if x else None), (self.N.function_at(y) if y else None)
            if x is None and y is None or i is not None and j is not None and self.m.get(i) == j: pairs += 1
            elif i is not None and self.m.get(i) is None: changed += 1
            else: other += 1
        return pairs, changed, other

    def check_calls(self, i, j):
        """Each branch out of an unchanged function, and each branch inside it, against its new one. A call to a
        function whose code changed is a note: its new code is FM's own, which the rules engine runs as it is."""
        O, N = self.O, self.N
        so, sn = O.starts[i], N.starts[j]
        ok, problems, notes = 0, [], collections.Counter()
        for k, w in enumerate(O.words[(so - O.ta) >> 2:(O.starts[i + 1] - O.ta) >> 2]):
            if TOP[w >> 24] != BIMM: continue
            a, b = branch_target(w, so + 4 * k), branch_target(N.word(sn + 4 * k), sn + 4 * k)
            if so <= a < O.starts[i + 1]:
                good = a - so == b - sn
            elif O.section(a)[0] == '__TEXT,__stubs':
                good = O.stub_name(a) is not None and O.stub_name(a) == N.stub_name(b)
            else:
                ci, cj = O.function_at(a), N.function_at(b)
                good = self.slot_pairs(a, b) and self.same(ci)
                if not good and ci is not None and cj is not None:
                    if self.m.get(ci) not in (None, cj):
                        problems.append(f'{hex(so + 4 * k)}: calls {hex(a)}, now {hex(b)}, but {hex(a)} pairs with '
                                        f'{hex(N.starts[self.m[ci]])}')
                    else:
                        notes[(a, b)] += 1
                    continue
            if good: ok += 1
            else: problems.append(f'{hex(so + 4 * k)}: branch to {hex(a)}, now {hex(b)}, which doesn\'t pair')
        notes = [f'note: calls {hex(a)}' + (f' ({c} times)' if c > 1 else '') + f', now {hex(b)}, whose code changed: '
                 + change(walk(O, O.function_at(a)), walk(N, N.function_at(b))) for (a, b), c in notes.items()]
        return ok, problems, notes

    def callers(self, a):
        """New addresses that unchanged callers of old address a now call, with counts, and how many callers changed."""
        votes, changed = collections.Counter(), 0
        for pc, i in self.found_old.get(a, []):
            if not self.same(i): changed += 1; continue
            j = self.m[i]
            npc = self.N.starts[j] + pc - self.O.starts[i]
            votes[branch_target(self.N.word(npc), npc)] += 1
        return votes, changed

    # The values.

    def fingerprint(self, name, value):
        lines = [f'SHA-256 of the arm64 slice: old {self.O.fingerprint}, new {self.N.fingerprint}']
        if value != self.O.fingerprint:
            return self.N.fingerprint, 'CHECK', lines + [f'the old value {value} isn\'t the old build\'s: is OLD the right build?']
        return self.N.fingerprint, 'FOUND', lines

    def function(self, name, a):
        O, N = self.O, self.N
        i = O.function_at(a)
        if i is None:
            return None, 'MISSING', [f'{hex(a)} isn\'t a function start in the old build: is OLD the right build?']
        j = self.m.get(i)
        size = O.starts[i + 1] - a
        votes, changed = self.callers(a)
        call_note = (f'{sum(votes.values())} unchanged call sites call ' + ', '.join(f'{hex(v)} ({c})' for v, c in votes.most_common())
                     if votes else 'no unchanged call sites') + (f'; {changed} callers changed' if changed else '')
        lines = []
        if j is not None and self.ho[i] == self.hn[j]:
            b = N.starts[j]
            problems, moves = self.check_data(i, j)
            ok, call_problems, notes = self.check_calls(i, j)
            refs = sum(moves.values())
            lines.append(f'same code ({self.how[i]} pair), {size} bytes; {len(self.refs(O, i))} data references'
                         + (f', {refs} moved by ' + ', '.join(f'{d:+#x} ({s})' for (s, d) in sorted({k for k in moves})) if refs else '')
                         + f'; {ok} branches agree')
            lines.append(call_note)
            lines += problems + call_problems + notes
            if votes and set(votes) != {b}:
                lines.append('callers disagree with the pairing')
                return b, 'CHECK', lines
            return b, ('CHECK' if problems or call_problems else 'FOUND'), lines
        # The code changed, or it didn't pair: go by its callers.
        b = None
        if len(votes) == 1:
            b = next(iter(votes))
            lines.append(f'found through its callers: {call_note}')
        elif j is not None:
            b = N.starts[j]
            lines.append(f'paired by {self.how[i]} only; {call_note}')
        else:
            lines.append(call_note)
        if b is not None and N.function_at(b) is not None:
            nj = N.function_at(b)
            lines.append(f'its code changed: {change(walk(O, i), walk(N, nj))}' + (', paired with it' if self.m.get(i) == nj else ''))
            oc = [x for x in self.calls(O, i)]
            nc = collections.Counter(self.calls(N, nj))
            agree = sum(1 for c in oc if c is not None and self.m.get(c) in nc)
            lines.append(f'{agree} of its {len(oc)} calls go to functions that pair with the new one\'s ({sum(nc.values())})')
            return b, 'CHECK', lines
        lines += self.candidates(i)
        return None, 'MISSING', lines

    def calls(self, B, i):
        s = B.starts[i]
        out = []
        for k, w in enumerate(B.words[(s - B.ta) >> 2:(B.starts[i + 1] - B.ta) >> 2]):
            if w & 0xFC000000 == 0x94000000:
                out.append(B.function_at(branch_target(w, s + 4 * k)))
        return out

    def candidates(self, i):
        """Likely new functions, between the nearest pairs around it."""
        O, N = self.O, self.N
        lo = max((k for k in range(i - 1, max(-1, i - 200), -1) if k in self.m), default=None)
        hi = min((k for k in range(i + 1, min(O.n, i + 200)) if k in self.m), default=None)
        if lo is None or hi is None: return ['no pairs nearby to search between']
        ow = walk(O, i)
        out = []
        for j in range(self.m[lo] + 1, self.m[hi]):
            nw = walk(N, j)
            if 0.5 * len(ow) <= len(nw) <= 2 * len(ow):
                out.append((similarity(ow, nw), j))
        out.sort(reverse=True)
        return [f'candidate {hex(N.starts[j])}, {N.starts[j + 1] - N.starts[j]} bytes, similarity {s:.2f}' for s, j in out[:3]]

    def global_(self, name, g):
        O, N = self.O, self.N
        votes, changed = collections.Counter(), 0
        for pc, i in self.found_old.get(g, []):
            if not self.same(i): changed += 1; continue
            j = self.m[i]
            off = pc - O.starts[i]
            hit = [b for (o, b, _) in self.refs(N, j) if o == off]
            if hit: votes[hit[0]] += 1
        lines = [f'{sum(votes.values())} references in unchanged functions: '
                 + ', '.join(f'{hex(v)} ({c})' for v, c in votes.most_common()) + (f'; {changed} in changed ones' if changed else '')]
        if not votes:
            return None, 'MISSING', lines
        b = votes.most_common(1)[0][0]
        so, sn = O.section(g), N.section(b)
        lines.append(f'{so[0]} moved {sn[1] - so[1]:+#x}, this {b - g:+#x}')
        return b, ('FOUND' if len(votes) == 1 and so[0] == sn[0] else 'CHECK'), lines

    def slot(self, name, slot, cls, top):
        O, N = self.O, self.N
        ov = [v for v in class_vtables(self.VO, cls) if v[0] == top]
        nv = [v for v in class_vtables(self.VN, cls) if v[0] == top]
        lines = [f'{cls} vtable at offset to top {top:#x}: {len(ov)} in old, {len(nv)} in new']
        if not ov or not nv:
            return None, 'MISSING', lines
        if len(ov) != 1 or len(nv) != 1:
            lines.append('more than one, so the first of each is compared')
        (_, oap, os_), (_, nap, ns_) = ov[0], nv[0]
        pairs, changed, other = self.compare_slots(os_, ns_)
        lines.append(f'address point {hex(oap)} -> {hex(nap)}, {len(os_)} -> {len(ns_)} slots: {pairs} pair'
                     + (f', {changed} changed' if changed else '') + (f', {other} pair with another slot\'s' if other else ''))
        if slot >= len(os_) or os_[slot] is None:
            return None, 'MISSING', lines + [f'the old vtable has no function in slot {slot}']
        i = O.function_at(os_[slot])
        j = self.m.get(i) if i is not None else None
        if j is None:
            if len(os_) == len(ns_) and slot < len(ns_) and ns_[slot] and not other:
                return slot, 'CHECK', lines + [f'slot {slot}: {hex(os_[slot])} -> {hex(ns_[slot])}, whose code changed: '
                                               + change(walk(O, i), walk(N, N.function_at(ns_[slot])))]
            return None, 'MISSING', lines + [f'slot {slot}\'s function {hex(os_[slot])} doesn\'t pair']
        now = [k for k, b in enumerate(ns_) if b and N.function_at(b) == j]
        if slot not in now:
            return (now[0] if now else None), ('CHECK' if now else 'MISSING'), lines + [f'its function is now in slots {now}']
        same = self.ho[i] == self.hn[j]
        lines.append(f'slot {slot}: {hex(os_[slot])} -> {hex(ns_[slot])}, ' + ('same code' if same else 'its code changed'))
        if same:
            problems, _ = self.check_data(i, j)
            _, call_problems, notes = self.check_calls(i, j)
            lines += problems + call_problems + notes
            same = not problems and not call_problems
        return slot, ('FOUND' if same and len(os_) == len(ns_) else 'CHECK'), lines

    def object_calls(self, B, g, sites):
        """The vtable slots called on the object that global g holds, in the functions that load it."""
        slots = collections.Counter()
        loads = 0
        for i in sorted({i for _, i in sites}):
            s = B.starts[i]
            state = {}
            for k, w in enumerate(B.words[(s - B.ta) >> 2:(B.starts[i + 1] - B.ta) >> 2]):
                t = TOP[w >> 24]
                if t == ADRP:
                    state[w & 31] = ('page', adrp_page(w, s + 4 * k)); continue
                if w & 0xFFFFFC1F == 0xD63F0000:                                  # blr
                    held = state.get((w >> 5) & 31)
                    if held and held[0] == 'fn': slots[held[1]] += 1
                if w & 0xFFE0FFE0 == 0xAA0003E0:                                  # mov xd, xm
                    held = state.get((w >> 16) & 31)
                    state.pop(w & 31, None)
                    if held: state[w & 31] = held
                    continue
                held = state.get((w >> 5) & 31)
                new = None
                if held and t == LDSTU and w >> 30 == 3 and (w >> 22) & 3 == 1 and not (w >> 26) & 1:  # ldr x
                    off = ((w >> 10) & 0xFFF) << 3
                    if held[0] == 'page' and held[1] + off == g or held == ('addr', g) and off == 0:
                        new = ('object',); loads += 1
                    elif held[0] == 'object' and off == 0: new = ('vtable',)
                    elif held[0] == 'vtable': new = ('fn', off // 8)
                elif held and t == ADDI and held[0] == 'page':
                    new = ('addr', held[1] + ((w >> 10) & 0xFFF))
                if t == BIMM and w >> 31:
                    for r in [r for r in state if r in CALLER_SAVED]: del state[r]
                else:
                    for r in written(w, t): state.pop(r, None)
                if new: state[w & 31] = new
        return loads, slots

    def callslot(self, name, slot, global_name):
        g_old, g_new = self.old.get(global_name), self.new.get(global_name)
        if g_old is None or g_new is None:
            return None, 'MISSING', [f'needs {global_name} first']
        new_sites = self.find_refs(self.N, g_new)
        lo, so = self.object_calls(self.O, g_old, self.found_old.get(g_old, []))
        ln, sn = self.object_calls(self.N, g_new, new_sites)
        lines = [f'calls through {global_name}\'s object: old {lo} loads, slots {dict(sorted(so.items()))}',
                 f'                                  new {ln} loads, slots {dict(sorted(sn.items()))}']
        if so and so == sn and slot in so:
            return slot, 'FOUND', lines
        return (slot if slot in sn else None), 'CHECK', lines

    def find_refs(self, B, g):
        """Every data reference to g in B, as (pc, function): one pass over the code's adrp instructions."""
        page = g & ~0xFFF
        sites = []
        funcs = set()
        for k, w in enumerate(B.words):
            if w & 0x9F000000 == 0x90000000 and adrp_page(w, B.ta + 4 * k) == page:
                funcs.add(B.function(B.ta + 4 * k))
        for i in funcs:
            if i is None: continue
            sites += [(B.starts[i] + off, i) for off, b, _ in self.refs(B, i) if b == g]
        return sites

    def constant(self, name, value, function_name):
        f_old, f_new = self.old.get(function_name), self.new.get(function_name)
        if f_old is None or f_new is None:
            return None, 'MISSING', [f'needs {function_name} first']
        co, cn = self.builds(self.O, f_old, value), self.builds(self.N, f_new, value)
        lines = [f'{function_name} builds {value:#x} {co} times in the old build, {cn} in the new']
        return value, ('FOUND' if co and co == cn else 'CHECK'), lines

    def builds(self, B, start, value):
        """How many times the function at start makes value with a mov and a movk."""
        i = B.function_at(start)
        if i is None: return 0
        ws = list(B.words[(start - B.ta) >> 2:(B.starts[i + 1] - B.ta) >> 2])
        count = 0
        for k, w in enumerate(ws):
            if w & 0x7FE00000 == 0x52800000 and (w >> 5) & 0xFFFF == value & 0xFFFF:              # movz, lsl 0
                for x in ws[k + 1:k + 6]:
                    if x & 0x7FE00000 == 0x72A00000 and x & 31 == w & 31 and (x >> 5) & 0xFFFF == value >> 16:  # movk, lsl 16
                        count += 1; break
        return count

    def run(self, name, value):
        kind = KINDS.get(name)
        if kind is None:
            return None, 'MISSING', ['the tool doesn\'t know what this value is: add it to KINDS']
        if kind[0] == 'fingerprint': return self.fingerprint(name, value)
        if kind[0] == 'function': return self.function(name, value)
        if kind[0] == 'global': return self.global_(name, value)
        if kind[0] == 'slot': return self.slot(name, value, kind[1], kind[2])
        if kind[0] == 'callslot': return self.callslot(name, value, kind[1])
        if kind[0] == 'constant': return self.constant(name, value, kind[1])
        return value, 'FOUND', ['a value, not an address: nothing to match']

    def reader_class(self, name):
        O, N = self.O, self.N
        ov, nv = class_vtables(self.VO, name), class_vtables(self.VN, name)
        if not ov or not nv:
            return f'{name}: no vtable in the {"old" if not ov else "new"} build', False
        tops_o, tops_n = [hex(v[0]) for v in ov], [hex(v[0]) for v in nv]
        lengths = [len(v[2]) for v in ov] == [len(v[2]) for v in nv]
        counts = [self.compare_slots(a, b) for (_, _, a), (_, _, b) in zip(ov, nv)]
        pairs, changed_slots, other = (sum(c[k] for c in counts) for k in range(3))
        po, pn = self.reader_points.get(name) or ([v[1] for v in ov], [v[1] for v in nv])
        fo = {i for ap in po for _, i in self.found_old.get(ap, [])}
        fn_ = {i for ap in pn for _, i in self.found_new.get(ap, [])}
        paired = [i for i in fo if self.m.get(i) in fn_]
        same = [i for i in paired if self.same(i)]
        changed = sorted(hex(O.starts[i]) for i in fo if i not in same)
        good = tops_o == tops_n and lengths and not other and len(same) == len(fo) == len(fn_)
        text = (f'{name}: offsets to top {" ".join(tops_o)}' + ('' if tops_o == tops_n else f', now {" ".join(tops_n)}')
                + f'; {len(ov)} vtables, ' + ('same lengths' if lengths else 'lengths changed')
                + f'; slots: {pairs} pair' + (f', {changed_slots} changed' if changed_slots else '')
                + (f', {other} pair with another slot\'s' if other else '')
                + f'; {len(fo)} functions build them (new {len(fn_)}), {len(same)} with the same code'
                + (f'; changed: {" ".join(changed[:6])}' if changed else ''))
        return text, good


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('old', help='the old build\'s game_plugin')
    parser.add_argument('new', help='the new build\'s game_plugin')
    parser.add_argument('values', nargs='*', help='old values as name=value; without any, Mac27\'s from --rules')
    parser.add_argument('--rules', default=RULES, help='RulesEngine.swift, for the old values (default: this repo\'s)')
    parser.add_argument('--class', dest='classes', action='append', default=[], help='another class to check, such as TEAM')
    args = parser.parse_args()
    if args.values:
        old = {}
        for item in args.values:
            name, _, value = item.partition('=')
            if not value: parser.error(f'{item}: expected name=value')
            old[name] = value if name == 'fingerprint' else parse_value(value)
    else:
        old = mac27_values(args.rules)
    READER_CLASSES.extend(args.classes)

    O, N = Image(args.old), Image(args.new)
    M = Matcher(O, N, old)
    same = sum(1 for i in M.m if M.same(i))
    print(f'old {os.path.basename(O.path)}: fingerprint {O.fingerprint}, {O.n:,} functions')
    print(f'new {os.path.basename(N.path)}: fingerprint {N.fingerprint}, {N.n:,} functions')
    unique = sum(1 for h in M.how.values() if h == 'unique')
    print(f'paired {len(M.m):,} functions ({unique:,} by code unique in both builds), {same:,} with the same code')
    new_sections = {s[0]: s[1] for s in N.sections}
    moved = [(s[0], new_sections[s[0]] - s[1]) for s in O.sections if s[0] in new_sections]
    print('sections moved: ' + (', '.join(f'{s} {d:+#x}' for s, d in moved if d) or 'none'))
    counts, grown = [0, 0, 0], 0
    for name, vs in M.VO.items():
        ns = M.VN.get(name, [])
        if [v[0] for v in vs] != [v[0] for v in ns]: continue
        for (_, _, a), (_, _, b) in zip(vs, ns):
            grown += len(a) != len(b)
            counts = [x + y for x, y in zip(counts, M.compare_slots(a, b))]
    print(f'vtables: {len(M.VO):,} classes old, {len(M.VN):,} new, {grown} changed length; slots: {counts[0]:,} pair, '
          f'{counts[1]:,} changed, {counts[2]:,} pair with another slot\'s')

    print('\nMac27')
    results = []
    order = sorted(old, key=lambda k: (KINDS.get(k, ('',))[0] in ('callslot', 'constant'), list(old).index(k)))
    for name in order:
        new, verdict, lines = M.run(name, old[name])
        if new is not None: M.new[name] = new
        results.append((name, new, verdict))
        print(f'  {name:24} {show(name, old[name]):>18} -> {show(name, new) if new is not None else "?":18} {verdict}')
        for line in lines:
            print(f'      {line}')

    print('\nReader classes (a good sign, not proof: Load Save\'s self-check is the test)')
    for name in READER_CLASSES:
        text, good = M.reader_class(name)
        print(f'  {"same" if good else "LOOK"}  {text}')

    print('\nSummary')
    for name in old:
        new, verdict = next((n, v) for k, n, v in results if k == name)
        print(f'  {name:24} {show(name, old[name]):>18} -> {show(name, new) if new is not None else "?":18} {verdict}'
              + ('' if new is None or new == old[name] else '  (changed)'))
    return 0 if all(v == 'FOUND' for _, _, v in results) else 3


if __name__ == '__main__':
    sys.exit(main())
