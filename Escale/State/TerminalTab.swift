import Foundation
import Observation
import EscaleCore

/// Un onglet : un moteur de terminal (via `session`) + le processus pty courant.
@MainActor
@Observable
final class TerminalTab: Identifiable {
    enum Kind: Equatable {
        case local(command: [String]?)
        case host(HostProfile)
    }
    enum Status: Equatable {
        case connecting
        case running
        case reconnecting
        case ended(PTYExitStatus)
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let baseTitle: String
    let session: TerminalSession
    var status: Status = .connecting
    /// Connexion maître qui porte ce shell (onglets SSH uniquement).
    var link: SSHLink?
    var isClosing = false
    /// Époque de la connexion au lancement du shell courant (voir `SSHLink.epoch`).
    @ObservationIgnored var launchEpoch = 0
    @ObservationIgnored var startTask: Task<Void, Never>?

    init(kind: Kind, baseTitle: String, session: TerminalSession = TerminalSession()) {
        self.kind = kind; self.baseTitle = baseTitle; self.session = session
    }

    var hostID: UUID? { if case .host(let h) = kind { h.id } else { nil } }
    var isRemote: Bool { hostID != nil }
    var displayTitle: String { session.title.isEmpty ? baseTitle : session.title }

    /// Message du bandeau non modal ; nil quand l'onglet fonctionne normalement.
    var bannerMessage: String? {
        switch status {
        case .running: return nil
        case .connecting: return "Connexion à \(baseTitle)…"
        case .failed(let m): return "Échec de la connexion : \(m)"
        case .ended: return session.statusText
        case .reconnecting:
            if case .reconnecting(let attempt, let retryIn)? = link?.state {
                if let s = retryIn { return "Connexion perdue — nouvelle tentative dans \(s) s" }
                return "Connexion perdue — reconnexion en cours (tentative \(attempt))…"
            }
            return "Connexion perdue — reconnexion…"
        }
    }
}
