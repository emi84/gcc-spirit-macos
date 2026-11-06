// Renders a PDF page to the 1-bit rasters the laser engraves (everything except the cut lines),
// in machine pixels, split into bands around the parts that hold something.
//
// Black & White: the page in grey, halftoned, engraved with pen 1.
// Manual Color Fill: each pixel goes to the pen of the nearest of the 16 colours (white: nothing),
// and each pen's pixels are engraved with that pen's settings, pen 1 first.

import CoreGraphics
import Foundation

struct RasterOptions {
    var xdpi: Int
    var ydpi: Int
    var settings: SpiritSettings
}

/// N×N threshold matrix (values 0…N²-1) for ordered dithering: Dot (clustered from the centre),
/// Bayer (dispersed) or Corner (clustered from a corner), like the driver's [DITHERING] choices.
func ditherMatrix(size n: Int, pattern: Int) -> [[Int]] {
    if pattern == 1 {
        var m = [[0]]
        while m.count * 2 <= n {
            let k = m.count
            var next = [[Int]](repeating: [Int](repeating: 0, count: k * 2), count: k * 2)
            for y in 0..<k {
                for x in 0..<k {
                    let v = m[y][x] * 4
                    next[y][x] = v
                    next[y][x + k] = v + 2
                    next[y + k][x] = v + 3
                    next[y + k][x + k] = v + 1
                }
            }
            m = next
        }
        return m
    }
    // Clustered: cells ranked by distance from the centre (Dot) or from the top-left corner.
    let c = pattern == 0 ? Double(n - 1) / 2 : 0
    var cells: [(Double, Int, Int)] = []
    for y in 0..<n {
        for x in 0..<n {
            let dx = Double(x) - c, dy = Double(y) - c
            cells.append((dx * dx + dy * dy + Double(y * n + x) * 1e-6, x, y))
        }
    }
    cells.sort { $0.0 < $1.0 }
    var m = [[Int]](repeating: [Int](repeating: 0, count: n), count: n)
    for (rank, cell) in cells.enumerated() { m[cell.2][cell.1] = rank }
    return m
}

