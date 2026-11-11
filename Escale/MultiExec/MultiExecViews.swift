import SwiftUI
import AppKit
import EscaleCore

// MARK: - Commandes (menu « Multi-exécution »)

struct MultiExecCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandMenu("Multi-exécution") {
            let feature = model.multiExec
            Button(feature.isBroadcasting ? "Arrêter la diffusion de la saisie" : "Diffuser la saisie") { feature.toggleBroadcast() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Choisir les panneaux à diffuser…") { feature.openBroadcastSheet() }
                .disabled(model.workspace.tabs.isEmpty)
            Divider()
            Button("Exécuter une commande sur les hôtes connectés…") {
                let hosts = model.library.library.hosts.filter { model.connections.state(of: $0.id) == .connected }
                feature.beginGroupExec(hosts: hosts)
            }
        }
    }
}

// MARK: - Menu de la sélection multiple de la barre latérale

struct MultiExecSelectionMenuItems: View {
    let model: AppModel
    let hosts: [HostProfile]
    var body: some View {
        Button("Exécuter une commande sur \(hosts.count) hôtes…") { model.multiExec.beginGroupExec(hosts: hosts) }
            .disabled(hosts.isEmpty)
    }
}

// MARK: - Scène : bandeau de diffusion, résultats, feuilles

struct MultiExecScene: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let feature = model.multiExec
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if feature.isBroadcasting { BroadcastBanner(feature: feature) }
                    if let run = feature.execRun { ExecResultsPanel(feature: feature, run: run) }
                }
            }
            .sheet(isPresented: Binding(
                get: { feature.execDraft != nil },
                set: { if !$0 { feature.cancelGroupExecDraft() } })
            ) {
                if feature.execDraft != nil {
                    ExecSheet(feature: feature, draft: Binding(get: { feature.execDraft ?? .init(hosts: []) }, set: { feature.execDraft = $0 }))
                }
            }
            .sheet(isPresented: Binding(
                get: { feature.broadcastSheetOpen },
                set: { if !$0 { feature.closeBroadcastSheet() } })
            ) {
                BroadcastSheet(model: model, feature: feature)
            }
    }
}

/// Bandeau rouge tant que la saisie est diffusée (les panneaux concernés portent aussi une bordure rouge).
private struct BroadcastBanner: View {
    let feature: MultiExecFeature
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Diffusion de la saisie : ce que vous tapez est envoyé à \(feature.broadcastPaneIDs.count) panneaux")
                .fontWeight(.semibold)
            Spacer()
            Button("Choisir…") { feature.openBroadcastSheet() }.buttonStyle(.bordered).controlSize(.small)
            Button("Arrêter (⌥⌘I)") { feature.stopBroadcast() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(Color.red)
        .accessibilityIdentifier("multiexec-banner")
    }
}

