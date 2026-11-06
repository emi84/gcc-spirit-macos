// gccspirit: PDF → GCC Spirit laser job.
//
// As a CUPS filter (6 or 7 arguments: job user title copies options [file]) it reads the PDF the
// Mac prints, writes the job to standard output and CUPS sends it to the laser. The settings come
// from the preset chosen in the print dialog, else from the active one (set in the GCC Spirit app).
// As a tool: gccspirit --pdf in.pdf --out job.prn [--preset file.spi] … (see --help).

import CoreGraphics
import Foundation

struct Options {
    var presetPath = SpiritFiles.active
    var powerLimit = 100        // percent of every pen's power (command line only)
    var hairlineMM: Double?     // command line; else the preset's
    var analyse = false

    mutating func set(_ key: String, _ value: String) {
        switch key.lowercased() {
        case "gccpreset":
            // The print dialog's choice: "Actif" (the app's settings) or a preset of the folder.
            if value != "Actif", let path = SpiritFiles.preset(keyword: value) { presetPath = path }
        case "power-limit": if let n = Int(value), (1...100).contains(n) { powerLimit = n }
        case "hairline-mm": if let x = Double(value), x > 0, x < 5 { hairlineMM = x }
        case "preset": presetPath = value
        default: break
        }
    }

    /// The PPD's defaults (`*DefaultGCCPowerLimit: 100`), as CUPS hands the filter only what changed.
    mutating func loadPPDDefaults(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("*Default") {
            let parts = line.dropFirst(8).split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { set(parts[0], parts[1]) }
        }
    }

