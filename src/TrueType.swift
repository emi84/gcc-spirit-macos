// Reads glyph outlines straight from a TrueType font embedded in a PDF (FontFile2), so that text
// drawn as an outline can be cut. Plain parsing rather than CoreText: the filter runs in CUPS's
// sandbox and the fonts are subsets holding only the tables a PDF needs. Every read is bounds
// checked; a damaged font gives empty outlines, never a crash.

import CoreGraphics

enum GlyphSegment {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, CGPoint)     // control, end
    case close
}

final class TrueTypeFont {
    private let d: [UInt8]
    private var tables: [String: (offset: Int, length: Int)] = [:]
    private let unitsPerEm: CGFloat
    private let longLoca: Bool
    private let glyphCount: Int
    private let metricCount: Int
    private var outlines: [Int: [GlyphSegment]] = [:]

    init?(data: [UInt8]) {
        d = data
        guard data.count > 12 else { return nil }
        let n = Int(data[4]) << 8 | Int(data[5])
        for i in 0..<n where 12 + 16 * i + 16 <= data.count {
            let e = 12 + 16 * i
            let tag = String(decoding: data[e..<e + 4], as: UTF8.self)
            let o = data[e + 8..<e + 12].reduce(0) { $0 << 8 | Int($1) }
            let l = data[e + 12..<e + 16].reduce(0) { $0 << 8 | Int($1) }
            tables[tag] = (o, l)
        }
        guard let head = tables["head"], let maxp = tables["maxp"], tables["glyf"] != nil, tables["loca"] != nil,
              head.offset + 54 <= data.count, maxp.offset + 6 <= data.count else { return nil }
        let upm = Int(data[head.offset + 18]) << 8 | Int(data[head.offset + 19])
        unitsPerEm = CGFloat(max(upm, 1))
        longLoca = data[head.offset + 51] != 0
        glyphCount = Int(data[maxp.offset + 4]) << 8 | Int(data[maxp.offset + 5])
        if let hhea = tables["hhea"], hhea.offset + 36 <= data.count {
            metricCount = Int(data[hhea.offset + 34]) << 8 | Int(data[hhea.offset + 35])
        } else {
            metricCount = 0
        }
    }

