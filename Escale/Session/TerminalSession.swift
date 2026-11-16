import Foundation
import Observation
import EscaleCore

/// Un moteur de terminal (donc un écran et son scrollback) qui survit à plusieurs processus pty
/// successifs : reconnexion SSH, relance d'un shell. Relie le moteur au processus COURANT :
/// sortie pty → `feed`, saisie → `write`, redimensionnement → `resize`.
/// Ne connaît aucun type SwiftTerm (le moteur est celui de `Escale/Terminal/`).
@MainActor
@Observable
final class TerminalSession: TerminalEngineDelegate {
    enum State: Equatable {
        case idle
        case running
        case finished(PTYExitStatus)
    }

    private(set) var state: State = .idle
    /// Titre annoncé par le programme (OSC 0/2) ; vide tant qu'aucun n'a été reçu.
    private(set) var title: String = ""
    private(set) var workingDirectory: URL?

    @ObservationIgnored let engine: SwiftTermEngine
    @ObservationIgnored private var process: (any TerminalByteStream)?
    @ObservationIgnored private var generation = 0
    /// Repérage du refus de redirection X11 dans la sortie du processus courant (shell ssh d'un hôte X11 seulement).
    @ObservationIgnored private var x11Refusal: X11ForwardingRefusalScanner?

    init(engine: SwiftTermEngine = SwiftTermEngine()) {
        self.engine = engine
        engine.delegate = self
    }

    var statusText: String? {
        guard case .finished(let st) = state else { return nil }
        switch st {
        case .exited(let c): return String(localized: "Session terminée (code \(c))")
        case .signaled(let s): return String(localized: "Session terminée (signal \(s))")
        }
    }

    /// Branche un nouveau processus (pty, port série, Telnet) sur le moteur (l'écran existant est conservé).
    /// `onExit` est appelé exactement une fois, à la fin de CE processus, même si la session a disparu.
    /// `watchX11Refusal` : la ligne « X11 forwarding request failed » de ssh est suivie d'un avertissement en français
    /// (la sortie de ssh reste affichée ; aucune sonde, simple lecture du flux).
    func attach(_ p: any TerminalByteStream, watchX11Refusal: Bool = false,
                onExit: @escaping @MainActor (PTYExitStatus) -> Void) {
        generation += 1
        let gen = generation
        process = p
        x11Refusal = watchX11Refusal ? X11ForwardingRefusalScanner() : nil
        // Nouveau flux : l'automate repart de l'état de base (une séquence coupée par la fin du précédent est perdue).
        flushHighlighter()
        if let r = highlighter?.rules { highlighter = OutputHighlighter(rules: r, alternateScreen: engine.isAlternateScreen) }
        state = .running
        let s = engine.size
        p.resize(columns: s.columns, rows: s.rows)
        Task { @MainActor [weak self] in
            for await chunk in p.output {
                guard let self, self.generation == gen else { continue }
                self.feedOutput(chunk)
                if self.x11Refusal?.consume(chunk) == true { self.appendNotice(X11ForwardingRefusalScanner.notice) }
            }
            if let self, self.generation == gen { self.flushHighlighter() }
            let status = await p.waitForExit()
            if let self, self.generation == gen {
                self.state = .finished(status)
                self.process = nil
            }
            onExit(status)
        }
    }

    // MARK: Surlignage de la sortie (voir `OutputHighlighter`)

    /// Jeu de règles appliqué à la sortie du processus (réglé par `TerminalColorsFeature`).
    var highlightRules: HighlightRuleSet {
        get { highlighter?.rules ?? .off }
        set {
            guard newValue != highlightRules else { return }
            flushHighlighter()
            highlighter = newValue == .off ? nil : OutputHighlighter(rules: newValue, alternateScreen: engine.isAlternateScreen)
        }
    }
    @ObservationIgnored private var highlighter: OutputHighlighter?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Dernière saisie de l'utilisateur : un écho interactif n'attend pas la suite du mot.
    @ObservationIgnored private var lastInput = Date.distantPast
    /// Délai au bout duquel un mot retenu en fin de paquet est affiché sans attendre la suite (bien sous une image).
    static let highlightFlushDelay: UInt64 = 8_000_000

    private func feedOutput(_ chunk: Data) {
        guard var h = highlighter else { engine.feed(chunk); return }
        flushTask?.cancel(); flushTask = nil
        var out = h.process(chunk)
        // Écho d'une frappe (paquet court juste après une saisie) : rien n'est retenu, la frappe s'affiche aussitôt.
        if h.hasPending, chunk.count < 64, Date().timeIntervalSince(lastInput) < 0.3 { out += h.flush() }
        highlighter = h
        if !out.isEmpty { engine.feed(out) }
        if h.hasPending {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.highlightFlushDelay)
                guard !Task.isCancelled else { return }
                self?.flushHighlighter()
            }
        }
    }

    private func flushHighlighter() {
        flushTask?.cancel(); flushTask = nil
        guard var h = highlighter, h.hasPending else { return }
        let out = h.flush()
        highlighter = h
        engine.feed(out)
    }

    /// Écrit du texte directement dans l'écran (séparateurs, messages), sans passer par le pty.
    func appendNotice(_ text: String) {
        flushHighlighter()
        engine.feed(Data(("\r\n\u{1b}[2m" + text + "\u{1b}[0m\r\n").utf8))
    }

    /// Ligne de séparation sur toute la largeur de l'écran, texte centré (« ──── texte ──── »).
    func appendSeparator(_ label: String) {
        let width = max(engine.size.columns, label.count + 6)
        let side = (width - label.count - 2) / 2
        let bar = String(repeating: "─", count: max(side, 2))
        appendNotice("\(bar) \(label) \(bar)")
    }

    func kill() { process?.kill() }

    /// Observateurs de la saisie de l'utilisateur, par clé de module (diffusion multi-exécution, macros).
    @ObservationIgnored var inputObservers: [String: @MainActor (Data) -> Void] = [:]

    /// Envoie des octets au processus comme une saisie, sans prévenir `inputObservers` (pas d'écho de diffusion).
    func write(_ bytes: Data) { if state == .running { process?.write(bytes) } }

    // MARK: TerminalEngineDelegate

    func terminal(_ engine: any TerminalEngine, didProduceInput bytes: Data) {
        lastInput = Date()
        if state == .running { process?.write(bytes) }
        for o in inputObservers.values { o(bytes) }
    }
    func terminal(_ engine: any TerminalEngine, didResize size: TerminalSize) {
        process?.resize(columns: size.columns, rows: size.rows)
    }
    func terminal(_ engine: any TerminalEngine, didChangeTitle title: String) { self.title = title }
    func terminal(_ engine: any TerminalEngine, didChangeWorkingDirectory url: URL) { workingDirectory = url }
}
