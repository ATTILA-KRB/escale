import Foundation

/// Table de touches : keysyms X11 (RFB KeyEvent). La saisie suit les caractères PRODUITS par le clavier local
/// (AZERTY, Option…), pas les positions physiques : le serveur retrouve lui-même la touche qui porte ce keysym.
public enum RFBKeysym {
    public static let shiftL: UInt32 = 0xffe1, shiftR: UInt32 = 0xffe2
    public static let controlL: UInt32 = 0xffe3, controlR: UInt32 = 0xffe4
    public static let capsLock: UInt32 = 0xffe5
    public static let altL: UInt32 = 0xffe9, altR: UInt32 = 0xffea
    public static let superL: UInt32 = 0xffeb, superR: UInt32 = 0xffec
    public static let delete: UInt32 = 0xffff
    public static let backSpace: UInt32 = 0xff08
    public static let returnKey: UInt32 = 0xff0d

    /// Keysym d'un caractère Unicode : Latin-1 tel quel, sinon forme « Unicode » 0x01000000 + point de code.
    /// Nil pour les caractères de contrôle et les points de code privés de macOS (touches de fonction 0xF700…).
    public static func keysym(forScalar v: UInt32) -> UInt32? {
        switch v {
        case 0x20...0x7e, 0xa0...0xff: return v
        case 0..<0x20, 0x7f...0x9f: return nil
        case 0xf700...0xf8ff: return nil
        case 0x100...0x10ffff: return 0x0100_0000 + v
        default: return nil
        }
    }

    /// Touches non imprimables d'un clavier Mac, par code de touche virtuel.
    public static let specialKeys: [UInt16: UInt32] = [
        36: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b, 117: 0xffff, 114: 0xff63,
        123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1, 96: 0xffc2, 97: 0xffc3, 98: 0xffc4, 100: 0xffc5,
        101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9, 105: 0xffca, 107: 0xffcb, 113: 0xffcc, 106: 0xffcd,
        76: 0xff8d, 71: 0xff7f,
    ]

    /// Pavé numérique (chiffres et opérateurs) : keysyms KP_*.
    public static let keypadKeys: [UInt16: UInt32] = [
        82: 0xffb0, 83: 0xffb1, 84: 0xffb2, 85: 0xffb3, 86: 0xffb4, 87: 0xffb5, 88: 0xffb6, 89: 0xffb7, 91: 0xffb8, 92: 0xffb9,
        65: 0xffae, 67: 0xffaa, 69: 0xffab, 78: 0xffad, 75: 0xffaf, 81: 0xffbd,
    ]

    /// Modificateurs par code de touche virtuel (événements `flagsChanged`).
    public static let modifierKeys: [UInt16: UInt32] = [
        56: shiftL, 60: shiftR, 59: controlL, 62: controlR, 58: altL, 61: altR, 55: superL, 54: superR, 57: capsLock,
    ]

    /// Keysym d'une frappe. `characters` : texte produit (Maj, Option compris) ; `base` : texte sans modificateurs.
    /// Avec Ctrl/Cmd, le texte produit est un caractère de contrôle ou inutile : on envoie la lettre de base.
    public static func keysym(keyCode: UInt16, characters: String?, base: String?, controlOrCommand: Bool) -> UInt32? {
        if let k = specialKeys[keyCode] ?? keypadKeys[keyCode] { return k }
        let text = controlOrCommand ? (base ?? characters) : (characters ?? base)
        guard let scalar = text?.unicodeScalars.first else { return nil }
        return keysym(forScalar: scalar.value)
    }
}
