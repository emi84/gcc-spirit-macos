// Finds the cut lines in a PDF page: stroked paths no wider than the hairline width whose
// stroke colour is a pen's colour with Vector on, and text drawn as an outline in the same way
// (CorelDRAW prints an outlined text as real text, in render mode 1, not as paths). Like the
// official driver, everything else (fills, thick lines, filled text, images) is engraved as raster.

import CoreGraphics
import Foundation

/// A stroked path found on the page, in PDF points (bottom-left origin), already flattened.
struct PageStroke {
    var pen: Int
    var points: [CGPoint]
    var closed: Bool
    var width: CGFloat = 0      // points, as drawn on the page
    /// The stroke as the PDF drew it, to paint it out of the raster exactly: the line width in its
    /// user space, that space (a stretched text has a stretched stroke), and the miter limit.
    var lineWidth: CGFloat = 0
    var space = CGAffineTransform.identity
    var miterLimit: CGFloat = 10
}

private struct GState {
    var ctm = CGAffineTransform.identity
    var lineWidth: CGFloat = 1
    var miterLimit: CGFloat = 10
    var stroke: (r: Int, g: Int, b: Int) = (0, 0, 0)
    /// Components of the stroke colour space (DeviceGray 1, RGB 3, CMYK 4; 0: a pattern or a
    /// space whose colours can't be read as RGB, which no pen matches).
    var strokeComponents = 1
    // Text state.
    var font: PDFFont?
    var fontSize: CGFloat = 0
    var charSpace: CGFloat = 0
    var wordSpace: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var leading: CGFloat = 0
    var rise: CGFloat = 0
    var renderMode = 0
}

/// A font of the page, as far as cutting needs it.
private final class PDFFont {
    let name: String
    var outlines: TrueTypeFont?     // nil: not TrueType (CFF, Type 3…), its text can't be cut
    var twoByte = false             // Type0: two-byte codes that are glyph ids
    var cidToGid: [UInt8]?
    var firstChar = 0
    var widths: [CGFloat] = []      // ems, by code from firstChar
    init(name: String) { self.name = name }

    func glyph(_ code: Int) -> Int {
        guard twoByte else { return outlines?.glyph(forCode: code) ?? 0 }
        if let map = cidToGid {
            return 2 * code + 1 < map.count ? Int(map[2 * code]) << 8 | Int(map[2 * code + 1]) : 0
        }
        return code
    }

    func advance(code: Int, glyph: Int) -> CGFloat {
        let i = code - firstChar
        if !twoByte, i >= 0, i < widths.count { return widths[i] }
        return outlines?.advance(glyph) ?? 0
    }
}

private func streamBytes(_ stream: CGPDFStreamRef) -> [UInt8]? {
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
    return [UInt8](data as Data)
}

private func loadFont(_ dict: CGPDFDictionaryRef) -> PDFFont {
    func name(_ d: CGPDFDictionaryRef, _ key: String) -> String {
        var v: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(d, key, &v) && v != nil ? String(cString: v!) : ""
    }
    let font = PDFFont(name: name(dict, "BaseFont"))
    var holder = dict
    if name(dict, "Subtype") == "Type0" {
        font.twoByte = true
        var descendants: CGPDFArrayRef?, first: CGPDFDictionaryRef?
        if CGPDFDictionaryGetArray(dict, "DescendantFonts", &descendants), let descendants,
           CGPDFArrayGetDictionary(descendants, 0, &first), let first {
            holder = first
            var map: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(first, "CIDToGIDMap", &map), let map { font.cidToGid = streamBytes(map) }
        }
    }
    var descriptor: CGPDFDictionaryRef?, file: CGPDFStreamRef?
    if CGPDFDictionaryGetDictionary(holder, "FontDescriptor", &descriptor), let descriptor,
       CGPDFDictionaryGetStream(descriptor, "FontFile2", &file), let file, let bytes = streamBytes(file) {
        font.outlines = TrueTypeFont(data: bytes)
    }
    var first: CGPDFInteger = 0, widths: CGPDFArrayRef?
    _ = CGPDFDictionaryGetInteger(dict, "FirstChar", &first)
    font.firstChar = first
    if CGPDFDictionaryGetArray(dict, "Widths", &widths), let widths {
        for k in 0..<CGPDFArrayGetCount(widths) {
            var w: CGPDFReal = 0
            _ = CGPDFArrayGetNumber(widths, k, &w)
            font.widths.append(w / 1000)
        }
    }
    return font
}

