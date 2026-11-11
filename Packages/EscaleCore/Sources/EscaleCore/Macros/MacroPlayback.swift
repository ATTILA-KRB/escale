import Foundation

/// Action élémentaire d'une lecture : envoyer des octets, ou attendre.
public enum MacroAction: Equatable, Sendable {
    case send(Data)
    case wait(milliseconds: Int)
}

/// Encodage des étapes en octets (pur, testable) et lecteur asynchrone.
public enum MacroPlayback {
    /// `\n` et `\r\n` deviennent un retour chariot, ce qu'envoie la touche Entrée d'un terminal.
    public static func bytes(forText text: String) -> Data {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        return Data(normalized.utf8)
    }

    /// Actions d'une macro, étapes vides ignorées et attentes bornées.
    public static func actions(for macro: Macro) -> [MacroAction] {
        macro.steps.compactMap { step in
            switch step {
            case .text(let t):
                let d = bytes(forText: t)
                return d.isEmpty ? nil : .send(d)
            case .key(let k): return .send(Data(k.bytes))
            case .wait(let ms):
                let clamped = min(max(ms, 0), Macro.maxWaitMilliseconds)
                return clamped == 0 ? nil : .wait(milliseconds: clamped)
            }
        }
    }

    /// Joue la macro : `send` reçoit les octets, `sleep` attend (injectable pour les tests).
    /// S'arrête dès que la tâche est annulée ; renvoie le nombre d'actions exécutées.
    @discardableResult
    public static func play(
        _ macro: Macro,
        send: @MainActor @Sendable (Data) -> Void,
        sleep: @Sendable (Int) async -> Void = { ms in try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
    ) async -> Int {
        var done = 0
        for action in actions(for: macro) {
            if Task.isCancelled { break }
            switch action {
            case .send(let d): await send(d)
            case .wait(let ms): await sleep(ms)
            }
            done += 1
        }
        return done
    }
}
