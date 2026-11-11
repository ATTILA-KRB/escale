import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EscaleCore

/// Fichier distant glissé vers le Finder : téléchargé à la demande dans un dossier temporaire.
struct RemoteDragFile: Transferable, Sendable {
    let fetch: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(try await file.fetch(), allowAccessingOriginalFile: true)
        }
    }
}

/// Contenu de l'inspecteur : navigateur de l'hôte de l'onglet actif + file de transferts.
struct SFTPBrowserView: View {
    @Bindable var feature: SFTPFeature

    var body: some View {
        VStack(spacing: 0) {
            if let session = feature.currentSession() {
                SFTPSessionView(feature: feature, session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView {
                    Label("Aucun hôte SSH", systemImage: "folder")
                } description: {
                    Text("Sélectionnez un onglet SSH, ou choisissez « Parcourir les fichiers (SFTP) » dans le menu d'un hôte.")
                }
                .frame(maxHeight: .infinity)
            }
            SFTPActivityView(feature: feature)
        }
        .background(.background)
    }
}

private struct SFTPSessionView: View {
    @Bindable var feature: SFTPFeature
    @Bindable var session: SFTPHostSession
    @State private var pathText = ""
    @State private var renaming: SFTPItem?
    @State private var renameText = ""
    @State private var creating = false
    @State private var newFolderText = ""
    @State private var deleting: [SFTPItem] = []
    @State private var confirmTracking = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            pathBar
            followRow
            if let m = session.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(m).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { session.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8).background(.orange.opacity(0.12))
            }
            Divider()
            content
        }
        .task(id: session.id) { await session.open() }
        .onChange(of: session.pathString) { _, new in pathText = new }
        .onAppear { pathText = session.pathString }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") { if let it = renaming { Task { await session.rename(it, to: renameText) } }; renaming = nil }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .alert("Nouveau dossier", isPresented: $creating) {
            TextField("Nom du dossier", text: $newFolderText)
            Button("Créer") { Task { await session.makeDirectory(newFolderText) } }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { let l = deleting; deleting = []; Task { await session.delete(l) } }
            Button("Annuler", role: .cancel) { deleting = [] }
        } message: {
            Text("Cette suppression est définitive : le contenu des dossiers est supprimé aussi.")
        }
        .confirmationDialog("Activer le suivi du dossier ?", isPresented: $confirmTracking, titleVisibility: .visible) {
            Button("Envoyer la fonction au shell") { feature.injectTracking() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Escale tape une fonction dans le shell distant (une fois, pour cette session) qui annonce le dossier courant à chaque invite (séquence OSC 7). Rien n'est écrit sur le serveur.")
        }
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Supprimer « \(deleting[0].name) » ?" : "Supprimer \(deleting.count) éléments ?"
    }

    // MARK: En-tête

    private var toolbar: some View {
        HStack(spacing: 4) {
            Text(session.profile.name).font(.headline).lineLimit(1)
            Spacer()
            Button { Task { await session.goBack() } } label: { Image(systemName: "chevron.left") }
                .disabled(session.back.isEmpty).help("Précédent")
            Button { Task { await session.goForward() } } label: { Image(systemName: "chevron.right") }
                .disabled(session.forward.isEmpty).help("Suivant")
            Button { Task { await session.goUp() } } label: { Image(systemName: "arrow.up") }
                .disabled(!session.canGoUp).help("Dossier parent")
            Button { Task { await session.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(!session.isReady).help("Actualiser")
            Button { newFolderText = ""; creating = true } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!session.isReady).help("Nouveau dossier")
            Menu {
                Toggle("Afficher les fichiers cachés", isOn: $session.showHidden)
                Button("Envoyer des fichiers…") { chooseFilesToUpload() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var pathBar: some View {
        TextField("Chemin", text: $pathText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { Task { await session.navigate(to: pathText) } }
            .padding(.horizontal, 10).padding(.bottom, 6)
            .disabled(!session.isReady)
    }

    private var followRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Suivre le terminal", isOn: $feature.followTerminal)
                .toggleStyle(.switch).controlSize(.small)
            if feature.followTerminal, feature.trackingMissing {
                HStack(spacing: 6) {
                    Text("Ce shell n'annonce pas son dossier.").font(.caption).foregroundStyle(.secondary)
                    Button("Activer le suivi") { confirmTracking = true }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Liste

    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle, .connecting:
            VStack { ProgressView("Ouverture du canal SFTP…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lost:
            VStack(spacing: 8) {
                ProgressView()
                Text("Connexion perdue — le navigateur reprendra à la reconnexion.").font(.caption).multilineTextAlignment(.center)
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            ContentUnavailableView {
                Label("SFTP indisponible", systemImage: "exclamationmark.triangle")
            } description: {
                Text(m)
            } actions: {
                Button("Réessayer") { Task { await session.open() } }
            }
        case .ready:
            list
        }
    }

    private var list: some View {
        List(selection: $session.selection) {
            ForEach(session.visibleItems) { item in
                row(item).tag(item.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if session.visibleItems.isEmpty && !session.isLoading {
                Text("Dossier vide").foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: Data.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            let items = session.items.filter { ids.contains($0.id) }
            guard items.count == 1, let it = items.first else { return }
            Task { if it.isDirectory { await session.open(it) } else { await feature.edit(it, in: session) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await session.upload(urls) }
            return true
        }
        .onDeleteCommand { deleting = session.selectedItems }
    }

    @ViewBuilder private func row(_ item: SFTPItem) -> some View {
        let r = HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : (item.isSymlink ? "link" : "doc"))
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text("\(item.isDirectory ? "" : SFTPFormat.size(item.size) + " · ")\(SFTPFormat.date(item.modified)) · \(item.permissionText)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if item.isDirectory {
            r.dropDestination(for: URL.self) { urls, _ in
                Task { await session.upload(urls, into: item.path) }
                return true
            }
        } else {
            r.draggable(RemoteDragFile(fetch: { [session] in try await session.exportForDrag(item) }))
        }
    }

    @ViewBuilder private func menu(for ids: Set<Data>) -> some View {
        let items = session.items.filter { ids.contains($0.id) }
        if items.isEmpty {
            Button("Nouveau dossier…") { newFolderText = ""; creating = true }
            Button("Envoyer des fichiers…") { chooseFilesToUpload() }
            Button("Actualiser") { Task { await session.refresh() } }
        } else {
            if items.count == 1, let it = items.first {
                if it.isDirectory {
                    Button("Ouvrir") { Task { await session.open(it) } }
                } else {
                    Button("Ouvrir avec l'éditeur") { Task { await feature.edit(it, in: session) } }
                }
            }
            Button("Télécharger dans Téléchargements") { Task { await session.downloadToDownloads(items) } }
            Button("Télécharger vers…") { chooseDownloadFolder(items) }
            if items.count == 1, let it = items.first {
                Button("Renommer…") { renameText = it.name; renaming = it }
            }
            Button("Copier le chemin") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map { SFTPPath.string($0.path) }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Supprimer…", role: .destructive) { deleting = items }
        }
    }

    private func chooseFilesToUpload() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Envoyer"
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        Task { await session.upload(urls) }
    }

    private func chooseDownloadFolder(_ items: [SFTPItem]) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Télécharger ici"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await session.download(items, to: url) }
    }
}

/// Transferts et éditions en cours (bas de l'inspecteur).
private struct SFTPActivityView: View {
    let feature: SFTPFeature
    @State private var expanded = true

    var body: some View {
        let queue = feature.transfers
        let edits = feature.edits.edits
        if !queue.items.isEmpty || !edits.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { expanded.toggle() } label: {
                        Label("Transferts (\(queue.activeCount) en cours)", systemImage: expanded ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).font(.subheadline.bold())
                    Spacer()
                    if queue.hasFinished { Button("Effacer les terminés") { queue.clearFinished() }.controlSize(.small) }
                }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(edits) { e in editRow(e) }
                            ForEach(queue.items) { t in transferRow(t, queue: queue) }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
            .padding(10)
        }
    }

    private func transferRow(_ t: SFTPTransfer, queue: SFTPTransferQueue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                Text(t.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch t.state {
                case .queued, .running:
                    Button { queue.cancel(t) } label: { Image(systemName: "xmark.circle") }.help("Annuler")
                case .failed, .cancelled:
                    Button { queue.retry(t) } label: { Image(systemName: "arrow.clockwise.circle") }.help("Réessayer")
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .buttonStyle(.borderless).font(.caption)
            switch t.state {
            case .running:
                ProgressView(value: t.fraction)
                Text("\(SFTPFormat.size(t.bytes)) sur \(SFTPFormat.size(t.total)) \(SFTPFormat.speed(t.speed))")
                    .font(.caption2).foregroundStyle(.secondary)
            case .queued: Text("En attente").font(.caption2).foregroundStyle(.secondary)
            case .failed(let m): Text(m).font(.caption2).foregroundStyle(.red)
            case .cancelled: Text("Annulé").font(.caption2).foregroundStyle(.secondary)
            case .done: Text(SFTPFormat.size(t.total)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func editRow(_ e: SFTPEdit) -> some View {
        HStack {
            Image(systemName: "pencil.circle")
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).lineLimit(1).font(.caption)
                Text(status(e)).font(.caption2).foregroundStyle(e.state.isProblem ? .red : .secondary)
            }
            Spacer()
            if e.state.isProblem { Button("Renvoyer") { feature.edits.resend(e) }.controlSize(.small) }
            Button("Terminer") { feature.edits.stop(e) }.controlSize(.small)
        }
    }

    private func status(_ e: SFTPEdit) -> String {
        switch e.state {
        case .watching: e.uploads == 0 ? "Surveillé — enregistrez pour envoyer" : "Envoyé \(e.uploads) fois"
        case .uploading: "Envoi…"
        case .conflict: "Conflit : version distante conservée"
        case .failed(let m): m
        case .stopped: "Arrêté"
        }
    }
}

private extension SFTPEdit.State {
    var isProblem: Bool { switch self { case .conflict, .failed: true; default: false } }
}