private final class Extractor {
    var states = [GState()]
    var state: GState {
        get { states[states.count - 1] }
        set { states[states.count - 1] = newValue }
    }
    /// The path being built, in device (page) space: subpaths of points.
    var subpaths: [[CGPoint]] = []
    var closedFlags: [Bool] = []
    var current = CGPoint.zero
    var found: [PageStroke] = []
    /// Every stroked path seen, for `gccspirit --analyse`: width (mm), colour, pen, decision.
    var report: [String] = []
    var fills = 0
    var filledText = 0
    var fonts: [Int: PDFFont] = [:]
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    let pens: [Pen]
    let hairline: CGFloat           // points
    let flatness: CGFloat           // points
    var depth = 0

    init(pens: [Pen], hairline: CGFloat, flatness: CGFloat) {
        self.pens = pens
        self.hairline = hairline
        self.flatness = flatness
    }

    func toPage(_ p: CGPoint) -> CGPoint { p.applying(state.ctm) }

    func moveTo(_ p: CGPoint) {
        subpaths.append([toPage(p)])
        closedFlags.append(false)
        current = p
    }

    func lineTo(_ p: CGPoint) {
        if subpaths.isEmpty { moveTo(current) }
        subpaths[subpaths.count - 1].append(toPage(p))
        current = p
    }

    func curveTo(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) {
        if subpaths.isEmpty { moveTo(current) }
        let p0 = current
        let a = toPage(p0), b = toPage(c1), c = toPage(c2), d = toPage(p)
        // As many segments as the curve's bend needs to stay within `flatness` of it (Wang's
        // formula): a segment per machine step would make the head jerk along the curve.
        let bend = max(hypot(a.x - 2 * b.x + c.x, a.y - 2 * b.y + c.y), hypot(b.x - 2 * c.x + d.x, b.y - 2 * c.y + d.y))
        let n = max(2, min(500, Int(sqrt(0.75 * bend / flatness).rounded(.up))))
        for k in 1...n {
            let t = CGFloat(k) / CGFloat(n), u = 1 - t
            let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
            let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
            subpaths[subpaths.count - 1].append(CGPoint(x: x, y: y))
        }
        current = p
    }

    func closePath() {
        guard var last = subpaths.last, let first = last.first else { return }
        if last.last != first { last.append(first) }
        subpaths[subpaths.count - 1] = last
        closedFlags[closedFlags.count - 1] = true
    }

