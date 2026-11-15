import AppKit
import QuartzCore
import SwiftTerm
import EscaleCore

/// Presse-papiers cible de l'OSC 52 (écriture). Le général par défaut ; les recettes le remplacent par un
/// presse-papiers nommé pour ne jamais écraser celui de l'utilisateur.
@MainActor
enum TerminalClipboard {
    static var pasteboard: NSPasteboard = .general
}

/// Adaptateur SwiftTerm du contrat `TerminalEngine`. Seul fichier (avec ses voisins de ce
/// dossier) autorisé à importer SwiftTerm : l'app n'en voit que `view` (une `NSView`).
///
/// Utilise la `TerminalView` NUE (alimentée par `feed`, saisie sortante via le délégué), jamais
/// `LocalProcessTerminalView` : le transport (pty local ou canal SSH) est choisi par l'appelant.
@MainActor
final class SwiftTermEngine: TerminalEngine {
    /// Vue à insérer dans la hiérarchie AppKit/SwiftUI.
    let view: NSView
    weak var delegate: (any TerminalEngineDelegate)?

    private let terminalView: EscaleTerminalView
    /// Vrai pendant `sendInput` : une saisie programmée (macros, diffusion) n'est jamais filtrée par la composition.
    private var isProgrammaticInput = false
    private let bridge: Bridge

    /// Vrai si le rendu Metal est actif ; sinon repli CoreGraphics (rendu par défaut de SwiftTerm).
    private(set) var isUsingMetal = false

