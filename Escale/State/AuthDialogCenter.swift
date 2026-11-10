import AppKit
import Foundation
import Observation
import EscaleCore

/// Une demande d'authentification affichée à l'utilisateur.
struct AuthDialog: Identifiable, Equatable {
    let id: UUID
    let hostID: UUID
    let hostName: String
    let request: AskpassRequest
    /// Vrai si la case « Mémoriser dans le Trousseau » a un effet (mot de passe d'un hôte « Trousseau », phrase de passe).
    let canRemember: Bool
}

/// File des dialogues d'authentification : plusieurs hôtes peuvent demander en même temps,
/// mais un seul dialogue est affiché à la fois (les autres attendent leur tour, dans l'ordre d'arrivée).
@MainActor
@Observable
final class AuthDialogCenter {
    /// Dialogue actuellement affiché (nil : aucun).
    private(set) var current: AuthDialog?
    /// Dialogues en attente derrière `current`.
    private(set) var queue: [AuthDialog] = []

    /// Délai entre la fermeture d'une feuille et l'ouverture de la suivante (laisse SwiftUI finir l'animation).
    @ObservationIgnored var handoverDelay: Duration = .milliseconds(350)
    /// Fait rebondir l'icône du Dock quand un dialogue apparaît alors que l'app est en arrière-plan (jamais d'activation).
    @ObservationIgnored var requestsAttention = true

    /// Journal pour les tests : dialogues dans l'ordre où ils ont été affichés.
    @ObservationIgnored private(set) var presentedLog: [AuthDialog] = []

    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<AskpassDecision, Never>] = [:]
    @ObservationIgnored private var handover: Task<Void, Never>?

    var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }

    /// Met la demande en file et attend la décision de l'utilisateur. Une annulation de la tâche appelante
    /// (délai du serveur askpass, arrêt de la connexion) retire la demande et répond « annuler ».
    func present(request: AskpassRequest, hostID: UUID, hostName: String, canRemember: Bool) async -> AskpassDecision {
        let dialog = AuthDialog(id: UUID(), hostID: hostID, hostName: hostName, request: request, canRemember: canRemember)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<AskpassDecision, Never>) in
                if Task.isCancelled { c.resume(returning: .cancel); return }
                continuations[dialog.id] = c
                queue.append(dialog)
                advance()
            }
        } onCancel: {
            Task { @MainActor in self.resolve(dialog.id, .cancel) }
        }
    }

    /// Réponse de l'utilisateur (ou d'un test) pour un dialogue affiché ou en attente.
    func resolve(_ id: UUID, _ decision: AskpassDecision) {
        guard let c = continuations.removeValue(forKey: id) else { return }
        if current?.id == id {
            current = nil
            scheduleHandover()
        } else {
            queue.removeAll { $0.id == id }
        }
        c.resume(returning: decision)
    }

    /// Annule tous les dialogues d'un hôte (connexion abandonnée).
    func cancelAll(forHost hostID: UUID) {
        let ids = ([current].compactMap { $0 } + queue).filter { $0.hostID == hostID }.map(\.id)
        for id in ids { resolve(id, .cancel) }
    }

    private func scheduleHandover() {
        guard !queue.isEmpty else { return }
        handoverPending = true
        let delay = handoverDelay
        handover = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.handoverPending = false
            self.advance()
        }
    }

    private func advance() {
        guard current == nil, !queue.isEmpty, !handoverPending else { return }
        let next = queue.removeFirst()
        current = next
        presentedLog.append(next)
        if requestsAttention, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    @ObservationIgnored private var handoverPending = false
}
