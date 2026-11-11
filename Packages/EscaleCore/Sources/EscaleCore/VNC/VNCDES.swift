import Foundation

/// DES en Swift pur (FIPS 46-3), uniquement pour l'authentification « VNC Authentication » du protocole RFB :
/// le serveur envoie 16 octets aléatoires, le client les chiffre en DES-ECB avec le mot de passe comme clé.
/// Particularité VNC : chaque octet de la clé (8 premiers caractères du mot de passe, complétés par des zéros)
/// a ses bits inversés avant usage. Implémentation volontairement simple (bit à bit) : 16 octets par connexion.
public enum VNCDES {
    private static let ip: [UInt8] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
    private static let fp: [UInt8] = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
    private static let expansion: [UInt8] = [
        32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
        16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
    private static let permutation: [UInt8] = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
    private static let pc1: [UInt8] = [
        57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
    private static let pc2: [UInt8] = [
        14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
    private static let shifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let sboxes: [[UInt8]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]

    /// Bits d'un bloc de 8 octets (poids fort d'abord), un bit par élément.
    private static func bits(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(bytes.count * 8)
        for b in bytes { for i in (0..<8).reversed() { out.append((b >> UInt8(i)) & 1) } }
        return out
    }

    private static func bytes(_ bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count, by: 8).map { i in (0..<8).reduce(UInt8(0)) { ($0 << 1) | bits[i + $1] } }
    }

    private static func permute(_ input: [UInt8], _ table: [UInt8]) -> [UInt8] { table.map { input[Int($0) - 1] } }

    /// 16 sous-clés de 48 bits.
    static func subkeys(key: [UInt8]) -> [[UInt8]] {
        precondition(key.count == 8)
        let k = permute(bits(key), pc1)
        var c = Array(k[0..<28]), d = Array(k[28..<56])
        var out: [[UInt8]] = []
        for s in shifts {
            c = Array(c[s...] + c[..<s]); d = Array(d[s...] + d[..<s])
            out.append(permute(c + d, pc2))
        }
        return out
    }

    private static func feistel(_ r: [UInt8], _ k: [UInt8]) -> [UInt8] {
        let e = permute(r, expansion)
        var out: [UInt8] = []
        for box in 0..<8 {
            let o = box * 6
            let v = (0..<6).map { e[o + $0] ^ k[o + $0] }
            let row = Int(v[0] << 1 | v[5]), col = Int(v[1] << 3 | v[2] << 2 | v[3] << 1 | v[4])
            let s = sboxes[box][row * 16 + col]
            for i in (0..<4).reversed() { out.append((s >> UInt8(i)) & 1) }
        }
        return permute(out, permutation)
    }

    /// Chiffre (ou déchiffre) un bloc de 8 octets avec une clé DES de 8 octets (parité ignorée).
    public static func cryptBlock(_ block: [UInt8], key: [UInt8], decrypt: Bool = false) -> [UInt8] {
        precondition(block.count == 8 && key.count == 8)
        var keys = subkeys(key: key)
        if decrypt { keys.reverse() }
        let t = permute(bits(block), ip)
        var l = Array(t[0..<32]), r = Array(t[32..<64])
        for k in keys {
            let f = feistel(r, k)
            let nr = zip(l, f).map { $0 ^ $1 }
            l = r; r = nr
        }
        return bytes(permute(r + l, fp))
    }

    /// Clé DES d'un mot de passe VNC : 8 premiers octets (latin-1, zéros de remplissage), bits de chaque octet inversés.
    public static func vncKey(password: String) -> [UInt8] {
        var raw = Array(password.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(8))
        while raw.count < 8 { raw.append(0) }
        return raw.map { b in (0..<8).reduce(UInt8(0)) { ($0 << 1) | ((b >> UInt8($1)) & 1) } }
    }

    /// Réponse au défi de 16 octets : deux blocs DES-ECB indépendants.
    public static func vncResponse(challenge: [UInt8], password: String) -> [UInt8] {
        precondition(challenge.count == 16)
        let key = vncKey(password: password)
        return cryptBlock(Array(challenge[0..<8]), key: key) + cryptBlock(Array(challenge[8..<16]), key: key)
    }
}
