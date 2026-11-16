import SwiftUI
import AppKit
import EscaleCore

/// Page d'accueil (l'onglet « Home » de MobaXterm) : connexion rapide, actions de départ, sessions récentes.
/// Affichée quand aucun onglet n'est ouvert, ou à la demande par le bouton maison de la barre d'onglets.
struct HomeView: View {
    @Bindable var model: AppModel
    @State private var target = ""
    @State private var rejected = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                quickConnect
                actions
                recents
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Escale").font(.system(size: 26, weight: .semibold))
                Text("Sessions SSH, fichiers distants, tunnels et multi-exécution").foregroundStyle(.secondary)
            }
        }
    }

    private var quickConnect: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.tint)
                TextField("Connexion rapide", text: $target, prompt: Text("utilisateur@hôte:port"))
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: .monospaced))
                    .disableAutocorrection(true)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: target) { _, _ in rejected = false }
                    .accessibilityIdentifier("home.quickconnect")
                Button("Connecter", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(rejected ? AnyShapeStyle(.red) : AnyShapeStyle(.separator)))
            Text(rejected ? "Cible non reconnue. Format attendu : utilisateur@hôte:port (utilisateur et port facultatifs)."
                          : "Ouvre une session SSH et l'enregistre dans la bibliothèque. ⇧⌘K depuis n'importe où.")
                .font(.caption).foregroundStyle(rejected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }

    private func submit() {
        if model.quickConnect(target) { target = "" } else { rejected = true }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            HomeAction(title: "Nouvelle session", symbol: "plus.rectangle.on.rectangle") { model.editor = .newHost(folder: nil) }
            HomeAction(title: "Terminal local", symbol: "terminal") { model.openLocalTab() }
            HomeAction(title: "Importer", symbol: "square.and.arrow.down") { model.sidebarTab = .tools }
            HomeAction(title: "Tunnels", symbol: "arrow.left.arrow.right") { model.tunnels.show() }
        }
    }

    private var recents: some View {
        let list = model.recentHosts
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sessions récentes").font(.headline)
                Spacer()
                if !list.isEmpty {
                    Button("Effacer") { model.clearRecents() }.buttonStyle(.link).font(.caption)
                }
            }
            if list.isEmpty {
                Text("Les sessions que vous ouvrez apparaîtront ici.").foregroundStyle(.secondary).font(.callout)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.host.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 38) }
                        RecentRow(model: model, host: entry.host, date: entry.date)
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}

private struct HomeAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.tint).frame(height: 24)
                Text(title).font(.callout).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(hovered ? 0.8 : 0.4), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct RecentRow: View {
    let model: AppModel
    let host: HostProfile
    let date: Date
    @State private var hovered = false

    var body: some View {
        Button { model.connect(host) } label: {
            HStack(spacing: 10) {
                Image(systemName: host.connectionProtocol.symbolName).foregroundStyle(host.connectionProtocol.tint).frame(width: 18)
                Text(host.name).lineLimit(1)
                if host.name != host.target {
                    Text(host.target).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                ConnectionDot(state: model.connections.state(of: host.id))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Connecter") { model.connect(host) }
            if host.connectionProtocol.isTerminal { Button("Nouvel onglet") { model.newTab(host) } }
            Button("Modifier…") { model.editor = .editHost(host) }
        }
        .accessibilityLabel("\(host.name), \(host.connectionProtocol.displayName)")
    }
}
