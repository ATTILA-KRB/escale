import SwiftUI
import AppKit

/// Zone de détail : barre d'onglets, panneaux de terminaux (tous gardés vivants), page d'accueil, barre d'état.
struct DetailView: View {
    let model: AppModel

    var body: some View {
        let ws = model.workspace
        // Lecture explicite de tout ce qui change la mise en page : SwiftUI relance alors `PaneHost.updateNSView`.
        // Onglets de la fenêtre principale seulement : les onglets détachés sont hébergés par leur fenêtre.
        let mainTabs = ws.mainTabs
        let snapshot = mainTabs.map { t in
            PaneHostTab(tab: t, layout: t.layout,
                        bannerIDs: Set(t.panes.filter { $0.bannerMessage != nil }.map(\.id)))
        }
        let home = mainTabs.isEmpty || ws.showsHome
        VStack(spacing: 0) {
            if !mainTabs.isEmpty {
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
