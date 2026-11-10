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
    @ObservationIgnored private var process: PTYProcess?
    @ObservationIgnored private var generation = 0

    init(engine: SwiftTermEngine = SwiftTermEngine()) {
        self.engine = engine
        engine.delegate = self
    }

    var statusText: String? {
        guard case .finished(let st) = state else { return nil }
        switch st {
        case .exited(let c): return "Session terminée (code \(c))"
        case .signaled(let s): return "Session terminée (signal \(s))"
        }
    }

    /// Branche un nouveau processus sur le moteur (l'écran existant est conservé).
    /// `onExit` est appelé exactement une fois, à la fin de CE processus, même si la session a disparu.
    func attach(_ p: PTYProcess, onExit: @escaping @MainActor (PTYExitStatus) -> Void) {
        generation += 1
        let gen = generation
        process = p
        state = .running
        let s = engine.size
        p.resize(columns: s.columns, rows: s.rows)
        Task { @MainActor [weak self] in
            for await chunk in p.output {
                guard let self, self.generation == gen else { continue }
                self.engine.feed(chunk)
            }
            let status = await p.waitForExit()
            if let self, self.generation == gen {
                self.state = .finished(status)
                self.process = nil
            }
            onExit(status)
        }
    }

    /// Écrit du texte directement dans l'écran (séparateurs, messages), sans passer par le pty.
    func appendNotice(_ text: String) {
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

    // MARK: TerminalEngineDelegate

    func terminal(_ engine: any TerminalEngine, didProduceInput bytes: Data) {
        if state == .running { process?.write(bytes) }
    }
    func terminal(_ engine: any TerminalEngine, didResize size: TerminalSize) {
        process?.resize(columns: size.columns, rows: size.rows)
    }
    func terminal(_ engine: any TerminalEngine, didChangeTitle title: String) { self.title = title }
    func terminal(_ engine: any TerminalEngine, didChangeWorkingDirectory url: URL) { workingDirectory = url }
}
