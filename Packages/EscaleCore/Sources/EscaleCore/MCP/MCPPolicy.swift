import Foundation

/// Niveau d'accès d'un agent IA (client MCP) à un hôte. Réglé hôte par hôte ; `none` par défaut.
public enum AgentAccess: String, Codable, Sendable, CaseIterable, Hashable {
    /// Hôte invisible pour les agents.
    case none
    /// Lecture : liste, terminal, fichiers, tunnels (sans rien modifier).
    case read
    /// Lecture libre ; chaque action (commande, saisie, écriture, tunnel) attend la confirmation de l'utilisateur.
    case confirm
    /// Lecture et actions sans confirmation (journalisées).
    case full

    public var allowsVisibility: Bool { self != .none }
}

/// Nature d'un outil : lecture seule ou action (mutation, exécution).
public enum MCPOperation: Sendable, Equatable {
    case read
    case action
}

/// Les messages destinés à l'agent (refus, erreurs d'outil) sont en anglais : valeurs de protocole, jamais localisées.
public enum MCPPolicyDecision: Sendable, Equatable {
    case allow
    case confirm
    case deny(String)
}

public enum MCPPolicy {
    public static func decide(_ op: MCPOperation, access: AgentAccess) -> MCPPolicyDecision {
        switch (op, access) {
        case (_, .none): .deny("agent access is disabled for this host")
        case (.read, _): .allow
        case (.action, .read): .deny("this host is read-only for agents")
        case (.action, .confirm): .confirm
        case (.action, .full): .allow
        }
    }
}
