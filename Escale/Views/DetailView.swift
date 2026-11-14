import SwiftUI
import AppKit

/// Zone de détail : barre d'onglets, panneaux de terminaux (tous gardés vivants), page d'accueil, barre d'état.
struct DetailView: View {
    let model: AppModel

    var body: some View {
        let ws = model.workspace
        // Lecture explicite de tout ce qui change la mise en page : SwiftUI relance alors `PaneHost.updateNSView`.
        let snapshot = ws.tabs.map { t in
            PaneHostTab(tab: t, layout: t.layout,
                        bannerIDs: Set(t.panes.filter { $0.bannerMessage != nil }.map(\.id)),
                        monitorIDs: Set(t.panes.map(\.id).filter { model.monitoring.monitors[$0] != nil }))
        }
        let home = ws.tabs.isEmpty || ws.showsHome
        VStack(spacing: 0) {
            if !ws.tabs.isEmpty {
                TabBarView(model: model)
                Divider()
            }
            ZStack {
                PaneHost(model: model, tabs: snapshot, activeID: ws.activeID)
                    .opacity(home ? 0 : 1)
                    .allowsHitTesting(!home)
                    .accessibilityHidden(home)
                if home { HomeView(model: model) }
            }
            StatusBarView(model: model)
        }
        // Retour de l'accueil vers un onglet : le panneau actif reprend le clavier (l'onglet actif n'a pas changé,
        // `PaneHostView` ne le refait donc pas de lui-même).
        .onChange(of: ws.showsHome) { _, shown in if !shown { model.focusActivePane() } }
    }
}
