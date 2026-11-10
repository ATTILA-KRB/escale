import SwiftUI
import AppKit

/// Zone de détail : barre d'onglets, terminaux (tous gardés vivants), bandeau d'état, état vide.
struct DetailView: View {
    let model: AppModel

    var body: some View {
        let ws = model.workspace
        VStack(spacing: 0) {
            if !ws.tabs.isEmpty {
                TabBarView(model: model)
                Divider()
            }
            ZStack(alignment: .top) {
                TerminalStack(tabs: ws.tabs, activeID: ws.activeID)
                    .opacity(ws.tabs.isEmpty ? 0 : 1)
                if ws.tabs.isEmpty {
                    EmptyStateView(model: model)
                } else if let tab = ws.activeTab, tab.bannerMessage != nil {
                    TabBanner(model: model, tab: tab)
                }
            }
        }
    }
}

private struct EmptyStateView: View {
    let model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label("Aucune session ouverte", systemImage: "terminal")
        } description: {
            Text("Double-cliquez sur un hôte dans la barre latérale ou ouvrez un terminal local.")
        } actions: {
            HStack {
                Button("Terminal local") { model.openLocalTab() }
                Button("Nouvel hôte…") { model.editor = .newHost(folder: nil) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Bandeau non modal en haut du terminal actif.
struct TabBanner: View {
    let model: AppModel
    let tab: TerminalTab

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.bannerMessage ?? "").lineLimit(2)
                if case .reconnecting = tab.status, let e = tab.link?.lastError {
                    Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch tab.status {
            case .reconnecting:
                Button("Reconnecter maintenant") { model.retry(tab) }
            case .failed:
                Button("Réessayer") { model.retry(tab) }
            case .ended:
                Button("Relancer") { model.retry(tab) }
            default:
                EmptyView()
            }
            Button(tab.status == .connecting ? "Annuler" : "Fermer") { model.close(tab) }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch tab.status {
        case .connecting: ProgressView().controlSize(.small)
        case .reconnecting: Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .ended: Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .running: EmptyView()
        }
    }
}

// MARK: - Terminaux

/// Héberge TOUTES les vues de moteur (une par onglet) : changer d'onglet ne fait que masquer/afficher,
/// le moteur (écran, scrollback) n'est jamais recréé. Donne le focus clavier au terminal actif.
struct TerminalStack: NSViewRepresentable {
    let tabs: [TerminalTab]
    let activeID: UUID?

    func makeNSView(context: Context) -> StackView { StackView() }

    func updateNSView(_ view: StackView, context: Context) {
        view.sync(engines: tabs.map { ($0.id, $0.session.engine) }, activeID: activeID)
    }

    final class StackView: NSView {
        private var engines: [UUID: SwiftTermEngine] = [:]
        private var lastActive: UUID?
        /// Marge intérieure : le texte ne colle pas aux bords ; le fond noir du terminal remplit la marge.
        static let insetX: CGFloat = 8
        static let insetY: CGFloat = 4

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

        func sync(engines list: [(UUID, SwiftTermEngine)], activeID: UUID?) {
            let ids = Set(list.map(\.0))
            for (id, e) in engines where !ids.contains(id) { e.view.removeFromSuperview(); engines[id] = nil }
            for (id, e) in list where engines[id] == nil {
                e.view.frame = bounds.insetBy(dx: Self.insetX, dy: Self.insetY)
                e.view.autoresizingMask = [.width, .height]
                addSubview(e.view)
                engines[id] = e
            }
            for (id, e) in list { e.view.isHidden = id != activeID }
            if activeID != lastActive {
                lastActive = activeID
                focusActive()
            }
        }

        private func focusActive() {
            // Après la fin du cycle de mise en place (la vue peut venir d'être insérée).
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let id = self.lastActive, let e = self.engines[id] else { return }
                    e.focus()
                    e.refreshDisplay()
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { focusActive() }
        }
    }
}
