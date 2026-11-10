import Foundation

/// Contrat entre l'app et le moteur de terminal. Aucun type du moteur (SwiftTerm aujourd'hui)
/// ne doit sortir de son adaptateur : c'est ce qui permet d'en changer.
@MainActor
public protocol TerminalEngine: AnyObject {
    var delegate: (any TerminalEngineDelegate)? { get set }
    var size: TerminalSize { get }
    /// Octets reçus de l'hôte (sortie du pty), à interpréter et afficher.
    func feed(_ bytes: Data)
    /// Injecte une saisie comme si elle venait du clavier (multi-exécution, snippets).
    func sendInput(_ bytes: Data)
    /// Texte du tampon, scrollback compris si demandé.
    func text(includingScrollback: Bool) -> String
    func setFont(name: String, size: Double)
}

public struct TerminalSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
}

@MainActor
public protocol TerminalEngineDelegate: AnyObject {
    /// Saisie de l'utilisateur à écrire dans le pty.
    func terminal(_ engine: any TerminalEngine, didProduceInput bytes: Data)
    func terminal(_ engine: any TerminalEngine, didResize size: TerminalSize)
    func terminal(_ engine: any TerminalEngine, didChangeTitle title: String)
    /// OSC 7 : dossier courant annoncé par le shell distant (sert au suivi SFTP).
    func terminal(_ engine: any TerminalEngine, didChangeWorkingDirectory url: URL)
}
