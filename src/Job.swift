// Writes a GCC LaserPro job in the format of the official Spirit driver ("Exp" output mode,
// machine model 1). Every command, its order and its arithmetic follow the decompiled driver;
// the function each part comes from is named in docs/PROTOCOLE.md.

import Foundation

/// Machine constants of the Spirit (official Spirit.ini, [MACHINE] section).
enum Spirit {
    static let vectorRes = 1016        // VECTOR_RES_X / VECTOR_RES_Y
    static let offsetUm = 50_000       // OFFSET, x0.001 mm, added to absolute X positions
    static let complementBytes = 8     // COMP_BYTE: raster rows padded to a multiple of 8 bytes
}

/// Nominal resolution (as shown) → machine resolution (dots per inch on the bed), from [Resolution].
let resolutions: [Int: (x: Int, y: Int)] = [
    1500: (1524, 1524), 1000: (1016, 1016), 760: (762, 762), 600: (762, 609), 500: (508, 508),
    380: (381, 381), 300: (381, 304), 250: (254, 254), 125: (127, 127),
]

/// One horizontal band of 1-bit raster: rows top to bottom, MSB first, 1 = burn.
struct RasterBand {
    var pen: Int        // 1…16
    var x: Int          // left edge, machine pixels, multiple of 8
    var y: Int          // top row, machine pixels from the top of the page
    var bytesPerRow: Int
    var rows: [[UInt8]]
    /// The pixels actually burned, left edge included, right edge excluded (the extent the
    /// driver reports, narrower than the padded rows).
    var inkX0 = 0, inkX1 = 0
}

/// One vector path, in machine pixels (top-left origin), with the pen (1…16) it is cut with.
struct VectorPath {
    var pen: Int
    var points: [(x: Int, y: Int)]
}

final class GCCJob {
    private(set) var data = Data()
    let s: SpiritSettings
    let name: String
    let xdpi: Int, ydpi: Int        // 0x40e0, 0x40e4
    let sxdpi: Int, sydpi: Int      // scaled (0x40e8, 0x40ec): the resolution the page is drawn at
    let pageW: Int, pageH: Int      // 0x40d4, 0x40d8
    let offsetPx: Int               // 0x4348
    /// Head position the relative commands start from (0x45e8, 0x45ec), machine pixels.
    private var last = (x: 0, y: 0)
    /// The point "back to origin" returns to (the head position the job started from).
    private var ref = (x: 0, y: 0)
    private var started = false     // 0x460c == 0 once the first output is positioned
    private var airState = 0        // 0x4618
    private var hpglPen = 0         // 0x45a4 in HP-GL
    private var rasterPen = 0       // 0x45a4 + 1 for raster bands
    private var bbox = (x0: 0, y0: 0, x1: 0, y1: 0)

    init(settings: SpiritSettings, name: String, pageWidthUm: Int, pageHeightUm: Int) {
        s = settings
        self.name = name
        let r = resolutions[settings.dpi] ?? (508, 508)
        xdpi = r.x
        ydpi = r.y
        sxdpi = ((settings.scalingX + 1000) * xdpi + 500) / 1000
        sydpi = ((settings.scalingY + 1000) * ydpi + 500) / 1000
        pageW = pageWidthUm * sxdpi / 25400
        pageH = pageHeightUm * sydpi / 25400
        // The machine offset applies to absolute positions only (start modes 0 and 3).
        offsetPx = settings.position.start == 0 ? Spirit.offsetUm * sxdpi / 25400 : 0
    }