    func nextLine(_ x: CGFloat, _ y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    func moveText(by x: CGFloat) {
        textMatrix = CGAffineTransform(translationX: x * state.horizontalScale, y: 0).concatenating(textMatrix)
    }

    /// Advances over `bytes`, and adds the outline of each glyph to the path when the render mode
    /// strokes. The caller ends the path.
    func show(_ bytes: [UInt8]) {
        let t = state
        guard let font = t.font else { return }
        let outlined = [1, 2, 5, 6].contains(t.renderMode)
        var i = 0
        while i < bytes.count {
            var code = Int(bytes[i])
            i += 1
            if font.twoByte {
                guard i < bytes.count else { break }
                code = code << 8 | Int(bytes[i])
                i += 1
            }
            let gid = font.glyph(code)
            if outlined, let outlines = font.outlines {
                let m = CGAffineTransform(a: t.fontSize * t.horizontalScale, b: 0, c: 0, d: t.fontSize, tx: 0, ty: t.rise)
                    .concatenating(textMatrix)
                for segment in outlines.outline(gid) {
                    switch segment {
                    case .move(let p): moveTo(p.applying(m))
                    case .line(let p): lineTo(p.applying(m))
                    case .close: closePath()
                    case .quad(let k, let p):
                        // The quadratic as a cubic, from the current point.
                        let c = k.applying(m), e = p.applying(m), a = current
                        curveTo(CGPoint(x: a.x + (c.x - a.x) * 2 / 3, y: a.y + (c.y - a.y) * 2 / 3),
                                CGPoint(x: e.x + (c.x - e.x) * 2 / 3, y: e.y + (c.y - e.y) * 2 / 3), e)
                    }
                }
            }
            let word = !font.twoByte && code == 32 ? t.wordSpace : 0
            moveText(by: font.advance(code: code, glyph: gid) * t.fontSize + t.charSpace + word)
        }
    }

    /// After a text operator: the text's outline is judged like any stroke.
    func endText() {
        let t = state
        guard t.font != nil, t.renderMode != 3, t.renderMode != 7 else { return }
        guard [1, 2, 5, 6].contains(t.renderMode) else {
            filledText += 1
            return
        }
        guard t.font?.outlines != nil else {
            report.append("texte en contour, police \(t.font?.name ?? "") illisible → gravé (convertissez-le en courbes)")
            return
        }
        endPath(stroked: true, what: "texte")
    }

    func endPath(stroked: Bool, what: String = "trait") {
        defer {
            subpaths.removeAll()
            closedFlags.removeAll()
        }
        guard stroked else { return }
        // The width as drawn on the page: the line width scaled by the CTM.
        let t = state.ctm
        // The larger of the two axes: text stretched by an object's scale has a different one each.
        let scale = max(hypot(t.a, t.b), hypot(t.c, t.d))
        let width = state.lineWidth * scale
        let c = state.stroke
        let mm = String(format: "%.4f mm", width / 72 * 25.4)
        let colour = c.r < 0 ? "couleur illisible" : "RVB \(c.r),\(c.g),\(c.b)"
        // 2 % of margin: CorelDRAW writes a 0.1 mm line as 0.28346 pt × a scale, which lands a
        // hair above 0.1 mm once multiplied back, and was engraved for it.
        // Exactly 1 pt: a line thinner than macOS draws (CorelDRAW's 0.0013 mm outline) reaches the
        // printer widened to 1 pt, so a stroke of exactly 1 pt is taken for a hairline too.
        let widenedHairline = abs(width - 1) < 0.003
        guard width <= hairline * 1.02 || widenedHairline else {
            report.append("\(what) \(mm), \(colour) : plus épais que \(String(format: "%.3f", hairline / 72 * 25.4)) mm → gravé")
            return
        }
        // The pen of the nearest colour, as the driver maps colours to its 16 pens (a colour
        // nearer to white than to any pen is not a pen's).
        guard c.r >= 0, let index = nearestPen(pens, c.r, c.g, c.b) else {
            report.append("\(what) \(mm), \(colour) : aucune couleur de stylo → gravé")
            return
        }
        guard pens[index].vector else {
            report.append("\(what) \(mm), \(colour) : stylo \(index + 1), « Vecteur » décoché → gravé")
            return
        }
        report.append("\(what) \(mm), \(colour) : stylo \(index + 1) → DÉCOUPE")
        // A lone point is a moveto with nothing drawn from it (CorelDRAW leaves one after a rectangle).
        for (pts, closed) in zip(subpaths, closedFlags) where pts.count > 1 {
            found.append(PageStroke(pen: index + 1, points: pts, closed: closed, width: width, lineWidth: state.lineWidth,
                                    space: CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0),
                                    miterLimit: state.miterLimit))
        }
    }

    func setStroke(_ comps: [CGFloat]) {
        let v = comps.map { min(max($0, 0), 1) }
        var rgb: (CGFloat, CGFloat, CGFloat)
        switch v.count {
        case 1: rgb = (v[0], v[0], v[0])
        case 3: rgb = (v[0], v[1], v[2])
        case 4: rgb = ((1 - v[0]) * (1 - v[3]), (1 - v[1]) * (1 - v[3]), (1 - v[2]) * (1 - v[3]))
        default: return
        }
        state.stroke = (Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()), Int((rgb.2 * 255).rounded()))
    }
}

// MARK: operator callbacks

private func ex(_ info: UnsafeMutableRawPointer?) -> Extractor {
    Unmanaged<Extractor>.fromOpaque(info!).takeUnretainedValue()
}

private func pop(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
    var v = [CGFloat](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var x: CGPDFReal = 0
        guard CGPDFScannerPopNumber(s, &x) else { return nil }
        v[i] = x
    }
    return v
}

private func stringBytes(_ s: CGPDFStringRef) -> [UInt8] {
    guard let p = CGPDFStringGetBytePtr(s) else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)))
}

