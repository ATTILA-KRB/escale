import AppKit
import SwiftUI
import EscaleCore

// MARK: - Confirmation (panneau flottant, sans activer l'app)

/// Panneau flottant des confirmations : visible au-dessus des autres apps (l'utilisateur est souvent dans son
/// terminal ou son éditeur quand l'agent agit), sans prendre le focus, indépendant des feuilles de la fenêtre.
@MainActor
final class MCPConfirmationPanel {
    private unowned let feature: MCPFeature
    private var panel: NSPanel?

    init(feature: MCPFeature) { self.feature = feature }

    func update() {
        guard !feature.pending.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = String(localized: "Action d'un agent")
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: MCPConfirmationView(feature: feature))
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - 480, y: screen.maxY - 300))
        }
        return p
    }
}

struct MCPConfirmationView: View {
    let feature: MCPFeature

    var body: some View {
        if let c = feature.pending.first {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("\(c.client) demande : \(Self.title(c.tool))")
                        .font(.headline)
                } icon: { Image(systemName: "sparkles") }
                Text("Hôte : \(c.hostName)").foregroundStyle(.secondary)
                ScrollView {
                    Text(c.detail.isEmpty ? " " : c.detail)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 60, maxHeight: 140)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    if feature.pending.count > 1 {
                        Text("\(feature.pending.count - 1) autre(s) demande(s) en attente").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refuser") { feature.respond(c.id, approved: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Autoriser") { feature.respond(c.id, approved: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 460)
        }
    }

    static func title(_ t: MCPCatalog.Tool) -> String {
        switch t {
        case .exec: String(localized: "exécuter une commande")
        case .sendInput: String(localized: "saisir dans un terminal")
        case .writeFile: String(localized: "écrire un fichier")
        case .startTunnel: String(localized: "ouvrir un tunnel")
        case .stopTunnel: String(localized: "fermer un tunnel")
        case .readFile: String(localized: "lire un fichier")
        case .listFiles: String(localized: "lister un dossier")
        case .readTerminal: String(localized: "lire un terminal")
        case .listTunnels: String(localized: "lister les tunnels")
        case .listHosts: String(localized: "lister les hôtes")
        case .listSessions: String(localized: "lister les sessions")
        }
    }
}

// MARK: - Réglages et journal

struct MCPSettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var feature: MCPFeature { model.mcp }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accès des agents (MCP)").font(.title2.bold())
            Text("Escale expose ses hôtes aux agents IA (Claude Code, Hermes, Cursor…) par le protocole MCP, sur un socket local réservé à votre compte. Un agent n'utilise que les connexions que vous avez déjà ouvertes et seulement les hôtes dont l'accès est réglé dans leur fiche (onglet Avancé).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Autoriser l'accès des agents", isOn: Binding(get: { feature.isEnabled }, set: { feature.setEnabled($0) }))
                .toggleStyle(.switch)
            status

            GroupBox("Configuration du client") {
                VStack(alignment: .leading, spacing: 8) {
                    copyRow(String(localized: "Claude Code"), feature.claudeCodeCommand)
                    copyRow(String(localized: "JSON (Cursor, Claude Desktop, Hermes…)"), feature.jsonConfiguration)
                }
                .padding(4)
            }

            GroupBox("Hôtes exposés") {
                let hosts = feature.exposedHosts
                if hosts.isEmpty {
                    Text("Aucun hôte : réglez « Accès des agents » dans la fiche d'un hôte SSH.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hosts) { h in
                            HStack {
                                Text(h.name)
                                Spacer()
                                Text(AgentAccessEditorSection.label(h.agentAccess)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }
            }

            GroupBox {
                journal
            } label: {
                HStack {
                    Text("Journal")
                    Spacer()
                    Button("Effacer") { feature.clearJournal() }.disabled(feature.journal.isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 680)
    }

    @ViewBuilder private var status: some View {
        if let e = feature.serverError {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if feature.isRunning {
            Label(feature.clientCount == 0 ? String(localized: "En écoute, aucun agent connecté")
                  : String(localized: "\(feature.clientCount) agent(s) connecté(s)"), systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        } else {
            Label("Désactivé", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .controlSize(.small)
            }
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var journal: some View {
        List(feature.journal.reversed()) { e in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(e.date, style: .time).monospacedDigit()
                    Text(e.tool).font(.system(.body, design: .monospaced))
                    if let h = e.hostName { Text(h).foregroundStyle(.secondary) }
                    Spacer()
                    Text(Self.outcome(e.outcome)).foregroundStyle(Self.color(e.outcome))
                }
                if !e.summary.isEmpty {
                    Text(e.summary).font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                }
                Text(e.client).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 160)
    }

    static func outcome(_ o: MCPFeature.JournalEntry.Outcome) -> String {
        switch o {
        case .allowed: String(localized: "autorisé")
        case .approved: String(localized: "confirmé")
        case .refusedByUser: String(localized: "refusé")
        case .denied: String(localized: "interdit")
        case .failed(let m): String(localized: "échec : \(m)")
        }
    }

    static func color(_ o: MCPFeature.JournalEntry.Outcome) -> Color {
        switch o {
        case .allowed, .approved: .green
        case .refusedByUser, .denied: .orange
        case .failed: .red
        }
    }
}

// MARK: - Fiche d'hôte

/// Niveau d'accès des agents (onglet Avancé de la fiche d'un hôte SSH).
struct AgentAccessEditorSection: View {
    @Binding var access: AgentAccess

    var body: some View {
        Section {
            Picker("Accès des agents (MCP)", selection: $access) {
                ForEach(AgentAccess.allCases, id: \.self) { a in Text(Self.label(a)).tag(a) }
            }
            Text(Self.help(access)).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func label(_ a: AgentAccess) -> String {
        switch a {
        case .none: String(localized: "Aucun")
        case .read: String(localized: "Lecture seule")
        case .confirm: String(localized: "Actions avec confirmation")
        case .full: String(localized: "Actions sans confirmation")
        }
    }

    static func help(_ a: AgentAccess) -> String {
        switch a {
        case .none: String(localized: "Hôte invisible pour les agents IA.")
        case .read: String(localized: "Les agents lisent les terminaux, fichiers et tunnels, sans rien modifier.")
        case .confirm: String(localized: "Chaque commande, saisie, écriture ou tunnel attend votre accord.")
        case .full: String(localized: "Les agents agissent sans demander (actions journalisées). À réserver aux machines de test.")
        }
    }
}

// MARK: - Commandes et scène

struct MCPCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Accès des agents (MCP)…") { model.mcp.isSettingsPresented = true }
        }
    }
}

struct MCPScene: ViewModifier {
    let model: AppModel
    static let sheetID = "mcp"
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.mcp.isSettingsPresented }, set: { model.mcp.isSettingsPresented = $0 })) {
                MCPSettingsView(model: model)
            }
            .onChange(of: model.mcp.isSettingsPresented) { _, shown in
                if shown { model.activeFeatureSheet = Self.sheetID }
                else if model.activeFeatureSheet == Self.sheetID { model.activeFeatureSheet = nil }
            }
    }
}