    private func u8(_ o: Int) -> Int { o >= 0 && o < d.count ? Int(d[o]) : 0 }
    private func u16(_ o: Int) -> Int { u8(o) << 8 | u8(o + 1) }
    private func i16(_ o: Int) -> Int { let v = u16(o); return v >= 0x8000 ? v - 0x10000 : v }
    private func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }

    /// The glyph of a one-byte character code, through the font's own cmap: Quartz renumbers the
    /// characters of a subset and keeps the mapping in the (1,0) table.
    func glyph(forCode code: Int) -> Int {
        guard let cmap = tables["cmap"] else { return code }
        let n = u16(cmap.offset + 2)
        var subtables: [(platform: Int, encoding: Int, offset: Int)] = []
        for i in 0..<min(n, 32) {
            let e = cmap.offset + 4 + 8 * i
            subtables.append((u16(e), u16(e + 2), cmap.offset + u32(e + 4)))
        }
        for (p, e) in [(1, 0), (3, 0), (3, 1), (0, 3)] {
            guard let t = subtables.first(where: { $0.platform == p && $0.encoding == e }) else { continue }
            let g = lookup(t.offset, code) != 0 ? lookup(t.offset, code) : (p == 3 && e == 0 ? lookup(t.offset, 0xF000 | code) : 0)
            if g != 0 { return g }
        }
        return 0
    }

    private func lookup(_ t: Int, _ code: Int) -> Int {
        switch u16(t) {
        case 0:
            return code < 256 ? u8(t + 6 + code) : 0
        case 6:
            let first = u16(t + 6), count = u16(t + 8)
            return code >= first && code < first + count ? u16(t + 10 + 2 * (code - first)) : 0
        case 4:
            let segX2 = u16(t + 6)
            for i in 0..<segX2 / 2 {
                let end = u16(t + 14 + 2 * i)
                guard code <= end else { continue }
                let startAt = t + 16 + segX2 + 2 * i
                let start = u16(startAt)
                guard code >= start else { return 0 }
                let delta = u16(startAt + segX2)
                let rangeAt = startAt + 2 * segX2
                let range = u16(rangeAt)
                if range == 0 { return (code + delta) & 0xFFFF }
                let g = u16(rangeAt + range + 2 * (code - start))
                return g == 0 ? 0 : (g + delta) & 0xFFFF
            }
            return 0
        default:
            return 0
        }
    }

    /// The advance of a glyph, in ems.
    func advance(_ gid: Int) -> CGFloat {
        guard let hmtx = tables["hmtx"], metricCount > 0 else { return 0 }
        return CGFloat(u16(hmtx.offset + 4 * min(gid, metricCount - 1))) / unitsPerEm
    }

    /// The outline of a glyph, in ems.
    func outline(_ gid: Int) -> [GlyphSegment] {
        if let o = outlines[gid] { return o }
        let scale = CGAffineTransform(scaleX: 1 / unitsPerEm, y: 1 / unitsPerEm)
        let o = contours(gid, depth: 0).flatMap { segments($0.map { (p: $0.p.applying(scale), on: $0.on) }) }
        outlines[gid] = o
        return o
    }

    private typealias Contour = [(p: CGPoint, on: Bool)]

    private func contours(_ gid: Int, depth: Int) -> [Contour] {
        guard gid >= 0, gid < glyphCount, depth < 6, let loca = tables["loca"], let glyf = tables["glyf"] else { return [] }
        let start = longLoca ? u32(loca.offset + 4 * gid) : 2 * u16(loca.offset + 2 * gid)
        let end = longLoca ? u32(loca.offset + 4 * gid + 4) : 2 * u16(loca.offset + 2 * gid + 2)
        guard end > start, glyf.offset + end <= d.count else { return [] }
        let g = glyf.offset + start
        let count = i16(g)
        return count >= 0 ? simple(g, count) : composite(g + 10, depth)
    }

    private func simple(_ g: Int, _ count: Int) -> [Contour] {
        var o = g + 10
        var ends: [Int] = []
        for i in 0..<count { ends.append(u16(o + 2 * i)) }
        o += 2 * count
        o += 2 + u16(o)                                 // the hinting instructions
        guard let last = ends.last, last < 20_000 else { return [] }
        let total = last + 1
        var flags: [Int] = []
        while flags.count < total, o < d.count {
            let f = u8(o); o += 1
            flags.append(f)
            if f & 8 != 0 {
                let r = u8(o); o += 1
                flags += [Int](repeating: f, count: min(r, total - flags.count))
            }
        }
        guard flags.count == total else { return [] }
        func axis(short: Int, same: Int) -> [Int] {
            var v = 0, out: [Int] = []
            for f in flags {
                if f & short != 0 {
                    v += f & same != 0 ? u8(o) : -u8(o)
                    o += 1
                } else if f & same == 0 {
                    v += i16(o)
                    o += 2
                }
                out.append(v)
            }
            return out
        }
        let xs = axis(short: 2, same: 16)
        let ys = axis(short: 4, same: 32)
        var result: [Contour] = []
        var first = 0
        for e in ends where e >= first && e < total {
            result.append((first...e).map { (CGPoint(x: xs[$0], y: ys[$0]), flags[$0] & 1 != 0) })
            first = e + 1
        }
        return result
    }

    private func composite(_ start: Int, _ depth: Int) -> [Contour] {
        var o = start
        var result: [Contour] = []
        for _ in 0..<64 {
            let f = u16(o), gid = u16(o + 2)
            o += 4
            var dx = 0, dy = 0
            if f & 1 != 0 {
                dx = i16(o); dy = i16(o + 2); o += 4
            } else {
                dx = u8(o) >= 128 ? u8(o) - 256 : u8(o)
                dy = u8(o + 1) >= 128 ? u8(o + 1) - 256 : u8(o + 1)
                o += 2
            }
            if f & 2 == 0 { dx = 0; dy = 0 }            // anchored on points: rare, left in place
            func f2dot14(_ p: Int) -> CGFloat { CGFloat(i16(p)) / 16384 }
            var m = CGAffineTransform.identity
            if f & 8 != 0 {
                m.a = f2dot14(o); m.d = m.a; o += 2
            } else if f & 0x40 != 0 {
                m.a = f2dot14(o); m.d = f2dot14(o + 2); o += 4
            } else if f & 0x80 != 0 {
                m.a = f2dot14(o); m.b = f2dot14(o + 2); m.c = f2dot14(o + 4); m.d = f2dot14(o + 6); o += 8
            }
            m.tx = CGFloat(dx); m.ty = CGFloat(dy)
            result += contours(gid, depth: depth + 1).map { $0.map { (p: $0.p.applying(m), on: $0.on) } }
            if f & 0x20 == 0 { break }
        }
        return result
    }

    /// A contour's points → segments: two control points in a row have an implied point between them.
    private func segments(_ c: Contour) -> [GlyphSegment] {
        guard c.count > 1 else { return [] }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var points = c
        if let i = points.firstIndex(where: { $0.on }) {
            points = Array(points[i...] + points[..<i])
        } else {
            points.insert((mid(points[points.count - 1].p, points[0].p), true), at: 0)
        }
        var out: [GlyphSegment] = [.move(points[0].p)]
        var control: CGPoint?
        for q in points.dropFirst() + [points[0]] {
            if q.on {
                if let k = control { out.append(.quad(k, q.p)) } else { out.append(.line(q.p)) }
                control = nil
            } else {
                if let k = control { out.append(.quad(k, mid(k, q.p))) }
                control = q.p
            }
        }
        out.append(.close)
        return out
    }
}
