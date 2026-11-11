import CommonCrypto
import CryptoKit
import Foundation

/// Arithmétique modulaire minimale (Montgomery, mots de 32 bits) pour l'échange Diffie-Hellman d'Apple Remote Desktop
/// (clé de 1024 bits : quelques millisecondes). Le module doit être impair (un nombre premier, en pratique).
public enum RFBModularMath {
    /// `base ^ exponent mod modulus`, entiers non signés en octets big-endian. Résultat sur `modulus.count` octets
    /// (zéros en tête conservés). nil si le module est pair/nul ou si `base >= modulus`.
    public static func modPow(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8]? {
        let m = limbs(modulus)
        let n = m.count
        guard n > 0, m[0] & 1 == 1 else { return nil }
        var b = limbs(base)
        guard b.count <= n else { return nil }
        b += [UInt32](repeating: 0, count: n - b.count)
        guard compare(b, m) < 0 else { return nil }

        // -m^{-1} mod 2^32 par itération de Newton.
        var inv = m[0]
        for _ in 0..<5 { inv = inv &* (2 &- m[0] &* inv) }
        let mInv = 0 &- inv

        // R² mod m (R = 2^(32 n)) par doublements successifs de 1.
        var r2 = [UInt32](repeating: 0, count: n); r2[0] = 1
        for _ in 0..<(64 * n) {
            var carry: UInt32 = 0
            for i in 0..<n { let v = r2[i]; r2[i] = v << 1 | carry; carry = v >> 31 }
            if carry != 0 || compare(r2, m) >= 0 { subtract(&r2, m) }
        }

        func mul(_ a: [UInt32], _ c: [UInt32]) -> [UInt32] { montMul(a, c, m, mInv) }
        var one = [UInt32](repeating: 0, count: n); one[0] = 1
        var acc = mul(one, r2)       // 1 en représentation de Montgomery
        let baseM = mul(b, r2)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                acc = mul(acc, acc)
                if (byte >> UInt8(bit)) & 1 == 1 { acc = mul(acc, baseM) }
            }
        }
        let result = mul(acc, one)
        return bytes(result, count: modulus.count)
    }

    private static func limbs(_ be: [UInt8]) -> [UInt32] {
        var out: [UInt32] = []
        var i = be.count
        while i > 0 {
            var v: UInt32 = 0
            for k in max(0, i - 4)..<i { v = v << 8 | UInt32(be[k]) }
            out.append(v); i -= 4
        }
        while out.count > 1, out.last == 0 { out.removeLast() }
        return out
    }

    private static func bytes(_ l: [UInt32], count: Int) -> [UInt8] {
        var be: [UInt8] = []
        for v in l.reversed() { be += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        if be.count >= count { return Array(be.suffix(count)) }
        return [UInt8](repeating: 0, count: count - be.count) + be
    }

    private static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        for i in (0..<a.count).reversed() where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return 0
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<a.count {
            let d = Int64(a[i]) - Int64(b[i]) - borrow
            a[i] = UInt32(truncatingIfNeeded: d); borrow = d < 0 ? 1 : 0
        }
    }

    private static func montMul(_ a: [UInt32], _ b: [UInt32], _ m: [UInt32], _ mInv: UInt32) -> [UInt32] {
        let n = m.count
        var t = [UInt32](repeating: 0, count: n + 2)
        for i in 0..<n {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<n {
                let s = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                t[j] = UInt32(truncatingIfNeeded: s); carry = s >> 32
            }
            var s = UInt64(t[n]) + carry
            t[n] = UInt32(truncatingIfNeeded: s); t[n + 1] = UInt32(truncatingIfNeeded: s >> 32)
            let q = UInt64(t[0] &* mInv)
            s = UInt64(t[0]) + q * UInt64(m[0]); carry = s >> 32
            for j in 1..<max(n, 1) {
                s = UInt64(t[j]) + q * UInt64(m[j]) + carry
                t[j - 1] = UInt32(truncatingIfNeeded: s); carry = s >> 32
            }
            s = UInt64(t[n]) + carry
            t[n - 1] = UInt32(truncatingIfNeeded: s)
            t[n] = t[n + 1] &+ UInt32(truncatingIfNeeded: s >> 32)
        }
        var r = Array(t[0..<n])
        if t[n] != 0 || compare(r, m) >= 0 { subtract(&r, m) }
        return r
    }
}

/// Authentification Apple Remote Desktop (type de sécurité 30), utilisée par le Partage d'écran de macOS pour les
/// comptes macOS : Diffie-Hellman, clé AES-128 = MD5(secret partagé), identifiants (64 + 64 octets) chiffrés en AES-ECB.
public enum RFBAppleAuth {
    /// Réponse du client : 128 octets chiffrés suivis de la clé publique du client (`keyLength` octets).
    /// `randomBytes` est injectable (tests) ; par défaut, aléatoire système.
    public static func response(generator: Int, prime: [UInt8], serverPublicKey: [UInt8], username: String, password: String,
                                randomBytes: (Int) -> [UInt8] = { n in (0..<n).map { _ in UInt8.random(in: 0...255) } }) throws -> [UInt8] {
        let keyLength = prime.count
        guard keyLength >= 16, keyLength <= 1024, serverPublicKey.count == keyLength, generator > 1 else {
            throw RFBError.protocolViolation("paramètres Diffie-Hellman invalides")
        }
        var priv = randomBytes(keyLength)
        priv[0] &= 0x7f
        let g = [UInt8](repeating: 0, count: keyLength - 2) + [UInt8(generator >> 8 & 0xff), UInt8(generator & 0xff)]
        guard let pub = RFBModularMath.modPow(base: g, exponent: priv, modulus: prime),
              let shared = RFBModularMath.modPow(base: serverPublicKey, exponent: priv, modulus: prime) else {
            throw RFBError.protocolViolation("échange Diffie-Hellman impossible")
        }
        let key = Array(Insecure.MD5.hash(data: shared))
        var credentials = randomBytes(128)
        func place(_ s: String, at o: Int) {
            let b = Array(s.utf8.prefix(63))
            for i in 0..<64 { credentials[o + i] = i < b.count ? b[i] : (i == b.count ? 0 : credentials[o + i]) }
        }
        place(username, at: 0); place(password, at: 64)
        return try aes128ECB(credentials, key: key, encrypt: true) + pub
    }

    /// AES-128-ECB sans bourrage (longueur multiple de 16).
    public static func aes128ECB(_ data: [UInt8], key: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard key.count == 16, data.count % 16 == 0 else { throw RFBError.protocolViolation("AES : paramètres invalides") }
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, 16, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw RFBError.protocolViolation("AES : échec (\(status))") }
        return Array(out[0..<moved])
    }
}
