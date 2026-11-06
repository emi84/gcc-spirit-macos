// Parameter files of the official driver (.spi): Windows INI text, sections [VERSION], [OPTION],
// [ADVANCE], [PAPER], [RASTER], [STAMP], [PEN]… Read and written keeping every key and its order,
// so a file saved on the Mac still opens in the Windows driver.

import Foundation

/// An INI file: ordered sections of ordered key/value pairs.
struct IniFile {
    var sections: [(name: String, entries: [(key: String, value: String)])] = []

    init() {}

    init(text: String) {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("//") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                sections.append((String(line[line.index(after: line.startIndex)..<end]), []))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // A comment after the value ("OFFSET = 50000   //50mm").
            if let c = value.range(of: "//") { value = value[..<c.lowerBound].trimmingCharacters(in: .whitespaces) }
            if sections.isEmpty { sections.append(("", [])) }
            sections[sections.count - 1].entries.append((key, value))
        }
    }

    /// Reads a file in any of the encodings Windows writes INI files in (UTF-16 with BOM, UTF-8, ANSI).
    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard let text else { return nil }
        self.init(text: text)
    }

    func value(_ section: String, _ key: String) -> String? {
        for s in sections where s.name.caseInsensitiveCompare(section) == .orderedSame {
            for e in s.entries where e.key.caseInsensitiveCompare(key) == .orderedSame { return e.value }
        }
        return nil
    }

    func int(_ section: String, _ key: String) -> Int? {
        value(section, key).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) }
    }

    mutating func set(_ section: String, _ key: String, _ value: String) {
        let si: Int
        if let i = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(section) == .orderedSame }) {
            si = i
        } else {
            sections.append((section, []))
            si = sections.count - 1
        }
        if let ki = sections[si].entries.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            sections[si].entries[ki].value = value
        } else {
            sections[si].entries.append((key, value))
        }
    }

    mutating func set(_ section: String, _ key: String, _ value: Int) { set(section, key, String(value)) }

    /// Windows-style text (CRLF), as WritePrivateProfileString leaves it.
    var text: String {
        var out = ""
        for s in sections {
            if !s.name.isEmpty { out += "[\(s.name)]\r\n" }
            for e in s.entries { out += "\(e.key)=\(e.value)\r\n" }
        }
        return out
    }

    func write(to path: String) throws {
        try text.data(using: .windowsCP1252, allowLossyConversion: true)!.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

enum MarkMode: Int, CaseIterable {
    case blackWhite = 1, colorFill = 2, threeD = 3, stamp = 4, rasterStamp = 5
}

/// POSITION in [ADVANCE]; each mode starts and ends the job as Spirit.ini's [POSITION] says.
enum PositionMode: Int, CaseIterable {
    case home = 0, withoutHome = 1, relative = 2, center = 3

    /// START: absolute (0), relative (1), relative to the job's centre (2).
    var start: Int { [0, 0, 1, 2][rawValue] }
    /// END: stay (0), top-left (1), bottom-left (2), top-right (3), bottom-right (4), back (5).
    var end: Int { [3, 0, 5, 5][rawValue] }
}

/// VECTOR_FUNCTION in [ADVANCE].
enum VectorFunction: Int, CaseIterable {
    case normal = 0, allRaster = 1, insideOut = 2, optimized = 3, decal = 4
}

/// Everything a job takes from a parameter file. Defaults are the official Spirit.ini's.
struct SpiritSettings {
    var markMode = MarkMode.blackWhite
    var dpi = 500
    var mirror = false
    var invert = false
    var immediate = false           // Imprimer immédiatement → ESC!m1S
    var accArea = false             // USE_ACC_AREA → ESC!r1A
    var oneDirection = false        // Unidirectional Engraving → ESC!r1V
    var lowSpeed = false            // ESC!s1S
    var preview = false
    var scalingX = 0, scalingY = 0  // per mille
    var position = PositionMode.home
    var vectorFunction = VectorFunction.normal
    var bottomUp = false            // Bas vers haut → ESC!r1B
    var noSkipWhite = false
    var drillCheck = false
    var drillTime = 2500            // ms → ESC!h<n>T
    var drillPower = 50
    var advancedVector = 0          // MODE → ESC!r<n>E
    var cuttingFirst = false
    var preciseCutting = false
    var fieldX = 640_000, fieldY = 460_000   // µm
    var extend = false
    var unitInch = false
    var imageFactor = 0             // IMAGE_TUNING FACTOR → ESC!r<n>N
    var contrast = 0                // -50…50
    var halftone = 0                // 0 dithering, 1 error diffusion
    var ditherMatrix = 8            // 2…8
    var ditherPattern = 0           // 0 dot, 1 Bayer, 2 corner
    var errorDiffusion = 0          // 0 Floyd, 1 Stucki, 2 Jarvis
    var material = ""
    var pens = PenTable.defaults()
    // Mac driver only ([MAC] section, ignored by the Windows driver):
    var hairlineUm = 100            // thicker strokes are engraved, not cut
    var rotation = 0                // extra clockwise quarter turns of the page: 0, 90, 180, 270
    var presetName = ""             // the preset these settings came from

    init() {}

    init(ini f: IniFile) {
        if let v = f.int("OPTION", "MARK_MODE"), let m = MarkMode(rawValue: v) { markMode = m }
        if let v = f.int("OPTION", "RESOLUTION"), resolutions[v] != nil { dpi = v }
        mirror = f.int("OPTION", "MIRROR") == 1
        invert = f.int("OPTION", "INVERT") == 1
        immediate = f.int("OPTION", "IMMEDIATE") == 1
        accArea = f.int("OPTION", "USE_ACC_AREA") == 1
        preview = f.int("OPTION", "PREVIEW") == 1
        oneDirection = f.int("OPTION", "IMAGEONEDIRECTION") == 1
        material = f.value("OPTION", "MATERIAL") ?? ""
        lowSpeed = f.int("ADVANCE", "LOW_SPEED") == 1
        scalingX = f.int("ADVANCE", "SCALING_X") ?? 0
        scalingY = f.int("ADVANCE", "SCALING_Y") ?? 0
        if let v = f.int("ADVANCE", "POSITION"), let p = PositionMode(rawValue: v) { position = p }
        if let v = f.int("ADVANCE", "VECTOR_FUNCTION"), let p = VectorFunction(rawValue: v) { vectorFunction = p }
        bottomUp = f.int("ADVANCE", "BOTTOM_UP") == 1
        noSkipWhite = f.int("ADVANCE", "NO_SKIP_WHITE") == 1
        drillCheck = f.int("ADVANCE", "DRILLCHECK") == 1
        drillTime = f.int("ADVANCE", "DRILLINGTIME") ?? 2500
        drillPower = f.int("ADVANCE", "DRILLINGPOWER") ?? 50
        advancedVector = f.int("ADVANCE", "MODE") ?? 0
        cuttingFirst = f.int("ADVANCE", "CUTTINGFIRST") == 1
        preciseCutting = f.int("ADVANCE", "PRECISECUTTING") == 1
        fieldX = f.int("PAPER", "FIELD_X") ?? fieldX
        fieldY = f.int("PAPER", "FIELD_Y") ?? fieldY
        extend = f.int("PAPER", "EXTEND") == 1
        unitInch = f.int("PAPER", "UNIT") == 1
        imageFactor = f.int("IMAGE_TUNING", "FACTOR") ?? 0
        contrast = f.int("RASTER", "CONTRAST") ?? 0
        halftone = f.int("RASTER", "HALFTONE") ?? 0
        ditherMatrix = min(max(f.int("RASTER", "DITHER_MX") ?? 8, 2), 8)
        ditherPattern = f.int("RASTER", "DITHER_PT") ?? 0
        errorDiffusion = f.int("RASTER", "ERR_DIFFU_TYPE") ?? 0
        pens = PenTable.load(ini: f)
        hairlineUm = min(max(f.int("MAC", "HAIRLINE_UM") ?? 100, 1), 5000)
        rotation = [0, 90, 180, 270].contains(f.int("MAC", "ROTATION") ?? 0) ? f.int("MAC", "ROTATION") ?? 0 : 0
        presetName = f.value("MAC", "PRESET") ?? ""
    }

    /// Writes these settings into `f`, keeping whatever else it holds.
    func store(into f: inout IniFile) {
        let b = { (x: Bool) in x ? 1 : 0 }
        if f.value("VERSION", "MACH_NAME") == nil { f.set("VERSION", "MACH_NAME", "Spirit") }
        if f.value("VERSION", "VERSION") == nil { f.set("VERSION", "VERSION", 425) }
        f.set("OPTION", "MARK_MODE", markMode.rawValue)
        f.set("OPTION", "RESOLUTION", dpi)
        f.set("OPTION", "MIRROR", b(mirror))
        f.set("OPTION", "INVERT", b(invert))
        f.set("OPTION", "IMMEDIATE", b(immediate))
        f.set("OPTION", "USE_ACC_AREA", b(accArea))
        f.set("OPTION", "PREVIEW", b(preview))
        f.set("OPTION", "IMAGEONEDIRECTION", b(oneDirection))
        f.set("OPTION", "MATERIAL", material)
        f.set("ADVANCE", "SCALING_X", scalingX)
        f.set("ADVANCE", "SCALING_Y", scalingY)
        f.set("ADVANCE", "POSITION", position.rawValue)
        f.set("ADVANCE", "VECTOR_FUNCTION", vectorFunction.rawValue)
        f.set("ADVANCE", "BOTTOM_UP", b(bottomUp))
        f.set("ADVANCE", "NO_SKIP_WHITE", b(noSkipWhite))
        f.set("ADVANCE", "LOW_SPEED", b(lowSpeed))
        f.set("ADVANCE", "DRILLCHECK", b(drillCheck))
        f.set("ADVANCE", "DRILLINGTIME", drillTime)
        f.set("ADVANCE", "DRILLINGPOWER", drillPower)
        f.set("ADVANCE", "MODE", advancedVector)
        f.set("ADVANCE", "CUTTINGFIRST", b(cuttingFirst))
        f.set("ADVANCE", "PRECISECUTTING", b(preciseCutting))
        f.set("PAPER", "FIELD_X", fieldX)
        f.set("PAPER", "FIELD_Y", fieldY)
        f.set("PAPER", "EXTEND", b(extend))
        f.set("PAPER", "UNIT", b(unitInch))
        f.set("IMAGE_TUNING", "FACTOR", imageFactor)
        f.set("RASTER", "CONTRAST", contrast)
        f.set("RASTER", "HALFTONE", halftone)
        f.set("RASTER", "DITHER_MX", ditherMatrix)
        f.set("RASTER", "DITHER_PT", ditherPattern)
        f.set("RASTER", "ERR_DIFFU_TYPE", errorDiffusion)
        PenTable.store(pens, into: &f)
        f.set("MAC", "HAIRLINE_UM", hairlineUm)
        f.set("MAC", "ROTATION", rotation)
        f.set("MAC", "PRESET", presetName)
    }
}

/// Where the Mac driver keeps its parameter files.
enum SpiritFiles {
    static let root = "/Library/Printers/GCC/Spirit"
    static let presets = root + "/Presets"
    /// The settings a print uses unless the print dialog names a preset.
    static let active = root + "/actif.spi"
    /// "Enregistrer dans Défaut" / "Original".
    static let defaults = root + "/defaut.spi"

    static func presetNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: presets)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".spi") }.map { String($0.dropLast(4)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension SpiritFiles {
    /// A preset name as a print-dialog choice: letters and digits, "_" for the rest, 40 at most.
    static func keyword(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let k = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
        return String(("P_" + k).prefix(40))
    }

    /// The preset file a print-dialog choice names, if it still exists.
    static func preset(keyword: String) -> String? {
        presetNames().first { self.keyword($0) == keyword }.map { presets + "/" + $0 + ".spi" }
    }

    /// The PPD with the print dialog's preset list filled in from the presets folder.
    static func ppd(template: String) -> String {
        let names = presetNames()
        var lines = ["*OpenUI *GCCPreset/Preset (matiere): PickOne",
                     "*OrderDependency: 5 AnySetup *GCCPreset",
                     "*DefaultGCCPreset: Actif",
                     "*GCCPreset Actif/Reglage actif (app GCC Spirit): \"\""]
        for n in names {
            let label = String(n.folding(options: .diacriticInsensitive, locale: nil)
                .unicodeScalars.filter { $0.isASCII && $0 != ":" && $0 != "/" && $0 != "\"" }.map(Character.init).prefix(70))
            lines.append("*GCCPreset \(keyword(n))/\(label): \"\"")
        }
        lines.append("*CloseUI: *GCCPreset")
        return template.replacingOccurrences(of: "*% GCCPRESETS", with: lines.joined(separator: "\n"))
    }
}
