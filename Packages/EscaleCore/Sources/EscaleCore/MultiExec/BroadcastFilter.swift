import Foundation

/// Distingue la saisie de l'utilisateur des réponses automatiques du terminal (rapports de position du
/// curseur, attributs du terminal, focus, souris, OSC) : celles-ci ne doivent JAMAIS être diffusées aux
/// autres panneaux (elles répondent à une question posée à un seul programme).
public enum BroadcastFilter {
    /// Vrai si `bytes` est une réponse/un rapport du terminal et non une frappe.
    public static func isTerminalReport(_ bytes: Data) -> Bool {
        let b = [UInt8](bytes)
        guard b.count >= 3, b[0] == 0x1b else { return false }
        switch b[1] {
        case 0x5d, 0x50:        // OSC (réponses de couleur, presse-papiers) ou DCS
            return true
        case 0x5b:              // CSI
            let rest = Array(b[2...])
            guard let final = rest.last else { return false }
            let body = rest.dropLast()
            // Focus entrant/sortant (ESC [ I / ESC [ O) : seulement sans paramètre.
            if body.isEmpty { return final == 0x49 || final == 0x4f }
            // Souris SGR (ESC [ < b ; x ; y M|m) et X10 (ESC [ M …).
            if body.first == 0x3c { return final == 0x4d || final == 0x6d }
            if body.isEmpty == false, rest.first == 0x4d, rest.count >= 4 { return true }
            // Réponses privées : DA (? … c / > … c), DECRQM (? … $ y), état (? … n).
            if body.first == 0x3f || body.first == 0x3e { return final == 0x63 || final == 0x79 || final == 0x6e }
            // Rapport de position du curseur : ESC [ ligne ; colonne R (ligne 1 = touche Maj+F3 : on la garde).
            if final == 0x52 {
                let s = String(decoding: body, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
                if s.count == 2, let row = Int(s[0]), Int(s[1]) != nil, row > 1 { return true }
            }
            return false
        default:
            return false
        }
    }
}