    private func put(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    private func esc(_ s: String) { put("\u{1b}" + s) }
    private func put(bytes: [UInt8]) { data.append(contentsOf: bytes) }

    /// Signed decimal the way the driver's "%+d" writes it.
    private func sgn(_ v: Int) -> String { v >= 0 ? "+\(v)" : "\(v)" }
    /// The *p C / *p D offsets: "-0" when zero.
    private func dashZero(_ v: Int) -> String { v == 0 ? "-0" : "\(v)" }
    private func b(_ x: Bool) -> Int { x ? 1 : 0 }

    /// *v<n>M: the position mode + 1 (+ 5 on the extended field), 0 with SmartCenter.
    private var positionCode: Int { s.position.rawValue + (s.extend ? 5 : 1) }

    // MARK: header (OutHeaderExp, 0x4212a0)

    func header(bounds: (x0: Int, y0: Int, x1: Int, y1: Int)) {
        bbox = bounds
        let pens = s.pens
        let n = pens.count
        esc("%-12345X")
        esc("E")
        esc("!r\(b(s.accArea))A")
        let title = String(name.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map(Character.init).prefix(20))
        esc("!m\(title.utf8.count)N\(title)")
        esc("!v\(n)R")
        put(pens.map { $0.ppi < 0x5f5 ? "1" : "0" }.joined())
        esc("!v\(n * 4)I")
        put(pens.map { String(format: "%04d", $0.ppi) }.joined())
        esc("!v\(n * 4)V")
        put(pens.map { String(format: "%04d", $0.speed) }.joined())
        esc("!v\(n * 4)P")
        put(pens.map { String(format: "%04d", $0.power * 10) }.joined())
        esc("!v\(n)D")
        put(bytes: pens.map { p -> UInt8 in
            switch (p.air, p.autofocus) {
            case (true, true): return 3
            case (true, false): return 2
            case (false, true): return 1
            case (false, false): return 0
            }
        })
        esc("!v\(n * 4)Z")
        put(pens.map { String(format: "%04d", $0.defocusOn ? 500 - $0.defocus : 500) }.joined())
        esc("!v\(n * 4)T")
        put(pens.map { String(format: "%d%03d", $0.powerTuning ? $0.tuningWidth : 0, $0.tuningPower) }.joined())
        esc("!h\(b(s.preciseCutting))A")
        esc("!h\(s.drillTime)T")
        esc("*t\(xdpi)R")
        esc("&u\(ydpi)D")
        esc("!r\(s.imageFactor)N")
        esc("!r\(s.advancedVector)E")
    }

    // MARK: positioning of the first output (0x422068 / 0x423274, by start mode)

    /// The first output places the head; returns the (relative or absolute) position written.
    private func firstPosition(x: Int, y: Int, focusPen: Pen, rasterPenNumber: Int?) {
        if s.dpi != 250 && s.dpi != 125 || rasterPenNumber == nil {
            esc("*p\(bbox.x1 - bbox.x0)A")
            esc("*p\(bbox.y1 - bbox.y0)B")
            esc("*p\(dashZero(bbox.x0 - x))C")
            esc("*p\(dashZero(bbox.y0 - y))D")
        }
        let focus = focusPen.autofocus || focusPen.defocusOn
        switch s.position.start {
        case 0:
            ref = (0, 0)
            esc("*p\(x + offsetPx)E")
            esc("*p\(y)F")
            esc("*v\(positionCode)M")
            esc("*p\(x + offsetPx)X")
            esc("*p\(y)Y")
        case 1:
            ref = (0, 0)
            esc("*p\(sgn(x))E")
            esc("*p\(sgn(y))F")
            esc("*v\(positionCode)M")
            esc("*p\(sgn(x))X")
            esc("*p\(sgn(y))Y")
        default:
            // Centred: positions relative to the centre of everything the job does, from where
            // the head stands.
            ref = (bbox.x0 + (bbox.x1 - bbox.x0) / 2, bbox.y0 + (bbox.y1 - bbox.y0) / 2)
            esc("*p\(sgn(x - ref.x))E")
            esc("*p\(sgn(y - ref.y))F")
            esc("*v\(positionCode)M")
            esc("*p\(sgn(x - ref.x))X")
            esc("*p\(sgn(y - ref.y))Y")
        }
        if focus {
            esc("*r1A")
            esc("*rC")
            if let pen = rasterPenNumber {
                esc(s.markMode == .colorFill ? "!m\(pen)A" : "!m1A")
            }
        }
        last = (x, y)
    }

    // MARK: raster (OutputExp 0x422068, rows 0x4134c0, band end 0x422f84)

    func raster(_ band: RasterBand) {
        guard !band.rows.isEmpty else { return }
        let pen = s.pens[band.pen - 1]
        // Bottom up: the band is engraved from its last row to its first.
        let rows = s.bottomUp ? band.rows.reversed() : band.rows
        let anchorY = s.bottomUp ? band.y + band.rows.count - 1 : band.y
        esc("%1A")
        if !started {
            firstPosition(x: band.x, y: anchorY, focusPen: pen, rasterPenNumber: band.pen)
        } else {
            esc("*p\(sgn(band.x - last.x))X")
            esc("*p\(sgn(anchorY - last.y))Y")
            // A new colour whose pen focuses: the head refocuses for it.
            if s.markMode == .colorFill && band.pen != rasterPen && (pen.autofocus || pen.defocusOn) {
                esc("*r1A")
                esc("*rC")
                esc("!m\(band.pen)A")
            }
        }
        esc("*t1Y")
        esc("!r\(b(s.bottomUp))B")
        esc("!r\(s.markMode == .colorFill ? 2 : 1)M")
        esc("!r\(b(s.oneDirection))V")
        esc("!r\(pen.speed)I")
        esc("!r\(pen.speed)K")
        esc("!r\(pen.power * 10)P")
        esc("*t\(xdpi)R")
        esc("&u\(ydpi)D")
        if !started {
            esc("!m\(b(s.immediate))S")
            esc("!s\(b(s.lowSpeed))S")
        }
        let air = pen.air ? 1 : 0
        if air != airState {
            airState = air
            esc("!r\(air * 2)D")
        }
        esc("*r\(band.rows.count)T")
        esc("*r\(band.bytesPerRow * 8)S")
        esc("*b1M")
        esc("*r1A")
        for row in rows {
            let packed = GCCJob.compress(row)
            esc("*b\(packed.count)W")
            put(bytes: packed)
        }
        esc("*rC")
        started = true
        rasterPen = band.pen
        last = (band.x, s.bottomUp ? band.y : band.y + band.rows.count - 1)
    }

    /// Row compression (0x413334). A byte followed by the same byte starts a run of up to 128:
    /// (count, byte). Otherwise a literal block (0x00, 0x03, length, bytes) runs until a byte
    /// equals the one before it, that first byte of the next run included. A last lone byte is
    /// a run of 1; the row ends with (0x00, 0x00). Byte-identical to the official driver on all
    /// 550 rows of the reference job it ships.
    static func compress(_ row: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(row.count / 4 + 8)
        let n = row.count
        var i = 0
        while i < n {
            if i + 1 < n && row[i + 1] == row[i] {
                var run = 1
                while i + run < n && row[i + run] == row[i] && run < 128 { run += 1 }
                out += [UInt8(run), row[i]]
                i += run
            } else if i + 1 == n {
                out += [1, row[i]]
                i += 1
            } else {
                var j = i + 1
                while j < n && row[j] != row[j - 1] && j - i < 127 { j += 1 }
                out += [0, 3, UInt8(j - i)]
                out += row[i..<j]
                i = j
            }
        }
        out += [0, 0]
        return out
    }

    // MARK: vectors (0x421c00, 0x423274, 0x4231bc)

    /// Machine pixels → vector units (0x4144dc): bottom-left origin (VECTOR_COORD = 1).
    private func vec(_ p: (x: Int, y: Int)) -> (x: Int, y: Int) {
        var rx = Spirit.vectorRes, ry = Spirit.vectorRes
        if s.dpi > 1000 { rx *= 3; ry *= 3 }
        let y = -p.y + pageH
        return ((rx * 1000 / xdpi) * p.x / 1000, (ry * 1000 / ydpi) * y / 1000)
    }

    func vectors(_ paths: [VectorPath]) {
        guard !paths.isEmpty else { return }
        endRaster()
        var first = true
        for path in paths {
            guard let start = path.points.first else { continue }
            let pen = s.pens[path.pen - 1]
            for _ in 0..<max(1, pen.repeatCount) {
                var a = start
                if !started {
                    vectorHeader(at: a, pen: pen)
                }
                if first {
                    esc("%1B;")
                    put("PR;")
                    first = false
                }
                moveTo(a)
                if hpglPen != path.pen {
                    hpglPen = path.pen
                    put(s.cuttingFirst ? "SP\(path.pen);PH;" : "SP\(path.pen);")
                }
                if path.points.count == 1 {
                    if s.drillCheck { put("PH;") }      // a point: drilled
                    continue
                }
                for b in path.points.dropFirst() {
                    let va = vec(a), vb = vec(b)
                    put("PD\(vb.x - va.x),\(vb.y - va.y);")
                    a = b
                    last = b
                }
            }
        }
        put("PU;")
        put("ZS0;RS0;")
    }

    private func moveTo(_ p: (x: Int, y: Int)) {
        if p.x != last.x || p.y != last.y {
            let va = vec(p), vl = vec(last)
            put("PU\(va.x - vl.x),\(va.y - vl.y);")
            last = p
        }
    }

    /// The positioning block a job without raster starts its vectors with (0x423274, first call).
    private func vectorHeader(at p: (x: Int, y: Int), pen: Pen) {
        esc("%1A")
        esc("!r\(pen.speed)I")
        esc("!r\(pen.speed)K")
        esc("!r\(pen.power * 10)P")
        esc("*t\(xdpi)R")
        esc("&u\(ydpi)D")
        firstPosition(x: p.x, y: p.y, focusPen: s.pens[0], rasterPenNumber: nil)
        esc("!m\(b(s.immediate))S")
        esc("!s\(b(s.lowSpeed))S")
        esc("*r1A")
        esc("*rC")
        started = true
    }

    // MARK: end (0x421c58), by the position mode's END

    /// End of the raster (0x421c00): the air assist the raster turned on goes off. The driver
    /// calls it after the raster of every page, vectors or not.
    private func endRaster() {
        if airState != 0 {
            airState = 0
            esc("!r0D")
            esc("*r1A")
            esc("*rC")
        }
    }

    func end() {
        endRaster()
        esc("%1A")
        switch s.position.end {
        case 3:     // to the top right
            let x = (pageW - sxdpi * 5000 / 25400) - sxdpi / 2 - last.x + offsetPx
            let y = sydpi * 5000 / 25400 - last.y
            esc("*p\(sgn(x))X")
            esc("*p\(sgn(y))Y")
        case 5:     // back where the job started
            esc("*p\(sgn(ref.x - last.x))X")
            esc("*p\(sgn(ref.y - last.y))Y")
        default:    // stay
            esc("E")
            esc("%-12345X")
            return
        }
        esc("*r1A")
        esc("*rC")
        esc("E")
        esc("%-12345X")
    }
}