private func popBytes(_ s: CGPDFScannerRef) -> [UInt8]? {
    var string: CGPDFStringRef?
    guard CGPDFScannerPopString(s, &string), let string else { return nil }
    return stringBytes(string)
}

/// Components of the colour space named `name` (a device space, or one from the resources).
private func components(_ s: CGPDFScannerRef, _ name: String) -> Int {
    switch name {
    case "DeviceGray", "G", "CalGray": return 1
    case "DeviceRGB", "RGB", "CalRGB": return 3
    case "DeviceCMYK", "CMYK": return 4
    default: break
    }
    let content = CGPDFScannerGetContentStream(s)
    guard let obj = CGPDFContentStreamGetResource(content, "ColorSpace", name) else { return 0 }
    var array: CGPDFArrayRef?
    guard CGPDFObjectGetValue(obj, .array, &array), let array else { return 0 }
    var family: UnsafePointer<CChar>?
    guard CGPDFArrayGetName(array, 0, &family), let family else { return 0 }
    switch String(cString: family) {
    case "CalGray": return 1
    case "CalRGB": return 3
    case "ICCBased":
        var stream: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return 0 }
        var n: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(dict, "N", &n) && [1, 3, 4].contains(n) ? n : 0
    default: return 0
    }
}

private func makeTable() -> CGPDFOperatorTableRef {
    let t = CGPDFOperatorTableCreate()!
    CGPDFOperatorTableSetCallback(t, "q") { _, i in let e = ex(i); e.states.append(e.state) }
    CGPDFOperatorTableSetCallback(t, "Q") { _, i in let e = ex(i); if e.states.count > 1 { e.states.removeLast() } }
    CGPDFOperatorTableSetCallback(t, "cm") { s, i in
        guard let v = pop(s, 6) else { return }
        let e = ex(i)
        e.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(e.state.ctm)
    }
    CGPDFOperatorTableSetCallback(t, "w") { s, i in if let v = pop(s, 1) { ex(i).state.lineWidth = v[0] } }
    CGPDFOperatorTableSetCallback(t, "M") { s, i in if let v = pop(s, 1) { ex(i).state.miterLimit = v[0] } }
    CGPDFOperatorTableSetCallback(t, "m") { s, i in if let v = pop(s, 2) { ex(i).moveTo(CGPoint(x: v[0], y: v[1])) } }
    CGPDFOperatorTableSetCallback(t, "l") { s, i in if let v = pop(s, 2) { ex(i).lineTo(CGPoint(x: v[0], y: v[1])) } }
    CGPDFOperatorTableSetCallback(t, "c") { s, i in
        guard let v = pop(s, 6) else { return }
        ex(i).curveTo(CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]), CGPoint(x: v[4], y: v[5]))
    }
    CGPDFOperatorTableSetCallback(t, "v") { s, i in
        guard let v = pop(s, 4) else { return }
        let e = ex(i)
        e.curveTo(e.current, CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]))
    }
    CGPDFOperatorTableSetCallback(t, "y") { s, i in
        guard let v = pop(s, 4) else { return }
        let p = CGPoint(x: v[2], y: v[3])
        ex(i).curveTo(CGPoint(x: v[0], y: v[1]), p, p)
    }
    CGPDFOperatorTableSetCallback(t, "h") { _, i in ex(i).closePath() }
    CGPDFOperatorTableSetCallback(t, "re") { s, i in
        guard let v = pop(s, 4) else { return }
        let e = ex(i)
        e.moveTo(CGPoint(x: v[0], y: v[1]))
        e.lineTo(CGPoint(x: v[0] + v[2], y: v[1]))
        e.lineTo(CGPoint(x: v[0] + v[2], y: v[1] + v[3]))
        e.lineTo(CGPoint(x: v[0], y: v[1] + v[3]))
        e.closePath()
    }
    CGPDFOperatorTableSetCallback(t, "S") { _, i in ex(i).endPath(stroked: true) }
    CGPDFOperatorTableSetCallback(t, "s") { _, i in let e = ex(i); e.closePath(); e.endPath(stroked: true) }
    for op in ["B", "B*"] {
        CGPDFOperatorTableSetCallback(t, op) { _, i in ex(i).endPath(stroked: true) }
    }
    for op in ["b", "b*"] {
        CGPDFOperatorTableSetCallback(t, op) { _, i in let e = ex(i); e.closePath(); e.endPath(stroked: true) }
    }
    for op in ["f", "F", "f*"] {
        CGPDFOperatorTableSetCallback(t, op) { _, i in let e = ex(i); e.fills += 1; e.endPath(stroked: false) }
    }
    CGPDFOperatorTableSetCallback(t, "n") { _, i in ex(i).endPath(stroked: false) }
    CGPDFOperatorTableSetCallback(t, "BT") { _, i in
        let e = ex(i); e.textMatrix = .identity; e.lineMatrix = .identity
    }
    CGPDFOperatorTableSetCallback(t, "Tf") { s, i in
        var size: CGPDFReal = 0
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopNumber(s, &size), CGPDFScannerPopName(s, &name), let name else { return }
        let e = ex(i)
        e.state.fontSize = size
        e.state.font = nil
        let content = CGPDFScannerGetContentStream(s)
        var dict: CGPDFDictionaryRef?
        guard let obj = CGPDFContentStreamGetResource(content, "Font", name),
              CGPDFObjectGetValue(obj, .dictionary, &dict), let dict else { return }
        let key = unsafeBitCast(dict, to: Int.self)
        if e.fonts[key] == nil { e.fonts[key] = loadFont(dict) }
        e.state.font = e.fonts[key]
    }
    CGPDFOperatorTableSetCallback(t, "Tr") { s, i in if let v = pop(s, 1) { ex(i).state.renderMode = Int(v[0]) } }
    CGPDFOperatorTableSetCallback(t, "Tc") { s, i in if let v = pop(s, 1) { ex(i).state.charSpace = v[0] } }
    CGPDFOperatorTableSetCallback(t, "Tw") { s, i in if let v = pop(s, 1) { ex(i).state.wordSpace = v[0] } }
    CGPDFOperatorTableSetCallback(t, "Tz") { s, i in if let v = pop(s, 1) { ex(i).state.horizontalScale = v[0] / 100 } }
    CGPDFOperatorTableSetCallback(t, "TL") { s, i in if let v = pop(s, 1) { ex(i).state.leading = v[0] } }
    CGPDFOperatorTableSetCallback(t, "Ts") { s, i in if let v = pop(s, 1) { ex(i).state.rise = v[0] } }
    CGPDFOperatorTableSetCallback(t, "Tm") { s, i in
        guard let v = pop(s, 6) else { return }
        let e = ex(i)
        e.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        e.textMatrix = e.lineMatrix
    }
    CGPDFOperatorTableSetCallback(t, "Td") { s, i in if let v = pop(s, 2) { ex(i).nextLine(v[0], v[1]) } }
    CGPDFOperatorTableSetCallback(t, "TD") { s, i in
        guard let v = pop(s, 2) else { return }
        let e = ex(i); e.state.leading = -v[1]; e.nextLine(v[0], v[1])
    }
    CGPDFOperatorTableSetCallback(t, "T*") { _, i in let e = ex(i); e.nextLine(0, -e.state.leading) }
    CGPDFOperatorTableSetCallback(t, "Tj") { s, i in
        guard let text = popBytes(s) else { return }
        let e = ex(i); e.show(text); e.endText()
    }
    CGPDFOperatorTableSetCallback(t, "'") { s, i in
        guard let text = popBytes(s) else { return }
        let e = ex(i); e.nextLine(0, -e.state.leading); e.show(text); e.endText()
    }
    CGPDFOperatorTableSetCallback(t, "\"") { s, i in
        guard let text = popBytes(s), let v = pop(s, 2) else { return }
        let e = ex(i)
        e.state.wordSpace = v[0]; e.state.charSpace = v[1]
        e.nextLine(0, -e.state.leading); e.show(text); e.endText()
    }
    CGPDFOperatorTableSetCallback(t, "TJ") { s, i in
        var array: CGPDFArrayRef?
        guard CGPDFScannerPopArray(s, &array), let array else { return }
        let e = ex(i)
        for k in 0..<CGPDFArrayGetCount(array) {
            var string: CGPDFStringRef?
            var number: CGPDFReal = 0
            if CGPDFArrayGetString(array, k, &string), let string {
                e.show(stringBytes(string))
            } else if CGPDFArrayGetNumber(array, k, &number) {
                e.moveText(by: -number / 1000 * e.state.fontSize)
            }
        }
        e.endText()
    }
    CGPDFOperatorTableSetCallback(t, "BI") { _, i in ex(i).report.append("image bitmap (en ligne) → gravé") }
    CGPDFOperatorTableSetCallback(t, "G") { s, i in
        let e = ex(i); e.state.strokeComponents = 1; if let v = pop(s, 1) { e.setStroke(v) }
    }
    CGPDFOperatorTableSetCallback(t, "RG") { s, i in
        let e = ex(i); e.state.strokeComponents = 3; if let v = pop(s, 3) { e.setStroke(v) }
    }
    CGPDFOperatorTableSetCallback(t, "K") { s, i in
        let e = ex(i); e.state.strokeComponents = 4; if let v = pop(s, 4) { e.setStroke(v) }
    }
    CGPDFOperatorTableSetCallback(t, "CS") { s, i in
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(s, &name), let name else { return }
        let e = ex(i)
        e.state.strokeComponents = components(s, String(cString: name))
        // A new colour space starts at its initial colour: black, or no pen at all.
        e.state.stroke = e.state.strokeComponents > 0 ? (0, 0, 0) : (-1, -1, -1)
    }
    for op in ["SC", "SCN"] {
        CGPDFOperatorTableSetCallback(t, op) { s, i in
            let e = ex(i)
            let n = e.state.strokeComponents
            if n > 0, let v = pop(s, n) { e.setStroke(v) } else { e.state.stroke = (-1, -1, -1) }
        }
    }
    CGPDFOperatorTableSetCallback(t, "Do") { s, i in
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(s, &name), let name else { return }
        let e = ex(i)
        guard e.depth < 8 else { return }
        let content = CGPDFScannerGetContentStream(s)
        guard let obj = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
        if String(cString: subtype) == "Image" {
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            _ = CGPDFDictionaryGetInteger(dict, "Width", &w)
            _ = CGPDFDictionaryGetInteger(dict, "Height", &h)
            e.report.append("image bitmap \(w) x \(h) pixels → gravé")
            return
        }
        guard String(cString: subtype) == "Form" else { return }
        // A form XObject: its content, through its own matrix, with its own resources.
        e.states.append(e.state)
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
            var m = [CGFloat](repeating: 0, count: 6)
            for k in 0..<6 {
                var x: CGPDFReal = 0
                _ = CGPDFArrayGetNumber(matrix, k, &x)
                m[k] = x
            }
            e.state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(e.state.ctm)
        }
        let sub = CGPDFContentStreamCreateWithStream(stream, dict, content)
        let scanner = CGPDFScannerCreate(sub, makeTable(), i)
        e.depth += 1
        CGPDFScannerScan(scanner)
        e.depth -= 1
        e.states.removeLast()
    }
    return t
}

