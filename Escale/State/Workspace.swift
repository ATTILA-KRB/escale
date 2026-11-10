import Foundation
import Observation

/// Liste ordonnée des onglets et onglet actif.
@MainActor
@Observable
final class Workspace {
    private(set) var tabs: [TerminalTab] = []
    private(set) var activeID: UUID?

    var activeTab: TerminalTab? { tabs.first { $0.id == activeID } }

    func add(_ tab: TerminalTab, activate: Bool = true) {
        tabs.append(tab)
        if activate || activeID == nil { activeID = tab.id }
    }

    /// Retire l'onglet ; l'activation passe au voisin de droite, sinon de gauche.
    func remove(_ tab: TerminalTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        if activeID == tab.id { activeID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
    }

    func select(_ id: UUID) { if tabs.contains(where: { $0.id == id }) { activeID = id } }
    func select(index: Int) { if tabs.indices.contains(index) { activeID = tabs[index].id } }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }
    private func step(_ d: Int) {
        guard !tabs.isEmpty else { return }
        let cur = tabs.firstIndex { $0.id == activeID } ?? 0
        activeID = tabs[(cur + d + tabs.count) % tabs.count].id
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