/// Choix des panneaux à diffuser.
private struct BroadcastSheet: View {
    let model: AppModel
    let feature: MultiExecFeature
    @State private var mode = 0   // 0 onglet actif, 1 tous les onglets, 2 sélection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diffuser la saisie").font(.title3.bold())
            Picker("Cible", selection: $mode) {
                Text("Panneaux de l'onglet actif").tag(0)
                Text("Tous les onglets").tag(1)
                Text("Sélection").tag(2)
            }
            .pickerStyle(.radioGroup)
            if mode == 2 {
                List {
                    ForEach(model.workspace.tabs) { tab in
                        Section(tab.displayTitle) {
                            ForEach(tab.panes) { p in
                                Toggle(p.displayTitle, isOn: Binding(
                                    get: { feature.sheetSelection.contains(p.id) },
                                    set: { on in if on { feature.sheetSelection.insert(p.id) } else { feature.sheetSelection.remove(p.id) } }))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
            Text("La saisie d'un panneau du groupe est envoyée telle quelle (touches spéciales et collage compris) aux autres. Les panneaux concernés ont une bordure rouge.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = problem { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { feature.closeBroadcastSheet() }.keyboardShortcut(.cancelAction)
                Button("Diffuser") { start() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20).frame(width: 440)
    }

    private var scope: MultiExecFeature.BroadcastScope? {
        switch mode {
        case 0: model.workspace.activeTab.map { .tab($0.id) }
        case 1: .allTabs
        default: .panes(feature.sheetSelection)
        }
    }
    private var problem: String? {
        guard let s = scope else { return "Aucun onglet ouvert." }
        return feature.members(of: s).count < 2 ? "Il faut au moins deux panneaux." : nil
    }
    private func start() {
        guard let s = scope else { return }
        feature.closeBroadcastSheet()
        feature.startBroadcast(s)
    }
}

/// Feuille « Exécuter une commande… ».
private struct ExecSheet: View {
    let feature: MultiExecFeature
    @Binding var draft: MultiExecFeature.ExecDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exécuter une commande sur \(draft.hosts.count) hôtes").font(.title3.bold())
            Text(draft.hosts.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            TextField("Commande", text: $draft.command, axis: .vertical)
                .lineLimit(2...6).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("multiexec-command")
            Picker("Délai maximal", selection: $draft.timeout) {
                Text("10 s").tag(10.0); Text("30 s").tag(30.0); Text("1 min").tag(60.0); Text("5 min").tag(300.0)
            }
            .pickerStyle(.segmented)
            Text("Exécution non interactive (sans terminal) sur la connexion de chaque hôte ; les hôtes non connectés sont connectés d'abord.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { feature.cancelGroupExecDraft() }.keyboardShortcut(.cancelAction)
                Button("Exécuter") { feature.startGroupExec(command: draft.command, timeout: draft.timeout, hosts: draft.hosts) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}

/// Résultats par hôte : état, code de sortie, durée, sorties (tronquées), copier, relancer.
private struct ExecResultsPanel: View {
    let feature: MultiExecFeature
    let run: MultiExecFeature.ExecRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if run.isRunning { ProgressView().controlSize(.small) }
                Text("$ \(run.command)").font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(run.isRunning ? "\(run.finishedCount)/\(run.rows.count) terminés"
                     : run.failedCount == 0 ? "Tous réussis" : "\(run.failedCount) en échec")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Relancer") { feature.rerun() }.disabled(run.isRunning).controlSize(.small)
                Button("Copier tout") { feature.copy(feature.reportText(run)) }.disabled(run.isRunning).controlSize(.small)
                Button("Fermer") { feature.closeResults() }.disabled(run.isRunning).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(run.rows) { row in ExecRowView(feature: feature, row: row) }
                }
            }
            .frame(maxHeight: 240)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("multiexec-results")
    }
}

private struct ExecRowView: View {
    let feature: MultiExecFeature
    let row: MultiExecFeature.ExecRow
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12) }
                    .buttonStyle(.plain)
                icon
                Text(row.host.name).fontWeight(.medium)
                Text(statusText).foregroundStyle(.secondary).font(.caption)
                Spacer()
                if let r = row.result {
                    Text(String(format: "%.1f s", r.duration)).font(.caption).foregroundStyle(.secondary)
                    Button { feature.copy(GroupExecReport.text(command: "", entries: [(row.host.name, r)])) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copier le résultat de cet hôte")
                }
            }
            if expanded, let r = row.result {
                if !r.stdout.isEmpty { output(r.stdout + (r.stdoutTruncated ? "\n[tronquée]" : ""), error: false) }
                if !r.stderr.isEmpty { output(r.stderr + (r.stderrTruncated ? "\n[tronquée]" : ""), error: true) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func output(_ text: String, error: Bool) -> some View {
        Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(error ? Color.red : Color.primary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
    }

    @ViewBuilder private var icon: some View {
        switch row.phase {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .connecting, .running: ProgressView().controlSize(.mini)
        case .done:
            if row.result?.isSuccess == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
        }
    }

    private var statusText: String {
        switch row.phase {
        case .waiting: "en attente"
        case .connecting: "connexion…"
        case .running: "exécution…"
        case .done: row.result?.summary ?? ""
        }
    }
}