/// The index of the pen whose colour is nearest to (r, g, b), or nil when white is nearer.
func nearestPen(_ pens: [Pen], _ r: Int, _ g: Int, _ b: Int) -> Int? {
    var best: Int?, bestD = (255 - r) * (255 - r) + (255 - g) * (255 - g) + (255 - b) * (255 - b)
    for (i, p) in pens.enumerated() {
        let d = (p.r - r) * (p.r - r) + (p.g - g) * (p.g - g) + (p.b - b) * (p.b - b)
        if d < bestD { bestD = d; best = i }
    }
    return best
}

/// The cut lines of `page`: hairline strokes (≤ `hairline` points wide) whose colour is nearest to
/// a pen with Vector on; and, for `--analyse`, what was decided for every stroke.
func extractStrokes(page: CGPDFPage, geometry: PageGeometry, pens: [Pen], hairline: CGFloat) -> (strokes: [PageStroke], report: [String]) {
    let e = Extractor(pens: pens, hairline: hairline, flatness: 0.03)
    e.state.ctm = geometry.transform
    let info = Unmanaged.passUnretained(e).toOpaque()
    let content = CGPDFContentStreamCreateWithPage(page)
    let scanner = CGPDFScannerCreate(content, makeTable(), info)
    CGPDFScannerScan(scanner)
    if e.fills > 0 { e.report.append("\(e.fills) remplissage(s) → gravé(s)") }
    if e.filledText > 0 { e.report.append("\(e.filledText) texte(s) rempli(s) → gravé(s)") }
    return (e.found, e.report)
}
