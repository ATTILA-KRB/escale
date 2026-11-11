import Foundation

/// Limites d'une exécution groupée.
public struct GroupExecLimits: Sendable, Equatable {
    public var timeout: TimeInterval
    public var maxOutputBytes: Int
    /// Nombre maximal d'hôtes traités en même temps.
    public var maxConcurrent: Int
    public init(timeout: TimeInterval = 60, maxOutputBytes: Int = 64 * 1024, maxConcurrent: Int = 16) {
        self.timeout = timeout; self.maxOutputBytes = maxOutputBytes; self.maxConcurrent = max(1, maxConcurrent)
    }
}

/// Un hôte visé par une exécution groupée. `execute` fait tout le travail pour cet hôte (connexion éventuelle
/// puis commande) ; il ne doit pas lever d'erreur : un échec se rend par `RemoteExecResult.failure`.
public struct GroupExecTarget: Sendable {
    public var id: UUID
    public var name: String
    /// Commande propre à cet hôte (remplace la commande commune).
    public var command: String?
    public var execute: @Sendable (_ command: String, _ limits: GroupExecLimits) async -> RemoteExecResult

    public init(
        id: UUID = UUID(), name: String, command: String? = nil,
        execute: @escaping @Sendable (String, GroupExecLimits) async -> RemoteExecResult
    ) {
        self.id = id; self.name = name; self.command = command; self.execute = execute
    }

    /// Cible adossée à un transport déjà connecté.
    public static func transport(_ t: OpenSSHTransport, id: UUID = UUID(), name: String, command: String? = nil) -> GroupExecTarget {
        GroupExecTarget(id: id, name: name, command: command) { cmd, limits in
            do { return try await t.exec(cmd, timeout: limits.timeout, maxOutputBytes: limits.maxOutputBytes) }
            catch SSHTransportError.notConnected { return RemoteExecResult(failure: "connexion non établie") }
            catch SSHTransportError.sessionRefused(let m) { return RemoteExecResult(failure: "session refusée : \(m)") }
            catch { return RemoteExecResult(failure: "\(error)") }
        }
    }
}

public enum GroupExecEvent: Sendable, Equatable {
    case started
    case finished(RemoteExecResult)
}

/// Exécution parallèle d'une même commande (ou d'une commande propre à chaque hôte) sur plusieurs hôtes.
public enum GroupExec {
    /// Retourne les résultats par identifiant de cible. `onEvent` est appelé depuis des tâches concurrentes.
    /// L'annulation de la tâche appelante interrompt les commandes en cours (leur résultat porte l'échec « annulé »).
    @discardableResult
    public static func run(
        command: String, targets: [GroupExecTarget], limits: GroupExecLimits = GroupExecLimits(),
        onEvent: @escaping @Sendable (UUID, GroupExecEvent) -> Void = { _, _ in }
    ) async -> [UUID: RemoteExecResult] {
        await withTaskGroup(of: (UUID, RemoteExecResult).self) { group in
            var results: [UUID: RemoteExecResult] = [:]
            var next = 0, running = 0
            func launch() {
                while running < limits.maxConcurrent, next < targets.count {
                    let t = targets[next]; next += 1; running += 1
                    group.addTask {
                        if Task.isCancelled { return (t.id, RemoteExecResult(failure: "annulé")) }
                        onEvent(t.id, .started)
                        let r = await t.execute(t.command ?? command, limits)
                        onEvent(t.id, .finished(r))
                        return (t.id, r)
                    }
                }
            }
            launch()
            while let (id, r) = await group.next() {
                running -= 1
                results[id] = r
                launch()
            }
            return results
        }
    }
}

/// Mise en forme du texte copié (presse-papiers) pour les résultats groupés.
public enum GroupExecReport {
    public static func text(command: String, entries: [(name: String, result: RemoteExecResult)]) -> String {
        var out = "$ \(command)\n"
        for e in entries {
            let r = e.result
            out += "\n=== \(e.name) — \(r.summary) (\(String(format: "%.1f", r.duration)) s) ===\n"
            if !r.stdout.isEmpty { out += r.stdout.hasSuffix("\n") ? r.stdout : r.stdout + "\n" }
            if r.stdoutTruncated { out += "[sortie standard tronquée]\n" }
            if !r.stderr.isEmpty { out += "--- stderr ---\n" + (r.stderr.hasSuffix("\n") ? r.stderr : r.stderr + "\n") }
            if r.stderrTruncated { out += "[erreur standard tronquée]\n" }
        }
        return out
    }
}
