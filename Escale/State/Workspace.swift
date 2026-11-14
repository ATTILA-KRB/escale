import Foundation
import Observation

/// Liste ordonnée des onglets et onglet actif.
/// `tabs` contient TOUS les onglets, y compris ceux détachés dans leur propre fenêtre (`TerminalTab.windowID`) :
/// compteurs, multi-exécution, macros et SFTP les voient donc sans cas particulier. `mainTabs`, `activeID`,
/// `activeTab` et la navigation ne concernent que la fenêtre principale.
@MainActor
@Observable
final class Workspace {
    private(set) var tabs: [TerminalTab] = []
    private(set) var activeID: UUID?
    /// Page d'accueil affichée par-dessus les onglets (toujours visible quand il n'y a aucun onglet).
    /// Choisir ou ouvrir un onglet la referme.
    var showsHome = false

    var activeTab: TerminalTab? { tabs.first { $0.id == activeID } }

    /// Onglets de la fenêtre principale (hors onglets détachés).
    var mainTabs: [TerminalTab] { tabs.filter { $0.windowID == nil } }
    /// Onglets détachés dans la fenêtre `windowID`.
    func tabs(inWindow windowID: UUID) -> [TerminalTab] { tabs.filter { $0.windowID == windowID } }
    /// Appelé quand on « sélectionne » un onglet détaché : la fenêtre concernée passe devant (renseigné par `AppModel`).
    @ObservationIgnored var revealDetached: ((TerminalTab) -> Void)?

    func add(_ tab: TerminalTab, activate: Bool = true) {
        tabs.append(tab)
        if activate || activeID == nil { activeID = tab.id; showsHome = false }
    }

    /// Retire l'onglet ; l'activation passe au voisin de droite, sinon de gauche.
    func remove(_ tab: TerminalTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        if activeID == tab.id { activeID = mainNeighbour(at: i) }
        if mainTabs.isEmpty { showsHome = false }
    }

    /// Onglet principal le plus proche de l'indice `i` : voisin de droite, sinon de gauche.
    private func mainNeighbour(at i: Int) -> UUID? {
        let k = min(i, tabs.count)
        return (tabs[k...].first { $0.windowID == nil } ?? tabs[..<k].last { $0.windowID == nil })?.id
    }

    /// Détache l'onglet dans la fenêtre `windowID` (le moteur et le pty ne sont pas touchés).
    /// L'activation de la fenêtre principale passe à un voisin.
    func detach(_ tab: TerminalTab, window windowID: UUID) {
        guard tab.windowID == nil, let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.windowID = windowID
        if activeID == tab.id { activeID = mainNeighbour(at: i + 1) }
        if mainTabs.isEmpty { showsHome = false }
    }

    /// Rattache l'onglet à la fenêtre principale, en fin de barre, et l'active.
    func reattach(_ tab: TerminalTab) {
        guard tab.windowID != nil, let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        tab.windowID = nil
        tabs.append(tab)
        activeID = tab.id
        showsHome = false
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.windowID != nil { revealDetached?(tab); return }
        activeID = id; showsHome = false
    }
    func select(index: Int) { let m = mainTabs; if m.indices.contains(index) { select(m[index].id) } }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }
    private func step(_ d: Int) {
        let m = mainTabs
        guard !m.isEmpty else { return }
        let cur = m.firstIndex { $0.id == activeID } ?? 0
        activeID = m[(cur + d + m.count) % m.count].id
        showsHome = false
    }

    /// Déplace `id` juste avant `target` (ou à la fin si `target` est nil).
    func move(_ id: UUID, before target: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), id != target else { return }
        let tab = tabs.remove(at: from)
        let to = target.flatMap { t in tabs.firstIndex { $0.id == t } } ?? tabs.count
        tabs.insert(tab, at: to)
    }

    func tabs(forHost id: UUID) -> [TerminalTab] { tabs.filter { $0.hostID == id } }
}