    /// Politique OSC 52 : écriture vers le presse-papiers permise, lecture refusée.
    /// Voir `Bridge.clipboardRead`.
    init(scrollback: Int = 10_000) {
        var options = TerminalOptions.default
        options.scrollback = scrollback
        let tv = EscaleTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560), font: nil, options: options)
        terminalView = tv
        view = tv
        bridge = Bridge()
        bridge.engine = self
        tv.terminalDelegate = bridge
        do {
            try tv.setUseMetal(true)
            isUsingMetal = tv.isUsingMetalRenderer
        } catch {
            isUsingMetal = false // repli CoreGraphics
        }
    }

    var size: TerminalSize {
        let d = terminalView.terminalDimensions
        return TerminalSize(columns: d.cols, rows: d.rows)
    }

    /// Hauteur d'une cellule (points) : la zone du moteur est dimensionnée en multiple entier pour ne rogner aucune ligne.
    var cellHeight: CGFloat {
        let d = terminalView.terminalDimensions
        guard d.rows > 0 else { return 0 }
        return terminalView.getOptimalFrameSize().height / CGFloat(d.rows)
    }

    func feed(_ bytes: Data) {
        terminalView.feed(byteArray: [UInt8](bytes)[...])
        terminalView.contentDidChange()
    }

    /// Comme une frappe : passe par `send(source:data:)` du délégué SwiftTerm → `didProduceInput`.
    func sendInput(_ bytes: Data) {
        isProgrammaticInput = true
        defer { isProgrammaticInput = false }
        terminalView.send(data: [UInt8](bytes)[...])
    }

    func text(includingScrollback: Bool) -> String {
        let region: TerminalContentRegion = includingScrollback ? .all : .history(maximumScrollbackRows: -1)
        guard let snap = terminalView.terminalContentSnapshot(region: region) else { return "" }
        var out = ""
        for (i, row) in snap.rows.enumerated() {
            if i > 0 && !row.isWrapped { out += "\n" }
            out += row.text
        }
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    func setFont(name: String, size: Double) {
        terminalView.font = NSFont(name: name, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    // MARK: - Thème de couleurs

    /// Identifiant du thème appliqué (`nil` : défauts du moteur, jamais touchés).
    private(set) var themeID: String?
    /// Fond imposé par le thème ; `nil` : thème « Système » (fond dynamique de macOS).
    private(set) var themeBackground: NSColor?
    /// Fond à peindre autour de la grille (marges, séparateurs) : celui du thème, sinon le fond dynamique du système
    /// (à résoudre dans l'apparence de la vue qui le peint).
    var marginBackground: NSColor { themeBackground ?? .textBackgroundColor }

    /// Applique un thème : 16 couleurs ANSI (le cube 256 en est recalculé), texte, fond, curseur, sélection.
    /// Le contenu déjà affiché est redessiné avec la nouvelle palette (les cellules gardent leurs index de couleur).
    func apply(theme: TerminalTheme) {
        guard theme.id != themeID else { return }
        themeID = theme.id
        terminalView.installColors(theme.ansi.map { Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue)) })
        func ns(_ c: TerminalRGB) -> NSColor { NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1) }
        if let fg = theme.foreground, let bg = theme.background {
            terminalView.nativeForegroundColor = ns(fg)
            terminalView.nativeBackgroundColor = ns(bg)
            themeBackground = ns(bg)
        } else {
            // Système : couleurs dynamiques de macOS, comme à la création de la vue.
            terminalView.nativeForegroundColor = .textColor
            terminalView.nativeBackgroundColor = .textBackgroundColor
            themeBackground = nil
        }
        terminalView.caretColor = theme.cursor.map(ns) ?? .selectedControlColor
        terminalView.selectedTextBackgroundColor = theme.selectionBackground.map(ns)
            ?? NSColor(srgbRed: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1.0)
        terminalView.selectedTextForegroundColor = theme.selectionForeground.map(ns) ?? .black
        terminalView.needsDisplay = true
        terminalView.superview?.needsLayout = true
    }

    /// Vrai si l'écran alternatif est actif (vim, less, htop) : le surlignage de la sortie s'y abstient.
    /// Lu à l'attache d'un processus ou au changement de réglage (copie de l'écran visible : pas à chaque paquet).
    var isAlternateScreen: Bool { terminalView.terminalContentSnapshot(region: .viewport)?.bufferKind == .alt }

    /// Recette : couleur de texte de la première cellule de chaque occurrence de `needle` (scrollback compris),
    /// sous forme lisible : `ansi:1`, `rgb:ff8000`, `default`.
    func foregroundDescriptions(of needle: String) -> [String] {
        guard let snap = terminalView.terminalContentSnapshot(region: .history(maximumScrollbackRows: 10_000)) else { return [] }
        var out: [String] = []
        for row in snap.rows {
            // Index de cellule de chaque caractère (les cellules de continuation des caractères larges sont sautées).
            var chars: [Character] = []
            var cellIndex: [Int] = []
            for (i, c) in row.cells.enumerated() where c.width > 0 {
                chars.append(c.isBlank ? " " : Character(c.text)); cellIndex.append(i)
            }
            let line = String(chars)
            var from = line.startIndex
            while let r = line.range(of: needle, range: from..<line.endIndex) {
                let attr = row.cells[cellIndex[line.distance(from: line.startIndex, to: r.lowerBound)]].attribute
                switch attr.fg {
                case .ansi256(let code): out.append("ansi:\(code)")
                case .trueColor(let r, let g, let b): out.append(String(format: "rgb:%02x%02x%02x", r, g, b))
                case .defaultColor: out.append("default")
                case .defaultInvertedColor: out.append("inverted")
                }
                from = r.upperBound
            }
        }
        return out
    }

    /// Recette : fond effectif de la vue (sRGB 8 bits).
    var effectiveBackground: TerminalRGB {
        let c = terminalView.nativeBackgroundColor.usingColorSpace(.sRGB) ?? .black
        return TerminalRGB(UInt8((c.redComponent * 255).rounded()), UInt8((c.greenComponent * 255).rounded()), UInt8((c.blueComponent * 255).rounded()))
    }

    /// Force le dessin d'une image Metal (captures déterministes : la fenêtre peut être inactive
    /// ou masquée et la boucle de rendu à la demande ne pas avoir tourné).
    func refreshDisplay() {
        terminalView.drawMetalFrameNow()
        terminalView.needsDisplay = true
        // Force le rendu synchrone de la fenêtre et la validation de la transaction Core Animation : sans cela,
        // une capture prise juste après une reconnexion peut montrer la frame précédente.
        terminalView.window?.displayIfNeeded()
        CATransaction.flush()
    }

    /// Donne le focus clavier à la vue du terminal.
    func focus() { terminalView.window?.makeFirstResponder(terminalView) }

    /// Vrai si la vue du terminal est le premier répondeur de sa fenêtre (vérifié par l'auto-test).
    var hasKeyboardFocus: Bool { terminalView.window?.firstResponder === terminalView }

    // MARK: - Accessibilité et saisie composée (voir EscaleTerminalView)

    /// Libellé VoiceOver de la vue (« Terminal — <hôte> »).
    var accessibilityLabel: String {
        get { terminalView.terminalAccessibilityLabel }
        set { terminalView.terminalAccessibilityLabel = newValue }
    }
    /// La vue comme client de saisie AppKit (la recette pilote setMarkedText/insertText comme un IME).
    var textInputClient: NSTextInputClient { terminalView }
    var isComposing: Bool { terminalView.isComposing }
    var suppressedOutputCount: Int { terminalView.suppressedOutputCount }
    var accessibilityNotificationCount: Int { terminalView.accessibilityNotificationCount }
    var accessibilityRebuildCount: Int { terminalView.accessibilityRebuildCount }
    func selectAll() { terminalView.selectAll() }
    func clearSelection() { terminalView.selectNone() }
    func forceAccessibilityNotifications(_ on: Bool) { terminalView.forceAccessibilityNotifications = on }

    // MARK: - Pont vers TerminalViewDelegate (SwiftTerm)

    private final class Bridge: TerminalViewDelegate {
        weak var engine: SwiftTermEngine?

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let e = engine else { return }
            e.delegate?.terminal(e, didResize: TerminalSize(columns: newCols, rows: newRows))
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            guard let e = engine else { return }
            e.delegate?.terminal(e, didChangeTitle: title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let e = engine, let directory else { return }
            // OSC 7 : « file://hôte/chemin » (chemin encodé) ; tolère un simple chemin.
            let url = URL(string: directory).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: directory)
            e.delegate?.terminal(e, didChangeWorkingDirectory: url)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let e = engine else { return }
            // Pendant une composition IME, le clavier appartient à l'IME (Retour arrière, Échap, flèches
            // passés par doCommand ne doivent pas atteindre l'hôte).
            if !e.isProgrammaticInput && e.terminalView.shouldSuppressOutput { return }
            e.delegate?.terminal(e, didProduceInput: Data(data))
        }
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) { NSSound.beep() }

        /// OSC 52 écriture : permise (le programme distant peut copier vers le presse-papiers).
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let s = String(data: content, encoding: .utf8) else { return }
            // Le délégué est appelé sur le fil principal (vue AppKit).
            MainActor.assumeIsolated {
                let pb = TerminalClipboard.pasteboard
                pb.clearContents()
                pb.setString(s, forType: .string)
            }
        }
        /// OSC 52 lecture : REFUSÉE. L'API SwiftTerm le permet : renvoyer `nil` nie la requête
        /// (comportement par défaut documenté), sans réponse envoyée au programme distant.
        /// Un hôte SSH quelconque ne doit pas pouvoir lire le presse-papiers du Mac.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        // OSC 5522 (presse-papiers kitty) : désactivé en entier (aucune capacité annoncée).
        func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
        func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { [] }
        func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { .denied }
        func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .denied }
        func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
