import Foundation
import Observation
import EscaleCore

/// Source d'import de sessions d'un autre client (M5).
enum SessionImportKind: String, CaseIterable, Sendable {
    case mobaXterm, putty, termius, csv

    var importer: any SessionImporter {
        switch self {
        case .mobaXterm: MobaXtermImporter()
        case .putty: PuTTYRegImporter()
        case .termius: TermiusImporter()
        case .csv: CSVSessionImporter()
        }
    }

    var menuTitle: String {
        switch self {
        case .mobaXterm: String(localized: "Depuis MobaXterm…")
        case .putty: String(localized: "Depuis PuTTY (.reg)…")
        case .termius: String(localized: "Depuis Termius (CSV)…")
        case .csv: String(localized: "Depuis un CSV…")
        }
    }

    var title: String {
        switch self {
        case .mobaXterm: String(localized: "Importer depuis MobaXterm")
        case .putty: String(localized: "Importer depuis PuTTY")
        case .termius: String(localized: "Importer depuis Termius")
        case .csv: String(localized: "Importer depuis un CSV")
        }
    }

    var fileExtensions: [String] {
        switch self {
        case .mobaXterm: ["mxtsessions", "ini", "txt"]
        case .putty: ["reg"]
        case .termius: ["csv", "txt"]
        case .csv: ["csv", "txt"]
        }
    }

    var prompt: String {
        switch self {
        case .mobaXterm: String(localized: "Choisissez un export MobaXterm (.mxtsessions) ou MobaXterm.ini.")
        case .putty: String(localized: "Choisissez l'export .reg de HKCU\\Software\\SimonTatham\\PuTTY\\Sessions.")
        case .termius: String(localized: "Choisissez un CSV au format du modèle Termius (Groups, Label, Tags, Hostname/IP, Protocol, Port, Username, Password). Termius n'a pas d'export natif : modèle rempli ou exporteur tiers.")
        case .csv: String(localized: "Choisissez un CSV (colonnes : name, host, port, user, folder, tags).")
        }
    }
}

/// État de la feuille d'import de sessions. Lecture seule stricte : le fichier source n'est jamais ouvert en écriture.
@MainActor
@Observable
final class SessionImportModel: Identifiable {
    nonisolated let id = UUID()
    let kind: SessionImportKind
    let source: URL
    private(set) var result: SessionImportResult?
    private(set) var error: String?
    /// Sessions déjà présentes (même host+port+user) : grisées, non importables.
    private(set) var existing: Set<UUID> = []
    var selected: Set<UUID> = []
    var folderID: UUID?
    /// Recrée les dossiers d'origine sous le dossier cible.
    var keepFolders = true
    private(set) var report: SessionImportReport?

    @ObservationIgnored private let library: LibraryStore

    init(library: LibraryStore, kind: SessionImportKind, source: URL) {
        self.library = library; self.kind = kind; self.source = source
    }

    var sessions: [ImportedSession] { result?.sessions ?? [] }
    var warnings: [String] { result?.warnings ?? [] }
    var passwordNotice: String? { result?.passwordNotice }
    var importableCount: Int { sessions.count - existing.count }
    func isImportable(_ s: ImportedSession) -> Bool { !existing.contains(s.id) }

    func load() {
        error = nil
        do {
            let r = try kind.importer.parse(fileAt: source)
            result = r
            existing = SessionImportMerge.existingIDs(r.sessions, comparedTo: library.library)
            // Doublons internes au fichier : seule la première occurrence est cochée.
            var seen = Set<String>()
            selected = Set(r.sessions.filter { isImportable($0) && seen.insert($0.identityKey).inserted }.map(\.id))
        } catch {
            result = nil
            self.error = String(localized: "Lecture de « \(source.path) » impossible : \(error.localizedDescription)")
        }
    }

    func selectAll() { selected = Set(sessions.filter(isImportable).map(\.id)) }

    /// Ajoute les sessions cochées ; renvoie le compte rendu.
    @discardableResult
    func commit() -> SessionImportReport {
        let chosen = sessions.filter { selected.contains($0.id) && isImportable($0) }
        let r = library.importSessions(chosen, into: folderID, keepFolders: keepFolders)
        report = r
        return r
    }
}
