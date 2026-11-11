import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import EscaleCore

/// M5 : import de sessions d'autres clients (MobaXterm, PuTTY, CSV), en lecture seule. Menu Fichier › Importer,
/// feuille d'aperçu (cases à cocher, dossier cible, avertissements). L'import `~/.ssh/config` reste celui de
/// `ImportSheet` / `ImportModel` (inchangé).
@MainActor
@Observable
final class ImportFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    /// Feuille d'aperçu ouverte (nil : aucune).
    var pending: SessionImportModel?

    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async { close() }

    /// Boîte « Ouvrir » (lecture seule) puis aperçu.
    func choose(_ kind: SessionImportKind) {
        let panel = NSOpenPanel()
        panel.message = kind.prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = kind.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, kind: kind)
    }

    /// Ouvre l'aperçu d'un fichier (aussi appelé directement par l'auto-test, sans boîte de dialogue).
    @discardableResult
    func open(_ url: URL, kind: SessionImportKind, folder: UUID? = nil) -> SessionImportModel? {
        guard let model else { return nil }
        let m = SessionImportModel(library: model.library, kind: kind, source: url)
        m.folderID = folder
        m.load()
        pending = m
        model.activeFeatureSheet = "import"
        return m
    }

    func close() {
        pending = nil
        if model?.activeFeatureSheet == "import" { model?.activeFeatureSheet = nil }
    }
}

struct ImportCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("Importer") {
                ForEach(SessionImportKind.allCases, id: \.self) { kind in
                    Button(kind.menuTitle) { model.imports.choose(kind) }
                }
            }
        }
    }
}

struct ImportScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.imports.pending },
            set: { if $0 == nil { model.imports.close() } })
        ) { m in
            SessionImportSheet(model: model, importer: m)
        }
    }
}
