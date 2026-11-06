// GCC Spirit: the settings of the Mac driver, laid out like the Windows driver's properties
// (Option, Stylo, Avancé, Papier) with its parameter files (.spi): the history list, Save, Load,
// Import, Export, Original, Save to Default, Delete. "OK" makes the settings the active ones,
// used by every print that doesn't choose a preset in the print dialog.

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

final class Store: ObservableObject {
    @Published var s = SpiritSettings()
    @Published var presets: [String] = []
    @Published var selectedPreset: String?
    @Published var pen = 0
    @Published var message = ""
    @Published var newName = ""
    @Published var askingName = false
    @Published var tab = 0
    /// The preset the active settings came from (shown ticked in the menu).
    @Published var activeName = ""
    /// The file the settings came from: keys this app doesn't edit are kept when saving.
    var ini = IniFile()

    init() {
        refresh()
        _ = load(path: SpiritFiles.active) || load(path: SpiritFiles.defaults) || original()
        activeName = s.presetName
        message = ""
    }

    /// Makes a preset the active settings (the menu's choice).
    func activate(_ name: String) {
        guard load(path: SpiritFiles.presets + "/" + name + ".spi") else { return }
        s.presetName = name
        if write(SpiritFiles.active) {
            activeName = name
            message = "« \(name) » est actif."
        }
    }

    func refresh() { presets = SpiritFiles.presetNames() }

    @discardableResult
    func load(path: String) -> Bool {
        guard let f = IniFile(path: path) else { return false }
        ini = f
        s = SpiritSettings(ini: f)
        message = "Chargé : \((path as NSString).lastPathComponent)"
        return true
    }

    @discardableResult
    func original() -> Bool {
        ini = IniFile()
        s = SpiritSettings()
        message = "Valeurs d'origine du pilote GCC"
        return true
    }

    func write(_ path: String) -> Bool {
        var f = ini
        s.store(into: &f)
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try f.write(to: path)
            ini = f
            return true
        } catch {
            message = "Impossible d'écrire \(path) : \(error.localizedDescription)"
            return false
        }
    }

    func apply() {
        if write(SpiritFiles.active) {
            activeName = s.presetName
            message = "Réglages actifs enregistrés : les prochaines impressions les utilisent."
        }
    }

    func saveAs(_ name: String) {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        s.presetName = clean
        if write(SpiritFiles.presets + "/" + clean + ".spi") {
            refresh()
            selectedPreset = clean
            message = "Préréglage « \(clean) » enregistré."
            updatePrintDialog()
        }
    }

    func loadSelected() {
        guard let n = selectedPreset else { return }
        if load(path: SpiritFiles.presets + "/" + n + ".spi") { s.presetName = n }
    }

    func deleteSelected() {
        guard let n = selectedPreset else { return }
        let alert = NSAlert()
        alert.messageText = "Effacer le préréglage « \(n) » ?"
        alert.addButton(withTitle: "Effacer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(atPath: SpiritFiles.presets + "/" + n + ".spi")
        selectedPreset = nil
        refresh()
        updatePrintDialog()
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choisissez les fichiers de paramètres (.spi) copiés depuis le PC Windows"
        guard panel.runModal() == .OK else { return }
        var count = 0
        for url in panel.urls where url.pathExtension.lowercased() == "spi" || IniFile(path: url.path)?.value("PEN", "PEN1POWER") != nil {
            let dest = SpiritFiles.presets + "/" + url.deletingPathExtension().lastPathComponent + ".spi"
            try? FileManager.default.createDirectory(atPath: SpiritFiles.presets, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: dest)
            if (try? FileManager.default.copyItem(atPath: url.path, toPath: dest)) != nil { count += 1 }
        }
        refresh()
        message = "\(count) préréglage(s) importé(s)."
        updatePrintDialog()
    }

    func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (selectedPreset ?? "Spirit") + ".spi"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(url.path) { message = "Exporté : \(url.lastPathComponent)" }
    }

    func saveDefault() {
        if write(SpiritFiles.defaults) { message = "Enregistré comme réglage par défaut." }
    }

    /// Rebuilds the print dialog's preset list (the printer's PPD).
    func updatePrintDialog() {
        let template = SpiritFiles.root + "/GCC_Spirit.ppd"
        guard let text = try? String(contentsOfFile: template, encoding: .isoLatin1) else { return }
        let tmp = NSTemporaryDirectory() + "GCC_Spirit.ppd"
        guard (try? SpiritFiles.ppd(template: text).write(toFile: tmp, atomically: true, encoding: .isoLatin1)) != nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lpadmin")
        task.arguments = ["-p", "GCC_Spirit", "-P", tmp]
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            message += " (liste de l'impression non mise à jour : relancez ./installer.sh)"
        }
    }
}

// MARK: - helpers