/// Error diffusion kernels: (dx, dy, weight), divisor.
private let kernels: [([(Int, Int, Int)], Int)] = [
    ([(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)], 16),                               // Floyd
    ([(1, 0, 8), (2, 0, 4), (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
      (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1)], 42),                     // Stucki
    ([(1, 0, 7), (2, 0, 5), (-2, 1, 3), (-1, 1, 5), (0, 1, 7), (1, 1, 5), (2, 1, 3),
      (-2, 2, 1), (-1, 2, 3), (0, 2, 5), (1, 2, 3), (2, 2, 1)], 48),                     // Jarvis
]

/// Renders `page` and returns its raster bands (machine pixels, top-left origin), pen by pen.
/// `strokes` are the cut lines: they are painted out of the raster.
func renderBands(page: CGPDFPage, geometry: PageGeometry, strokes: [PageStroke], options o: RasterOptions) -> [RasterBand] {
    let s = o.settings
    let box = CGRect(origin: .zero, size: geometry.size)
    let width = Int((box.width / 72 * CGFloat(o.xdpi)).rounded(.up))
    let height = Int((box.height / 72 * CGFloat(o.ydpi)).rounded(.up))
    guard width > 0, height > 0 else { return [] }
    let colour = s.markMode == .colorFill
    let strip = max(1, min(height, 32_000_000 / max(width * 4, 1)))
    let space = CGColorSpaceCreateDeviceRGB()
    let toPage = geometry.transform
    let rowBytes = (width + 7) / 8

    // One bit plane per pen (Black & White: pen 1 only).
    let planes = colour ? PenTable.count : 1
    var bits = [[[UInt8]]](repeating: [], count: planes)
    var used = [Bool](repeating: false, count: planes)

    // Colour → pen: the nearest of the 16 pen colours, or white (nothing). Cached per colour.
    var nearest: [UInt32: Int] = [:]
    func penIndex(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if let v = nearest[key] { return v }
        let best = nearestPen(s.pens, r, g, b) ?? -1
        nearest[key] = best
        return best
    }

    // Halftoning (Black & White).
    let matrix = ditherMatrix(size: s.ditherMatrix, pattern: s.ditherPattern)
    let mn = matrix.count, levels = mn * mn
    let (kernel, divisor) = kernels[min(max(s.errorDiffusion, 0), 2)]
    var errRows = [[Int]](repeating: [Int](repeating: 0, count: width + 4), count: 3)

    var y0 = 0
    while y0 < height {
        let h = min(strip, height - y0)
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        // Page space (points, bottom-left) → this strip's pixels.
        ctx.translateBy(x: 0, y: CGFloat(h - (height - y0)))
        if s.mirror {
            ctx.translateBy(x: CGFloat(width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.scaleBy(x: CGFloat(o.xdpi) / 72, y: CGFloat(o.ydpi) / 72)
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.concatenate(toPage)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        // Cut lines are cut, not engraved: painted out, four machine pixels wider than drawn, so that no stray
        // pixel of them is left to be swept by the head.
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let pixel = 72 / CGFloat(min(o.xdpi, o.ydpi))
        ctx.setLineCap(.round)
        for st in strokes where st.points.count > 1 {
            // The stroke again, in its own space (a stretched text has a stretched line) with its
            // own miter limit, so that the long spikes at the sharp corners of a letter are covered
            // too; two pixels wider on each side. Rounded as well, for the line's ends.
            let space = st.space.a * st.space.d - st.space.b * st.space.c != 0 ? st.space : .identity
            let inverse = space.inverted()
            let unit = min(hypot(space.a, space.b), hypot(space.c, space.d))
            let points = st.points.map { $0.applying(inverse) }
            ctx.saveGState()
            ctx.concatenate(space)
            ctx.setLineWidth(st.lineWidth + 4 * pixel / max(unit, 1e-9))
            ctx.setMiterLimit(max(st.miterLimit, 10) * 1.5)
            for join in [CGLineJoin.miter, .round] {
                ctx.setLineJoin(join)
                ctx.beginPath()
                ctx.addLines(between: points)
                if st.closed { ctx.closePath() }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        for r in 0..<h {
            let y = y0 + r
            var rows = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: planes)
            let base = r * width * 4
            if colour {
                for x in 0..<width {
                    let p = base + x * 4
                    let i = penIndex(Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
                    guard i >= 0, s.pens[i].raster else { continue }
                    rows[i][x >> 3] |= 0x80 >> UInt8(x & 7)
                    used[i] = true
                }
            } else {
                errRows.removeFirst()
                errRows.append([Int](repeating: 0, count: width + 4))
                for x in 0..<width {
                    let p = base + x * 4
                    var grey = (Int(px[p]) * 299 + Int(px[p + 1]) * 587 + Int(px[p + 2]) * 114) / 1000
                    grey = min(max(grey + s.contrast * 255 / 100, 0), 255)   // -50 darker … +50 lighter
                    var dark = 255 - grey
                    if s.invert { dark = 255 - dark }
                    let burn: Bool
                    if s.halftone == 1 {
                        let v = dark + errRows[0][x + 2] / divisor
                        burn = v >= 128
                        let e = v - (burn ? 255 : 0)
                        for (dx, dy, w) in kernel where x + dx >= 0 && x + dx < width {
                            errRows[dy][x + dx + 2] += e * w
                        }
                    } else {
                        // Pure black stays solid; greys get the dot pattern.
                        burn = dark * levels > matrix[y % mn][x % mn] * 255 + 127
                    }
                    if burn {
                        rows[0][x >> 3] |= 0x80 >> UInt8(x & 7)
                        used[0] = true
                    }
                }
            }
            for i in 0..<planes { bits[i].append(rows[i]) }
        }
        y0 += h
    }
    // What is left of a cut line is not an engraving: a few pixels at the tip of a stroke's spikes
    // would still make the head sweep. A pen that cuts and has under 0.5 mm² to engrave engraves nothing.
    if colour {
        let crumbs = Double(o.xdpi * o.ydpi) * 0.5 / (25.4 * 25.4)
        for i in Set(strokes.map({ $0.pen - 1 })) where i >= 0 && i < planes && used[i] {
            let burned = bits[i].reduce(0) { $0 + $1.reduce(0) { $0 + $1.nonzeroBitCount } }
            if Double(burned) < crumbs { used[i] = false }
        }
    }
    var bands: [RasterBand] = []
    for i in 0..<planes where used[i] && s.pens[i].raster {
        bands += makeBands(pen: i + 1, bits: bits[i], rowBytes: rowBytes, keepWhite: s.noSkipWhite)
    }
    return bands
}

/// Splits a pen's raster into bands at long runs of blank rows, each band cropped to its columns
/// (left edge on a byte, width padded to COMP_BYTE bytes), like the official driver. With
/// "Désactiver le saut de blancs" the band keeps the full width and every row.
func makeBands(pen: Int, bits: [[UInt8]], rowBytes: Int, keepWhite: Bool, gap: Int = 64) -> [RasterBand] {
    let blank = bits.map { row in row.allSatisfy { $0 == 0 } }
    var bands: [RasterBand] = []
    var y = 0
    while y < bits.count {
        guard !blank[y] else { y += 1; continue }
        var end = y, empty = 0
        var k = y
        while k < bits.count {
            if blank[k] { empty += 1; if empty >= gap && !keepWhite { break } } else { empty = 0; end = k }
            k += 1
        }
        var lo = 0, hi = rowBytes - 1
        if !keepWhite {
            lo = rowBytes; hi = -1
            for r in y...end {
                if let f = bits[r].firstIndex(where: { $0 != 0 }) { lo = min(lo, f) }
                if let l = bits[r].lastIndex(where: { $0 != 0 }) { hi = max(hi, l) }
            }
        }
        let used = hi - lo + 1
        let n = (used + Spirit.complementBytes - 1) / Spirit.complementBytes * Spirit.complementBytes
        let rows = (y...end).map { r -> [UInt8] in
            var row = [UInt8](repeating: 0, count: n)
            let take = min(n, rowBytes - lo)
            row.replaceSubrange(0..<take, with: bits[r][lo..<lo + take])
            return row
        }
        // The burned extent, to the pixel.
        var inkL = Int.max, inkR = Int.min
        for r in y...end {
            if let f = bits[r].firstIndex(where: { $0 != 0 }) { inkL = min(inkL, f * 8 + bits[r][f].leadingZeroBitCount) }
            if let l = bits[r].lastIndex(where: { $0 != 0 }) { inkR = max(inkR, l * 8 + 8 - bits[r][l].trailingZeroBitCount) }
        }
        bands.append(RasterBand(pen: pen, x: lo * 8, y: y, bytesPerRow: n, rows: rows, inkX0: inkL, inkX1: inkR))
        y = end + 1
    }
    return bands
}
