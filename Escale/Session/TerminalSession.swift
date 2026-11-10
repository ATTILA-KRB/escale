import Foundation
import Observation
import EscaleCore

/// Relie un moteur de terminal (`any TerminalEngine`) à un `PTYProcess` :
/// sortie pty → `feed`, saisie → `write`, redimensionnement → `resize`,
/// fin du processus → état observable. Ne connaît aucun type SwiftTerm.
@MainActor
@Observable
final class TerminalSession: TerminalEngineDelegate {
    enum State: Equatable {
        case running
        case finished(PTYExitStatus)
    }

    private(set) var state: State = .running
    private(set) var title: String
    private(set) var workingDirectory: URL?

    @ObservationIgnored let engine: any TerminalEngine
    @ObservationIgnored let process: PTYProcess
    @ObservationIgnored private var pumpTask: Task<Void, Never>?

    init(engine: any TerminalEngine, process: PTYProcess, title: String = "Escale") {
        self.engine = engine
        self.process = process
        self.title = title
        engine.delegate = self
        // Alignement immédiat si le moteur a déjà une taille différente de celle du pty.
        let s = engine.size
        process.resize(columns: s.columns, rows: s.rows)
        pumpTask = Task { [weak self] in
            for await chunk in process.output {
                guard let self else { return }
                self.engine.feed(chunk)
            }
            let status = await process.waitForExit()
            self?.state = .finished(status)
        }
    }

    var statusText: String? {
        guard case .finished(let st) = state else { return nil }
        switch st {
        case .exited(let c): return "Terminé, code \(c)"
        case .signaled(let s): return "Terminé, signal \(s)"
        }
    }

    func terminate() { process.terminate() }
    func kill() { process.kill() }

    /// Lance `executable` dans un pty dimensionné d'après le moteur.
    static func launch(engine: any TerminalEngine, executable: String, arguments: [String],
                       environment: [String: String], currentDirectory: String? = nil) throws -> TerminalSession {
        let s = engine.size
        let p = try PTYProcess(executable: executable, arguments: arguments, environment: environment,
                               columns: s.columns, rows: s.rows, currentDirectory: currentDirectory)
        return TerminalSession(engine: engine, process: p, title: (executable as NSString).lastPathComponent)
    }

    // MARK: TerminalEngineDelegate

    func terminal(_ engine: any TerminalEngine, didProduceInput bytes: Data) { process.write(bytes) }
    func terminal(_ engine: any TerminalEngine, didResize size: TerminalSize) {
        process.resize(columns: size.columns, rows: size.rows)
    }
    func terminal(_ engine: any TerminalEngine, didChangeTitle title: String) { self.title = title }
    func terminal(_ engine: any TerminalEngine, didChangeWorkingDirectory url: URL) { workingDirectory = url }
}
