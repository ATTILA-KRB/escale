import Foundation

/// Transforme le flux d'octets saisis par l'utilisateur en étapes de macro.
/// Chaque appel à `feed` correspond à une frappe (ou un collage) livrée par le terminal :
/// les séquences d'échappement y arrivent entières. Les pauses longues entre deux frappes deviennent des attentes.
public struct MacroRecorder: Sendable {
    /// Pause minimale (secondes) enregistrée comme attente.
    public var pauseThreshold: TimeInterval
    /// Pause maximale enregistrée (secondes).
    public var maxPause: TimeInterval

    public private(set) var steps: [MacroStep] = []
    private var pendingText = Data()
    private var lastInput: Date?

    public init(pauseThreshold: TimeInterval = 1.0, maxPause: TimeInterval = 60) {
        self.pauseThreshold = pauseThreshold; self.maxPause = maxPause
    }

    /// Étapes enregistrées jusqu'ici (le texte en attente est inclus).
    public var result: [MacroStep] {
        var r = self
        r.flushText()
        return r.steps
    }

    public var isEmpty: Bool { steps.isEmpty && pendingText.isEmpty }

    public mutating func feed(_ bytes: Data, at date: Date = Date()) {
        guard !bytes.isEmpty else { return }
        if let last = lastInput, date.timeIntervalSince(last) >= pauseThreshold, !isEmpty {
            flushText()
            let ms = Int((min(date.timeIntervalSince(last), maxPause) * 10).rounded()) * 100
            steps.append(.wait(milliseconds: ms))
        }
        lastInput = date
        let b = [UInt8](bytes)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x1b {
                if let (key, len) = Self.escapeKey(b, at: i) { flushText(); steps.append(.key(key)); i += len; continue }
                flushText(); steps.append(.key(.escape)); i += 1; continue
            }
            if c == 0x0d || c == 0x0a {
                // CRLF compte pour une seule fin de ligne.
                pendingText.append(0x0a)
                i += (c == 0x0d && i + 1 < b.count && b[i + 1] == 0x0a) ? 2 : 1
                continue
            }
            if let key = Self.singleByteKey(c) { flushText(); steps.append(.key(key)); i += 1; continue }
            pendingText.append(c)
            i += 1
        }
    }

    private mutating func flushText() {
        guard !pendingText.isEmpty else { return }
        let text = String(decoding: pendingText, as: UTF8.self)
        pendingText.removeAll()
        if case .text(let previous)? = steps.last {
            steps[steps.count - 1] = .text(previous + text)
        } else {
            steps.append(.text(text))
        }
    }

    private static func singleByteKey(_ c: UInt8) -> MacroKey? {
        switch c {
        case 0x09: .tab
        case 0x7f, 0x08: .backspace
        case 0x01: .ctrlA
        case 0x03: .ctrlC
        case 0x04: .ctrlD
        case 0x05: .ctrlE
        case 0x0b: .ctrlK
        case 0x0c: .ctrlL
        case 0x12: .ctrlR
        case 0x15: .ctrlU
        case 0x17: .ctrlW
        case 0x1a: .ctrlZ
        default: nil
        }
    }

    /// Séquence CSI/SS3 reconnue commençant à `i` (ESC déjà vu) : touche et longueur.
    private static func escapeKey(_ b: [UInt8], at i: Int) -> (MacroKey, Int)? {
        guard i + 2 < b.count, b[i + 1] == 0x5b || b[i + 1] == 0x4f else { return nil }
        switch b[i + 2] {
        case 0x41: return (.up, 3)
        case 0x42: return (.down, 3)
        case 0x43: return (.right, 3)
        case 0x44: return (.left, 3)
        case 0x48: return (.home, 3)
        case 0x46: return (.end, 3)
        case 0x33 where i + 3 < b.count && b[i + 3] == 0x7e: return (.delete, 4)
        case 0x35 where i + 3 < b.count && b[i + 3] == 0x7e: return (.pageUp, 4)
        case 0x36 where i + 3 < b.count && b[i + 3] == 0x7e: return (.pageDown, 4)
        default: return nil
        }
    }
}
