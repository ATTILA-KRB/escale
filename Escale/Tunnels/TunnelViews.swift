import AppKit
import SwiftUI
import EscaleCore

// MARK: - Éditeur (feuille d'édition d'hôte)

/// Section « Tunnels » de la feuille d'édition d'hôte (la liste est enregistrée avec l'hôte).
struct TunnelEditorSection: View {
    @Binding var tunnels: [TunnelSpec]
    @State private var editing: UUID?

    var body: some View {
        Section("Tunnels") {
            if tunnels.isEmpty {
                Text("Aucun tunnel. Un tunnel redirige un port à travers la connexion SSH de cet hôte.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($tunnels) { $t in
                TunnelEditorRow(tunnel: $t, isEditing: Binding(
                    get: { editing == t.id }, set: { editing = $0 ? t.id : nil }),
                    onDelete: { let id = t.id; tunnels.removeAll { $0.id == id } })
            }
            HStack {
                Menu("Ajouter un tunnel") {
                    Button("Local (-L) : un port d'ici vers un service distant") { add(.local) }
                    Button("Distant (-R) : un port du serveur vers un service d'ici") { add(.remote) }
                    Button("Dynamique (-D) : proxy SOCKS") { add(.dynamic) }
                }
                .fixedSize()
                Spacer()
            }
            ForEach(TunnelValidation.listErrors(tunnels), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
        }
    }

    private func add(_ kind: TunnelSpec.Kind) {
        let used = Set(tunnels.map(\.bindPort))
        var port = kind == .dynamic ? 1080 : 8080
        while used.contains(port) { port += 1 }
        let t = TunnelSpec(kind: kind, bindPort: port,
                           destinationHost: kind == .dynamic ? "" : "localhost", destinationPort: kind == .dynamic ? 0 : 80)
        tunnels.append(t)
        editing = t.id
    }
}

private struct TunnelEditorRow: View {
    @Binding var tunnel: TunnelSpec
    @Binding var isEditing: Bool
    let onDelete: () -> Void

    var body: some View {
        let errors = TunnelValidation.errors(tunnel)
        let warnings = TunnelValidation.warnings(tunnel)
        HStack(spacing: 8) {
            Image(systemName: errors.isEmpty ? (warnings.isEmpty ? tunnel.kind.symbol : "exclamationmark.triangle.fill") : "xmark.octagon.fill")
                .foregroundStyle(errors.isEmpty ? (warnings.isEmpty ? Color.secondary : .orange) : .red)
                .help((errors + warnings).joined(separator: "\n"))
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.name.isEmpty ? tunnel.summary : tunnel.name).lineLimit(1)
                if !tunnel.name.isEmpty { Text(tunnel.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if tunnel.autoStart { Text("auto").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule()) }
            Spacer()
            Button("Modifier…") { isEditing = true }
                .popover(isPresented: $isEditing, arrowEdge: .trailing) { TunnelEditForm(tunnel: $tunnel).padding(14).frame(width: 360) }
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .help("Supprimer ce tunnel").buttonStyle(.borderless)
        }
    }
}

private struct TunnelEditForm: View {
    @Binding var tunnel: TunnelSpec

    var body: some View {
        let errors = TunnelValidation.errors(tunnel)
        let warnings = TunnelValidation.warnings(tunnel)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Type", selection: $tunnel.kind) {
                Text("Local (-L)").tag(TunnelSpec.Kind.local)
                Text("Distant (-R)").tag(TunnelSpec.Kind.remote)
                Text("Dynamique SOCKS (-D)").tag(TunnelSpec.Kind.dynamic)
            }
            TextField("Nom", text: $tunnel.name, prompt: Text("Facultatif"))
            TextField(tunnel.kind == .remote ? "Écoute (serveur)" : "Écoute (ce Mac)", text: $tunnel.bindAddress, prompt: Text("127.0.0.1"))
                .disableAutocorrection(true)
            TextField("Port d'écoute", value: $tunnel.bindPort, format: .number.grouping(.never))
            if tunnel.kind != .dynamic {
                TextField(tunnel.kind == .remote ? "Destination (depuis ce Mac)" : "Destination (depuis le serveur)",
                          text: $tunnel.destinationHost, prompt: Text("localhost"))
                    .disableAutocorrection(true)
                TextField("Port de destination", value: $tunnel.destinationPort, format: .number.grouping(.never))
            }
            Toggle("Ouvrir à la connexion de l'hôte", isOn: $tunnel.autoStart)
            ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ForEach(warnings, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension TunnelSpec.Kind {
    /// Pictogramme SF Symbols du type de tunnel.
    var symbol: String {
        switch self {
        case .local: "arrow.right.circle"
        case .remote: "arrow.left.circle"
        case .dynamic: "network"
        }
    }

    var label: String {
        switch self {
        case .local: "Local"
        case .remote: "Distant"
        case .dynamic: "SOCKS"
        }
    }
}

// MARK: - Gestionnaire (⇧⌘T, menu d'hôte « Tunnels… »)

struct TunnelManagerView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var feature: TunnelFeature { model.tunnels }

    private var hosts: [HostProfile] {
        let all = model.library.library.hosts.filter { !$0.tunnels.isEmpty }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let f = feature.focusedHostID { return all.filter { $0.id == f } }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tunnels").font(.title2.bold())
                Spacer()
                if feature.focusedHostID != nil {
                    Button("Tous les hôtes") { feature.focusedHostID = nil }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            if hosts.isEmpty {
                ContentUnavailableView(
                    "Aucun tunnel",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Ajoutez des tunnels dans la fiche d'un hôte (Modifier l'hôte… → Tunnels)."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(hosts) { host in
                        Section {
                            ForEach(host.tunnels) { t in TunnelRow(model: model, host: host, tunnel: t) }
                        } header: { TunnelHostHeader(model: model, host: host) }
                    }
                }
            }
            Divider()
            HStack {
                Text("Un tunnel ouvert garde la connexion de l'hôte active.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 460)
    }
}

private struct TunnelHostHeader: View {
    let model: AppModel
    let host: HostProfile

    var body: some View {
        let state = model.connections.state(of: host.id)
        HStack(spacing: 6) {
            Text(host.name).font(.headline)
            Text(label(state)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if host.tunnels.contains(where: { model.tunnels.state(of: $0.id) != .stopped }) {
                Button("Tout arrêter") { Task { await model.tunnels.stopAll(on: host) } }.controlSize(.small)
            }
        }
    }

    private func label(_ s: SSHLink.State) -> String {
        switch s {
        case .connected: "connecté"
        case .connecting: "connexion…"
        case .reconnecting: "reconnexion…"
        default: "non connecté"
        }
    }
}

private struct TunnelRow: View {
    let model: AppModel
    let host: HostProfile
    let tunnel: TunnelSpec

    var body: some View {
        let state = model.tunnels.state(of: tunnel.id)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tunnel.kind.symbol).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tunnel.title).lineLimit(1)
                    if tunnel.autoStart { Text("auto").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                }
                if !tunnel.name.isEmpty { Text(tunnel.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if case .failed(let m) = state {
                    Text(m).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                ForEach(TunnelValidation.warnings(tunnel), id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            badge(state)
            Button { copy(tunnel.clientURL) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copier \(tunnel.clientURL)")
            Button(state.isActive || state == .opening ? "Arrêter" : "Démarrer") {
                Task {
                    if state.isActive { await model.tunnels.stop(tunnel, on: host) }
                    else { await model.tunnels.start(tunnel, on: host) }
                }
            }
            .disabled(state == .opening)
            .frame(minWidth: 72)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func badge(_ s: TunnelState) -> some View {
        switch s {
        case .stopped: Label("Arrêté", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .opening: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Ouverture…").font(.caption) }
        case .active: Label("Actif", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
        case .failed: Label("Échec", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
