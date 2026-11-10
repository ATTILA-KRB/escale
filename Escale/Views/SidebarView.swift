import SwiftUI
import EscaleCore

/// Barre latérale : recherche, « Terminal local », arborescence dossiers/hôtes avec état de connexion.
struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<UUID> = []

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Terminal local", systemImage: "terminal").tag(AppModel.localTerminalID)
            }
            Section("Hôtes") {
                if searching {
                    let found = model.library.search(model.searchText)
                    if found.isEmpty {
                        Text("Aucun résultat").foregroundStyle(.secondary)
                    }
                    ForEach(found) { HostRow(model: model, host: $0).tag($0.id) }
                } else if model.library.tree.isEmpty {
                    Text("Aucun hôte enregistré").foregroundStyle(.secondary)
                } else {
                    TreeRows(model: model, nodes: model.library.tree)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Rechercher un hôte")
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-clic ou Entrée.
            for id in ids {
                if id == AppModel.localTerminalID { model.openLocalTab() }
                else if let h = model.library.host(id) { model.connect(h) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    Button("Nouvel hôte…") { model.editor = .newHost(folder: selectedFolder) }
                    Button("Nouveau dossier…") { model.editor = .newFolder(parent: selectedFolder) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ajouter un hôte ou un dossier")
                .accessibilityLabel("Ajouter")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var selectedFolder: UUID? {
        guard let id = selection.first, model.library.folder(id) != nil else { return nil }
        return id
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        if ids.isEmpty {
            Button("Nouvel hôte…") { model.editor = .newHost(folder: nil) }
            Button("Nouveau dossier…") { model.editor = .newFolder(parent: nil) }
        } else if ids == [AppModel.localTerminalID] {
            Button("Ouvrir un terminal local") { model.openLocalTab() }
        } else if ids.count == 1, let id = ids.first, let host = model.library.host(id) {
            Button("Connecter") { model.connect(host) }
            Button("Nouvel onglet") { model.newTab(host) }
            if model.connections.existing(host.id)?.tabCount ?? 0 > 0 {
                Button("Déconnecter") { model.disconnect(host) }
            }
            Divider()
            Button("Modifier…") { model.editor = .editHost(host) }
            Button("Dupliquer") { model.library.duplicateHost(host.id) }
            Menu("Déplacer vers") {
                Button("Racine") { model.library.moveHost(host.id, to: nil) }.disabled(host.folderID == nil)
                ForEach(model.library.allFolderPaths, id: \.id) { f in
                    Button(f.path) { model.library.moveHost(host.id, to: f.id) }.disabled(host.folderID == f.id)
                }
            }
            Divider()
            Button("Supprimer…", role: .destructive) { model.pendingDeletion = .host(host) }
        } else if ids.count == 1, let id = ids.first, let folder = model.library.folder(id) {
            Button("Nouvel hôte ici…") { model.editor = .newHost(folder: folder.id) }
            Button("Nouveau sous-dossier…") { model.editor = .newFolder(parent: folder.id) }
            Button("Renommer…") { model.editor = .renameFolder(folder) }
            Divider()
            Button("Supprimer…", role: .destructive) { model.pendingDeletion = .folder(folder) }
        } else {
            // Sélection multiple : seules les actions sans ambiguïté.
            let hosts = ids.compactMap { model.library.host($0) }
            Button("Connecter \(hosts.count) hôtes") { hosts.forEach { model.connect($0) } }.disabled(hosts.isEmpty)
        }
    }
}

/// Lignes récursives de l'arborescence (dossiers repliables).
private struct TreeRows: View {
    let model: AppModel
    let nodes: [SidebarNode]

    var body: some View {
        ForEach(nodes) { node in
            switch node.kind {
            case .folder(let f):
                DisclosureGroup(isExpanded: Binding(
                    get: { !model.collapsedFolders.contains(f.id) },
                    set: { open in
                        if open { model.collapsedFolders.remove(f.id) } else { model.collapsedFolders.insert(f.id) }
                    })
                ) {
                    TreeRows(model: model, nodes: node.children)
                } label: {
                    Label(f.name, systemImage: "folder")
                }
                .tag(f.id)
            case .host(let h):
                HostRow(model: model, host: h).tag(h.id)
            }
        }
    }
}

private struct HostRow: View {
    let model: AppModel
    let host: HostProfile

    var body: some View {
        let state = model.connections.state(of: host.id)
        HStack(spacing: 8) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).lineLimit(1)
                Text(host.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            ConnectionDot(state: state)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.name), \(ConnectionDot.label(state))")
    }
}

/// Pastille d'état de connexion (vide = déconnecté).
struct ConnectionDot: View {
    let state: SSHLink.State

    static func label(_ s: SSHLink.State) -> String {
        switch s {
        case .disconnected: "déconnecté"
        case .connecting: "connexion en cours"
        case .connected: "connecté"
        case .failed(let m): "échec : \(m)"
        case .reconnecting: "reconnexion en cours"
        }
    }

    var body: some View {
        switch state {
        case .disconnected:
            Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 8, height: 8).help("Déconnecté")
        case .connecting, .reconnecting:
            Circle().fill(.orange).frame(width: 8, height: 8).help(Self.label(state))
        case .connected:
            Circle().fill(.green).frame(width: 8, height: 8).help("Connecté")
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8).help(Self.label(state))
        }
    }
}
