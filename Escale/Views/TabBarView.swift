import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Barre d'onglets compacte : titre, pastille d'état, fermeture (bouton ou clic milieu), glisser pour réordonner.
struct TabBarView: View {
    let model: AppModel
    @State private var hovered: UUID?
    @State private var monitor: Any?

    var body: some View {
        let ws = model.workspace
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ws.tabs) { tab in
                        TabItem(tab: tab, isActive: tab.id == ws.activeID, isHovered: hovered == tab.id,
                                select: { ws.select(tab.id) }, close: { model.close(tab) })
                            .onHover { inside in
                                if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                            }
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                                ws.move(id, before: tab.id)
                                return true
                            }
                    }
                }
                .padding(.horizontal, 6)
            }
            Button { model.openLocalTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Nouveau terminal local (⌘T)")
                .accessibilityLabel("Nouveau terminal local")
                .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(.bar)
        .onAppear {
            // Clic milieu = fermer l'onglet survolé (SwiftUI n'expose pas ce bouton).
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
                guard event.buttonNumber == 2, let id = hovered, let tab = model.workspace.tabs.first(where: { $0.id == id }) else { return event }
                model.close(tab)
                return nil
            }
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
    }
}

private struct TabItem: View {
    static let width: CGFloat = 164
    let tab: TerminalTab
    let isActive: Bool
    let isHovered: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            indicator.frame(width: 12)
            Text(tab.displayTitle).lineLimit(1).truncationMode(.middle).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tab.panes.count > 1 {
                Text("\(tab.panes.count)").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("\(tab.panes.count) panneaux")
            }
            // Espace réservé identique sur tous les onglets ; visible au survol seulement.
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help("Fermer l'onglet")
            .accessibilityLabel("Fermer \(tab.displayTitle)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: Self.width)
        .background(isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var indicator: some View {
        if tab.isRemote {
            switch tab.status {
            case .running: Circle().fill(.green).frame(width: 7, height: 7)
            case .connecting, .reconnecting: Circle().fill(.orange).frame(width: 7, height: 7)
            case .failed: Circle().fill(.red).frame(width: 7, height: 7)
            case .ended: Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 7, height: 7)
            }
        } else {
            Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
