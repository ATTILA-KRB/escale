import SwiftUI
import AppKit

/// Zone de détail : barre d'onglets, panneaux de terminaux (tous gardés vivants), état vide.
struct DetailView: View {
    let model: AppModel

    var body: some View {
        let ws = model.workspace
        // Lecture explicite de tout ce qui change la mise en page : SwiftUI relance alors `PaneHost.updateNSView`.
        let snapshot = ws.tabs.map { t in
            PaneHostTab(tab: t, layout: t.layout,
                        bannerIDs: Set(t.panes.filter { $0.bannerMessage != nil }.map(\.id)))
        }
        VStack(spacing: 0) {
            if !ws.tabs.isEmpty {
                TabBarView(model: model)
                Divider()
            }
            ZStack {
                PaneHost(model: model, tabs: snapshot, activeID: ws.activeID)
                    .opacity(ws.tabs.isEmpty ? 0 : 1)
                if ws.tabs.isEmpty { EmptyStateView(model: model) }
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