private let dpis = [125, 250, 300, 380, 500, 600, 760, 1000, 1500]

private func penColor(_ p: Pen) -> Color {
    Color(red: Double(p.r) / 255, green: Double(p.g) / 255, blue: Double(p.b) / 255)
}

private func yes(_ b: Bool) -> String { b ? "YES" : "NO" }

struct Box<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox(label: Text(title)) {
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var format: (Int) -> String = { "\($0)" }
    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(format(value)).monospacedDigit().frame(width: 60, alignment: .trailing)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

// MARK: - Option

struct OptionTab: View {
    @EnvironmentObject var st: Store

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Box(title: "Mode Configuration") {
                    Picker("", selection: $st.s.markMode) {
                        Text("Noir & Blanc").tag(MarkMode.blackWhite)
                        Text("Sélection des couleurs").tag(MarkMode.colorFill)
                        Text("Mode 3D (non pris en charge)").tag(MarkMode.threeD)
                        Text("Mode tampon (non pris en charge)").tag(MarkMode.stamp)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                Picker("DPI :", selection: $st.s.dpi) {
                    ForEach(dpis, id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 200)
                Box(title: "Image") {
                    Toggle("Miroir", isOn: $st.s.mirror)
                    Toggle("Inverser", isOn: $st.s.invert)
                }
                Toggle("Imprimer immédiatement", isOn: $st.s.immediate)
                Toggle("Unidirectional Engraving", isOn: $st.s.oneDirection)
                if st.s.markMode == .blackWhite {
                    Box(title: "Trame (Noir & Blanc)") {
                        SliderRow(label: "Contraste", value: $st.s.contrast, range: -50...50)
                        Picker("Demi-teinte", selection: $st.s.halftone) {
                            Text("Lissage (trame)").tag(0)
                            Text("Diffusion d'erreurs").tag(1)
                        }
                        if st.s.halftone == 0 {
                            Picker("Matrice", selection: $st.s.ditherMatrix) {
                                ForEach(2...8, id: \.self) { Text("\($0) x \($0)").tag($0) }
                            }
                            Picker("Modèle", selection: $st.s.ditherPattern) {
                                Text("Point").tag(0); Text("Bayer").tag(1); Text("Angulaire").tag(2)
                            }
                        } else {
                            Picker("Type", selection: $st.s.errorDiffusion) {
                                Text("Floyd").tag(0); Text("Stucki").tag(1); Text("Jarvis").tag(2)
                            }
                        }
                    }
                }
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 8) {
                Box(title: "Fonction Fichier") {
                    HStack {
                        Button("Enregistrer") { st.newName = st.selectedPreset ?? st.s.material; st.askingName = true }
                        Button("Charger") { st.loadSelected() }.disabled(st.selectedPreset == nil)
                    }
                    HStack {
                        Button("Import") { st.importFiles() }
                        Button("Export") { st.exportFile() }
                    }
                    Button("Original") { st.original() }
                    Button("Enregistrer dans Défaut") { st.saveDefault() }
                    Button("Effacer") { st.deleteSelected() }.disabled(st.selectedPreset == nil)
                    Text("Fichier historique").padding(.top, 4)
                    List(st.presets, id: \.self, selection: $st.selectedPreset) { n in
                        Text(n).onTapGesture(count: 2) { st.selectedPreset = n; st.loadSelected() }
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .padding()
        .alert("Nom du préréglage", isPresented: $st.askingName) {
            TextField("ex. 30W Granit noir", text: $st.newName)
            Button("Enregistrer") { st.saveAs(st.newName) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Il apparaîtra aussi dans la fenêtre d'impression (CorelDRAW).")
        }
    }
}

// MARK: - Stylo

struct PenTab: View {
    @EnvironmentObject var st: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PenGrid()
            .frame(height: 300)
            HStack(alignment: .top, spacing: 20) {
                VStack {
                    SliderRow(label: "Vitesse", value: $st.s.pens[st.pen].speed, range: 1...1000,
                              format: { String(format: "%.1f", Double($0) / 10) })
                    SliderRow(label: "Puissance", value: $st.s.pens[st.pen].power, range: 0...100)
                    SliderRow(label: "PPI", value: $st.s.pens[st.pen].ppi, range: 1...1524)
                    SliderRow(label: "Defocus", value: $st.s.pens[st.pen].defocus, range: 0...1000,
                              format: { String(format: "%.2f mm", Double($0) / 100) })
                        .disabled(!st.s.pens[st.pen].defocusOn)
                    SliderRow(label: "Puissance rampe", value: $st.s.pens[st.pen].tuningPower, range: 0...100)
                        .disabled(!st.s.pens[st.pen].powerTuning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Trame", isOn: $st.s.pens[st.pen].raster)
                    Toggle("Vecteur", isOn: $st.s.pens[st.pen].vector)
                    Toggle("Air (« Rampe » sur Windows)", isOn: $st.s.pens[st.pen].air)
                    Toggle("Auto Focus", isOn: $st.s.pens[st.pen].autofocus)
                    Toggle("Power ramp tuning", isOn: $st.s.pens[st.pen].powerTuning)
                    Toggle("Defocus", isOn: $st.s.pens[st.pen].defocusOn)
                    Stepper("Repeat : \(st.s.pens[st.pen].repeatCount)", value: $st.s.pens[st.pen].repeatCount, in: 1...99)
                }
                .frame(width: 230)
            }
            Text("Stylo \(st.pen + 1) – couleur RVB \(st.s.pens[st.pen].r), \(st.s.pens[st.pen].g), \(st.s.pens[st.pen].b). Dans CorelDRAW, utilisez exactement cette couleur.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// The pen list, columns as in the Windows driver; a click selects the pen to edit below.
struct PenGrid: View {
    @EnvironmentObject var st: Store
    static let widths: [CGFloat] = [30, 50, 55, 70, 45, 50, 55, 40, 35, 60, 50]

    private func cell(_ t: String, _ i: Int) -> some View {
        Text(t).monospacedDigit().frame(width: PenGrid.widths[i], alignment: .center)
    }

    private func row(_ i: Int) -> some View {
        let p = st.s.pens[i]
        let defocus = String(format: "%.1f", p.defocusOn ? Double(p.defocus) / 100 : 0)
        return HStack(spacing: 0) {
            cell("\(i + 1)", 0)
            RoundedRectangle(cornerRadius: 2).fill(penColor(p)).frame(width: 28, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.gray, lineWidth: 0.5))
                .frame(width: PenGrid.widths[1])
            cell(String(format: "%.1f", Double(p.speed) / 10), 2)
            cell("\(p.power)", 3)
            cell(p.ppi >= 1525 ? "Auto" : "\(p.ppi)", 4)
            cell(yes(p.raster), 5)
            cell(yes(p.vector), 6)
            cell(yes(p.air), 7)
            cell(yes(p.autofocus), 8)
            cell(defocus, 9)
            cell("\(p.repeatCount)", 10)
        }
        .padding(.vertical, 2)
        .background(i == st.pen ? Color.accentColor.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { st.pen = i }
    }

    var body: some View {
        let titles = ["No.", "Couleur", "Vitesse", "Puissance", "PPI", "Trame", "Vecteur", "Air", "AF", "Defocus", "Repeat"]
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Text(titles[i]).font(.caption.bold()).frame(width: PenGrid.widths[i])
                }
            }
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<PenTable.count, id: \.self) { i in row(i) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .border(Color.gray.opacity(0.5))
    }
}

// MARK: - Avancé

struct AdvancedTab: View {
    @EnvironmentObject var st: Store
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Box(title: "Dimensionnement") {
                    SliderRow(label: "X", value: $st.s.scalingX, range: -100...100, format: { "\($0) / 1000" })
                    SliderRow(label: "Y", value: $st.s.scalingY, range: -100...100, format: { "\($0) / 1000" })
                }
                Box(title: "Mode « Position »") {
                    Picker("", selection: $st.s.position) {
                        Text("Home").tag(PositionMode.home)
                        Text("Sans « Home »").tag(PositionMode.withoutHome)
                        Text("Relatif").tag(PositionMode.relative)
                        Text("Centrer").tag(PositionMode.center)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                Box(title: "Orientation de l'image de sortie") {
                    Picker("", selection: $st.s.bottomUp) {
                        Text("Haut vers bas").tag(false)
                        Text("Bas vers haut").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                Box(title: "Drilling") {
                    Toggle("Enable Drilling", isOn: $st.s.drillCheck)
                    SliderRow(label: "Time", value: $st.s.drillTime, range: 0...10000, format: { "\($0) ms" })
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Box(title: "Fonction « Vecteur »") {
                    Picker("", selection: $st.s.vectorFunction) {
                        Text("Normal").tag(VectorFunction.normal)
                        Text("Trame Seulement").tag(VectorFunction.allRaster)
                        Text("Trie vectoriel (intérieur d'abord)").tag(VectorFunction.insideOut)
                        Text("Optimisation de trie").tag(VectorFunction.optimized)
                        Text("Decal Cutting").tag(VectorFunction.decal)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                Box(title: "Mode Vectoriel « Avancé »") {
                    Toggle("Vecteur « Avancé »", isOn: Binding(get: { st.s.advancedVector != 0 }, set: { st.s.advancedVector = $0 ? 1 : 0 }))
                    Toggle("Precise Cutting", isOn: $st.s.preciseCutting)
                }
                Box(title: "Découpe (pilote Mac)") {
                    Picker("Traits découpés jusqu'à", selection: $st.s.hairlineUm) {
                        Text("0,05 mm").tag(50); Text("0,1 mm").tag(100); Text("0,2 mm").tag(200)
                        Text("0,3 mm").tag(300); Text("0,5 mm").tag(500)
                    }
                    Text("Un contour plus fin, dans la couleur d'un stylo « Vecteur », est découpé ; plus épais, il est gravé.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Désactiver le saut de blancs", isOn: $st.s.noSkipWhite)
                Toggle("Vitesse lente (Low speed)", isOn: $st.s.lowSpeed)
            }
        }
        .padding()
    }
}

// MARK: - Papier

struct PaperTab: View {
    @EnvironmentObject var st: Store
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Box(title: "Dimensions papier") {
                HStack { Text("X :"); TextField("", value: mmBinding(\.fieldX), format: .number).frame(width: 80); Text("Millimètres") }
                HStack { Text("Y :"); TextField("", value: mmBinding(\.fieldY), format: .number).frame(width: 80); Text("Millimètres") }
                Toggle("Etendre (740 × 460 mm)", isOn: $st.s.extend)
                Text("Dans CorelDRAW, choisissez le même format de page à l'impression.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 280)
            VStack(alignment: .leading, spacing: 12) {
                Box(title: "Unité") {
                    Picker("", selection: $st.s.unitInch) {
                        Text("Métrique (mm)").tag(false)
                        Text("Impérial (pouces)").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                Box(title: "Rotation du dessin (pilote Mac)") {
                    Picker("", selection: $st.s.rotation) {
                        Text("Aucune").tag(0); Text("90° horaire").tag(90); Text("180°").tag(180); Text("90° anti-horaire").tag(270)
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                Box(title: "Réglages de l'image") {
                    SliderRow(label: "", value: $st.s.imageFactor, range: -10...10)
                }
            }
        }
        .padding()
    }

    private func mmBinding(_ k: WritableKeyPath<SpiritSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(st.s[keyPath: k]) / 1000 }, set: { st.s[keyPath: k] = Int(($0 * 1000).rounded()) })
    }
}

// MARK: - window

struct ContentView: View {
    @EnvironmentObject var st: Store
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $st.tab) {
                OptionTab().tabItem { Text("Option") }.tag(0)
                PenTab().tabItem { Text("Stylo") }.tag(1)
                AdvancedTab().tabItem { Text("Avancé") }.tag(2)
                PaperTab().tabItem { Text("Papier") }.tag(3)
            }
            .padding([.top, .horizontal])
            HStack {
                Text(st.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Annuler") { _ = st.load(path: SpiritFiles.active) || st.original() }
                Button("OK") { st.apply() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 600)
    }
}

/// `GCC Spirit --snapshot <folder> [preset.spi]`: draws each tab into a PNG (to check the layout).
func snapshot(to folder: String, preset: String?) {
    let store = Store()
    if let preset { store.load(path: preset) }
    for t in 0..<4 {
        store.tab = t
        store.pen = t == 1 ? 1 : 0
        let view = NSHostingView(rootView: ContentView().environmentObject(store).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        view.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/onglet-\(t).png"))
    }
}

// MARK: - menu bar

/// The menu of the menu bar icon: the presets (the active one ticked), the settings window.
struct MenuContent: View {
    @EnvironmentObject var st: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Laser GCC Spirit")
        Divider()
        if st.presets.isEmpty {
            Text("Aucun préréglage : Réglages… > Import")
        }
        ForEach(st.presets, id: \.self) { n in
            Button((n == st.activeName ? "✓  " : "     ") + n) { st.activate(n) }
        }
        Divider()
        Button("Réglages…") {
            st.refresh()
            openWindow(id: "reglages")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Button(LoginItem.enabled ? "✓  Ouvrir au démarrage du Mac" : "     Ouvrir au démarrage du Mac") { LoginItem.toggle() }
        Divider()
        Button("Quitter") { NSApp.terminate(nil) }
    }
}

/// Starting with the Mac, so that the menu is always there.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func toggle() {
        if enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }
    /// Registers once, the first time the app runs.
    static func enableOnFirstRun() {
        let key = "loginItemSet"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

@main
struct GCCSpiritApp: App {
    @StateObject private var store = Store()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            NSApplication.shared.setActivationPolicy(.prohibited)
            snapshot(to: args[i + 1], preset: i + 2 < args.count ? args[i + 2] : nil)
            exit(0)
        }
        // Installed: start with the Mac (once; the menu can turn it off).
        if Bundle.main.bundlePath.hasPrefix("/Applications/") { LoginItem.enableOnFirstRun() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(store)
                .onAppear { store.refresh() }
        } label: {
            Image(systemName: "flame")
        }
        Window("Propriétés de : GCC Spirit", id: "reglages") {
            ContentView().environmentObject(store)
        }
    }
}