    mutating func parseCUPS(_ s: String) {
        for tok in s.split(separator: " ") {
            let kv = tok.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { set(kv[0], kv[1]) }
        }
    }
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func loadSettings(_ path: String) -> SpiritSettings {
    if let f = IniFile(path: path) { return SpiritSettings(ini: f) }
    if let f = IniFile(path: SpiritFiles.defaults) { return SpiritSettings(ini: f) }
    return SpiritSettings()
}

/// Orders the cut lines as the preset's "Fonction Vecteur" says.
func orderPaths(_ paths: [VectorPath], _ f: VectorFunction) -> [VectorPath] {
    func box(_ p: VectorPath) -> (Int, Int, Int, Int) {
        let xs = p.points.map(\.x), ys = p.points.map(\.y)
        return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
    }
    switch f {
    case .insideOut:
        // A shape inside another is cut first, so the part does not move before it is done.
        return paths.enumerated().sorted { a, b in
            let (ba, bb) = (box(a.element), box(b.element))
            let aInB = ba.0 >= bb.0 && ba.1 >= bb.1 && ba.2 <= bb.2 && ba.3 <= bb.3
            let bInA = bb.0 >= ba.0 && bb.1 >= ba.1 && bb.2 <= ba.2 && bb.3 <= ba.3
            if aInB != bInA { return aInB }
            return a.offset < b.offset
        }.map(\.element)
    case .optimized:
        // Pen by pen, each path starting where the head is nearest.
        var out: [VectorPath] = []
        for pen in 1...PenTable.count {
            var left = paths.filter { $0.pen == pen }
            var at = (x: out.last?.points.last?.x ?? 0, y: out.last?.points.last?.y ?? 0)
            while !left.isEmpty {
                let k = left.indices.min { i, j in
                    let p = left[i].points[0], q = left[j].points[0]
                    return (p.x - at.x) * (p.x - at.x) + (p.y - at.y) * (p.y - at.y) < (q.x - at.x) * (q.x - at.x) + (q.y - at.y) * (q.y - at.y)
                }!
                let p = left.remove(at: k)
                out.append(p)
                at = p.points.last!
            }
        }
        return out
    default:
        return paths
    }
}

/// Converts every page of `pdf` into one job each and returns the bytes.
func convert(pdf: CGPDFDocument, title: String, o: Options) -> Data {
    var settings = loadSettings(o.presetPath)
    let hairline = o.hairlineMM ?? Double(settings.hairlineUm) / 1000
    for k in settings.pens.indices { settings.pens[k].power = settings.pens[k].power * o.powerLimit / 100 }
    if settings.markMode != .blackWhite && settings.markMode != .colorFill {
        log("WARNING: mode 3D / tampon non pris en charge : gravure en Noir & Blanc")
        settings.markMode = .blackWhite
    }
    var out = Data()
    for n in 1...max(1, pdf.numberOfPages) {
        guard let page = pdf.page(at: n) else { continue }
        // A page taller than the bed (CorelDRAW's 740 × 460 mm page, handed over on 460 × 740 mm
        // paper, turned a quarter clockwise) is turned back a quarter anticlockwise, to lie along
        // the bed like on Windows.
        let upright = PageGeometry(page: page)
        let fieldH = CGFloat(settings.fieldY) / 25400 * 72
        let tooTall = upright.size.height > fieldH + 1 && upright.size.width < upright.size.height
        let turn = (settings.rotation + (tooTall ? 270 : 0)) % 360
        let geometry = PageGeometry(page: page, extra: turn)
        let box = CGRect(origin: .zero, size: geometry.size)
        let job = GCCJob(settings: settings, name: title, pageWidthUm: Int(box.width * 25400 / 72), pageHeightUm: Int(box.height * 25400 / 72))
        log(String(format: "INFO: page %d : %.1f x %.1f mm (rotation de la page %d°, + %d°)", n, box.width / 72 * 25.4, box.height / 72 * 25.4, page.rotationAngle, turn))
        let (dx, dy) = (job.sxdpi, job.sydpi)       // the page is drawn at the scaled resolution

        let found = settings.vectorFunction == .allRaster
            ? (strokes: [], report: ["Fonction Vecteur « Trame seulement » : aucun trait découpé"])
            : extractStrokes(page: page, geometry: geometry, pens: settings.pens, hairline: CGFloat(hairline / 25.4 * 72))
        let strokes = found.strokes
        // In the CUPS log (debug level): what was decided for every stroke.
        found.report.forEach { log("DEBUG: GCC \($0)") }
        if found.report.isEmpty { log("DEBUG: GCC aucun trait (contour) dans le PDF reçu") }
        if o.analyse {
            print("Page \(n) : \(String(format: "%.1f x %.1f mm", box.width / 72 * 25.4, box.height / 72 * 25.4)), mode \(settings.markMode == .colorFill ? "Sélection des couleurs" : "Noir & Blanc"), découpe si trait ≤ \(hairline) mm")
            found.report.forEach { print("  " + $0) }
            if found.report.isEmpty { print("  aucun trait (contour) dans le PDF") }
        }
        let bands = renderBands(page: page, geometry: geometry, strokes: strokes, options: RasterOptions(xdpi: dx, ydpi: dy, settings: settings))
        if o.analyse {
            for b in bands {
                print(String(format: "  gravure stylo %d : %.1f x %.1f mm à (%.1f ; %.1f) mm", b.pen,
                             Double(b.bytesPerRow * 8) / Double(dx) * 25.4, Double(b.rows.count) / Double(dy) * 25.4,
                             Double(b.x) / Double(dx) * 25.4, Double(b.y) / Double(dy) * 25.4))
            }
            if bands.isEmpty { print("  aucune gravure (pas de balayage)") }
        }
        // Cut lines in machine pixels (top-left origin).
        let widthPx = Int((box.width / 72 * CGFloat(dx)).rounded(.up))
        var paths: [VectorPath] = strokes.map { st in
            var points: [(x: Int, y: Int)] = []
            for p in st.points {
                var x = Int((p.x * CGFloat(dx) / 72).rounded())
                if settings.mirror { x = widthPx - x }
                let y = Int(((box.height - p.y) * CGFloat(dy) / 72).rounded())
                // A curve is flattened finer than a machine pixel: no zero-length moves.
                if let l = points.last, l.x == x, l.y == y { continue }
                points.append((x, y))
            }
            return VectorPath(pen: st.pen, points: points)
        }
        paths = orderPaths(paths, settings.vectorFunction)

        // The extent of everything the job does (the *p A/B/C/D of the official driver).
        var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        for b in bands {
            x0 = min(x0, b.inkX0); y0 = min(y0, b.y)
            x1 = max(x1, b.inkX1); y1 = max(y1, b.y + b.rows.count)
        }
        for p in paths { for q in p.points { x0 = min(x0, q.x); y0 = min(y0, q.y); x1 = max(x1, q.x); y1 = max(y1, q.y) } }
        guard x0 <= x1 else {
            log("INFO: page \(n) vide, rien à envoyer")
            continue
        }
        // Bottom up: the bands go from the bottom of the page to the top.
        let ordered = settings.bottomUp
            ? bands.sorted { ($0.pen, -$0.y) < ($1.pen, -$1.y) }
            : bands
        let pens = Set(bands.map(\.pen)).sorted().map(String.init).joined(separator: ",")
        log("INFO: page \(n): \(bands.count) bande(s) raster (stylos \(pens)), \(paths.count) découpe(s), \(settings.dpi) dpi, \(settings.markMode == .colorFill ? "couleurs" : "noir et blanc")")
        job.header(bounds: (x0, y0, x1, y1))
        for b in ordered { job.raster(b) }
        job.vectors(paths)
        job.end()
        out.append(job.data)
    }
    return out
}

func usage() -> Never {
    print("""
    gccspirit – pilote GCC Spirit pour macOS (PDF → travail GCC)

      gccspirit --pdf dessin.pdf --out travail.prn [options]
      gccspirit --pdf dessin.pdf --send 192.168.100.100 [options]   (envoi direct, port 9100)

    Options :
      --analyse              dit, pour chaque trait du PDF, s'il est découpé ou gravé et pourquoi
      --preset fichier.spi   préréglage (par défaut le préréglage actif de l'app GCC Spirit)
      --power-limit 1…100    pourcentage appliqué à la puissance de tous les stylos
      --hairline-mm 0.1      épaisseur max. d'un trait de découpe
    """)
    exit(2)
}

func send(_ data: Data, host: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    task.arguments = ["-w", "10", host, "9100"]
    let pipe = Pipe()
    task.standardInput = pipe
    do { try task.run() } catch { return false }
    pipe.fileHandleForWriting.write(data)
    pipe.fileHandleForWriting.closeFile()
    task.waitUntilExit()
    return task.terminationStatus == 0
}

let args = CommandLine.arguments
if args.count >= 6 && !args[1].hasPrefix("-") {
    // CUPS filter.
    var o = Options()
    if let ppd = ProcessInfo.processInfo.environment["PPD"] { o.loadPPDDefaults(ppd) }
    o.parseCUPS(args[5])
    let input: Data
    if args.count >= 7 {
        input = (try? Data(contentsOf: URL(fileURLWithPath: args[6]))) ?? Data()
    } else {
        input = FileHandle.standardInput.readDataToEndOfFile()
    }
    guard let provider = CGDataProvider(data: input as CFData), let pdf = CGPDFDocument(provider) else {
        log("ERROR: le travail n'est pas un PDF")
        exit(1)
    }
    log("INFO: préréglage \(o.presetPath)")
    let title = args[3]     // as the Windows driver: the document's name, extension included
    FileHandle.standardOutput.write(convert(pdf: pdf, title: title, o: o))
    exit(0)
}

var o = Options()
var pdfPath: String?, outPath: String?, host: String?
var i = 1
while i < args.count {
    let a = args[i]
    func next() -> String { i += 1; guard i < args.count else { usage() }; return args[i] }
    switch a {
    case "--pdf": pdfPath = next()
    case "--out": outPath = next()
    case "--send": host = next()
    case "--preset": o.set("preset", next())
    case "--power-limit": o.set("power-limit", next())
    case "--hairline-mm": o.set("hairline-mm", next())
    case "--analyse": o.analyse = true
    case "--make-ppd":
        // --make-ppd template.ppd out.ppd: the PPD with the print dialog's preset list.
        let template = next(), out = next()
        guard let text = try? String(contentsOfFile: template, encoding: .isoLatin1) else { log("modèle PPD illisible"); exit(1) }
        try SpiritFiles.ppd(template: text).write(toFile: out, atomically: true, encoding: .isoLatin1)
        exit(0)
    default: usage()
    }
    i += 1
}
guard let pdfPath, outPath != nil || host != nil || o.analyse else { usage() }
guard let pdf = CGPDFDocument(URL(fileURLWithPath: pdfPath) as CFURL) else {
    log("impossible de lire \(pdfPath)")
    exit(1)
}
let title = URL(fileURLWithPath: pdfPath).deletingPathExtension().lastPathComponent
let data = convert(pdf: pdf, title: title, o: o)
if let outPath {
    try data.write(to: URL(fileURLWithPath: outPath))
    log("écrit \(data.count) octets dans \(outPath)")
}
if let host {
    log(send(data, host: host) ? "envoyé \(data.count) octets à \(host):9100" : "échec de l'envoi à \(host):9100")
}
