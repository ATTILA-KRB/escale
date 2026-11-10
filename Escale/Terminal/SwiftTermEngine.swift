import AppKit
import SwiftTerm
import EscaleCore

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

    private let terminalView: TerminalView
    private let bridge: Bridge

    /// Vrai si le rendu Metal est actif ; sinon repli CoreGraphics (rendu par défaut de SwiftTerm).
    private(set) var isUsingMetal = false

    /// Politique OSC 52 : écriture vers le presse-papiers permise, lecture refusée.
    /// Voir `Bridge.clipboardRead`.
    init(scrollback: Int = 10_000) {
        var options = TerminalOptions.default
        options.scrollback = scrollback
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560), font: nil, options: options)
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
    }

    /// Comme une frappe : passe par `send(source:data:)` du délégué SwiftTerm → `didProduceInput`.
    func sendInput(_ bytes: Data) {
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

    /// Force le dessin d'une image Metal (captures déterministes : la fenêtre peut être inactive
    /// ou masquée et la boucle de rendu à la demande ne pas avoir tourné).
    func refreshDisplay() {
        terminalView.drawMetalFrameNow()
        terminalView.needsDisplay = true
    }

    /// Donne le focus clavier à la vue du terminal.
    func focus() { terminalView.window?.makeFirstResponder(terminalView) }

    /// Vrai si la vue du terminal est le premier répondeur de sa fenêtre (vérifié par l'auto-test).
    var hasKeyboardFocus: Bool { terminalView.window?.firstResponder === terminalView }

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
            e.delegate?.terminal(e, didProduceInput: Data(data))
        }
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) { NSSound.beep() }

        /// OSC 52 écriture : permise (le programme distant peut copier vers le presse-papiers).
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let s = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
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
