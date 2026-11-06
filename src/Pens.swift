// Pen table of the GCC Spirit: 16 pens, each a colour with its laser settings.
// The fields, their keys in the parameter files and their ranges follow the official driver
// (pen structure of 0x98 bytes, keys PEN<n>… of the [PEN] section).

import Foundation

struct Pen {
    var r = 0, g = 0, b = 0
    var power = 50          // percent, 0…100 (sent ×10)
    var speed = 500         // 0…1000, shown as 0.0…100.0 % (sent as is)
    var raster = true       // RAST "Trame": fills and images in this colour are engraved
    var vector = true       // VECT "Vecteur": hairlines in this colour are cut
    var ppi = 400           // pulses per inch, 1…1524 (1525: Auto)
    var air = true          // BLOWR "Air" (the French driver says "Rampe")
    var airVector = false   // BLOWV
    var autofocus = false
    var defocus = 0         // DEFOCUS_LIST, ×0.01 mm, 0…1000
    var defocusOn = false   // DEFOCUS_CHECK
    var bridge = 0          // BRIDGE_LIST
    var bridgeOn = false    // BRIDGE_CHECK
    var repeatCount = 1     // REPEATCOPY, 1…99
    var powerTuning = false
    var tuningWidth = 1     // 1…5
    var tuningPower = 50

    func matches(r: Int, g: Int, b: Int, tolerance: Int = 2) -> Bool {
        abs(self.r - r) <= tolerance && abs(self.g - g) <= tolerance && abs(self.b - b) <= tolerance
    }
}

/// Colours of the 16 pens in the official Spirit.ini.
let penColours: [(Int, Int, Int)] = [
    (0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (255, 0, 255), (0, 255, 255),
    (255, 128, 128), (128, 255, 128), (255, 255, 128), (128, 128, 255), (255, 128, 255), (128, 255, 255),
    (128, 128, 128), (0, 128, 128), (128, 128, 0),
]

enum PenTable {
    static let count = 16

    static func defaults() -> [Pen] {
        penColours.map { c in
            var p = Pen()
            (p.r, p.g, p.b) = c
            return p
        }
    }

    /// Reads the PEN<n><KEY> entries of an INI file (official .ini / .spi format). Missing keys
    /// keep their defaults; values are clamped to the official ranges.
    static func load(ini f: IniFile) -> [Pen] {
        var pens = defaults()
        for n in 1...count {
            var p = pens[n - 1]
            func get(_ k: String, _ lo: Int, _ hi: Int) -> Int? {
                f.int("PEN", "PEN\(n)\(k)").map { min(max($0, lo), hi) }
            }
            if let v = get("R", 0, 255) { p.r = v }
            if let v = get("G", 0, 255) { p.g = v }
            if let v = get("B", 0, 255) { p.b = v }
            if let v = get("POWER", 0, 100) { p.power = v }
            if let v = get("SPEED", 0, 1000) { p.speed = v }
            if let v = get("RAST", 0, 1) { p.raster = v == 1 }
            if let v = get("VECT", 0, 1) { p.vector = v == 1 }
            if let v = get("PPI", 1, 1525) { p.ppi = v }
            if let v = get("BLOWR", 0, 1) { p.air = v == 1 }
            if let v = get("BLOWV", 0, 1) { p.airVector = v == 1 }
            if let v = get("AUTOFOCUS", 0, 1) { p.autofocus = v == 1 }
            if let v = get("DEFOCUS_LIST", 0, 1000) { p.defocus = v }
            if let v = get("DEFOCUS_CHECK", 0, 1) { p.defocusOn = v == 1 }
            if let v = get("BRIDGE_LIST", 0, 1000) { p.bridge = v }
            if let v = get("BRIDGE_CHECK", 0, 1) { p.bridgeOn = v == 1 }
            if let v = get("REPEATCOPY", 1, 99) { p.repeatCount = v }
            if let v = get("POWERTUNING", 0, 1) { p.powerTuning = v == 1 }
            if let v = get("TUNINGWIDTH", 1, 5) { p.tuningWidth = v }
            if let v = get("TUNINGPOWER", 0, 100) { p.tuningPower = v }
            pens[n - 1] = p
        }
        return pens
    }

    static func store(_ pens: [Pen], into f: inout IniFile) {
        let b = { (x: Bool) in x ? 1 : 0 }
        for (i, p) in pens.enumerated() {
            let n = i + 1
            for (k, v) in [("R", p.r), ("G", p.g), ("B", p.b), ("POWER", p.power), ("SPEED", p.speed),
                           ("RAST", b(p.raster)), ("VECT", b(p.vector)), ("PPI", p.ppi), ("BLOWR", b(p.air)),
                           ("BLOWV", b(p.airVector)), ("AUTOFOCUS", b(p.autofocus)), ("DEFOCUS_LIST", p.defocus),
                           ("DEFOCUS_CHECK", b(p.defocusOn)), ("BRIDGE_LIST", p.bridge), ("BRIDGE_CHECK", b(p.bridgeOn)),
                           ("REPEATCOPY", p.repeatCount), ("POWERTUNING", b(p.powerTuning)),
                           ("TUNINGWIDTH", p.tuningWidth), ("TUNINGPOWER", p.tuningPower)] {
                f.set("PEN", "PEN\(n)\(k)", v)
            }
        }
    }
}
