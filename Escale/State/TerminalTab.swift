import Foundation
import Observation
import EscaleCore

/// Un onglet : un arbre de panneaux (`PaneLayout`) dont chaque feuille est un `Pane`
/// (moteur de terminal + shell). Les propriétés `session`, `status`, `link`… reflètent le panneau actif
/// (ou le pire état), si bien qu'un onglet à un seul panneau se comporte comme avant.
@MainActor
@Observable
final class TerminalTab: Identifiable {
    typealias Kind = Pane.Kind
    typealias Status = Pane.Status

    let id = UUID()
    let baseTitle: String
    private(set) var layout: PaneLayout
    private var panesByID: [UUID: Pane]
    var isClosing = false
    /// Fenêtre détachée qui porte cet onglet ; nil dans la fenêtre principale. Seul changement : l'hébergement de la
    /// vue (moteur, pty et connexion ne bougent pas).
    var windowID: UUID?
    /// Dernière taille de la zone des panneaux (renseignée par la vue) : sert à la navigation directionnelle
    /// et aux bornes de redimensionnement.
    @ObservationIgnored var viewSize = CGSize(width: 1000, height: 600)

    init(kind: Kind, baseTitle: String, session: TerminalSession = TerminalSession()) {
        let p = Pane(kind: kind, baseTitle: baseTitle, session: session)
        self.baseTitle = baseTitle
        panesByID = [p.id: p]
        layout = PaneLayout(first: p.id)
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: viewSize) }

    // MARK: Panneaux

    /// Panneaux dans l'ordre de l'arbre (gauche→droite, haut→bas).
    var panes: [Pane] { layout.leafIDs.compactMap { panesByID[$0] } }
    var activePane: Pane { panesByID[layout.active] ?? panes[0] }
    func pane(_ id: UUID) -> Pane? { panesByID[id] }

    // MARK: Reflet du panneau actif / de l'ensemble

    var kind: Kind { activePane.kind }
    var session: TerminalSession { activePane.session }
    var link: SSHLink? { activePane.link }
    var hostID: UUID? { activePane.hostID }
    var isRemote: Bool { activePane.isRemote }
    var displayTitle: String { activePane.displayTitle }
    var bannerMessage: String? { activePane.bannerMessage }
    /// Pire état parmi les panneaux (échec > reconnexion > connexion > terminé > actif).
    var status: Status {
        panes.max { $0.status.severity < $1.status.severity }?.status ?? .running
    }

    // MARK: Opérations (le cycle de vie des shells est dans `AppModel`)

    /// Crée un panneau voisin du panneau actif (même hôte / même commande) ; il devient actif.
    func splitActive(_ axis: PaneAxis) -> Pane {
        let src = activePane
        let p = Pane(kind: src.kind, baseTitle: src.baseTitle)
        panesByID[p.id] = p
        layout.split(src.id, axis: axis, newID: p.id)
        return p
    }

    /// Retire un panneau de l'arbre ; faux s'il était le dernier (l'onglet doit alors être fermé).
    func removePane(_ id: UUID) -> Bool {
        guard layout.remove(id) else { return false }
        panesByID[id] = nil
        return true
    }

    func setActive(_ id: UUID) { if layout.contains(id), layout.active != id { layout.active = id } }
    func focusNext() { layout.focusNext() }
    func focusPrevious() { layout.focusPrevious() }
    @discardableResult func focus(_ dir: PaneDirection) -> Bool { layout.focus(dir, in: bounds) }
    func equalize() { layout.equalize() }
    @discardableResult func setRatio(_ splitID: UUID, _ ratio: Double) -> Bool { layout.setRatio(splitID, ratio, in: bounds) }
}
