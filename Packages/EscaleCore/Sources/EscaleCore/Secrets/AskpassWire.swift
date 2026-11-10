import Foundation

/// Protocole (privé au paquet) entre l'exécutable askpass et `AskpassServer`, sur socket Unix.
///
/// Requête : 4 octets (longueur, big-endian) + `ESCALE-ASKPASS/1\n<jeton>\n<invite UTF-8>`.
/// Réponse : 1 octet d'état (0 = secret, 1 = refus) + 4 octets de longueur + données (vide si refus).
enum AskpassWire {
    static let header = "ESCALE-ASKPASS/1"
    static let statusSecret: UInt8 = 0
    static let statusRefused: UInt8 = 1
    /// Taille maximale d'un secret renvoyé au client.
    static let maxReplyBytes = 8192

    static func encodeRequest(token: String, prompt: String) -> Data {
        let payload = Data("\(header)\n\(token)\n\(prompt)".utf8)
        var d = Data(); d.append(uint32: UInt32(payload.count)); d.append(payload)
        return d
    }

    static func encodeReply(_ secret: Data?) -> Data {
        var d = Data([secret == nil ? statusRefused : statusSecret])
        d.append(uint32: UInt32(secret?.count ?? 0))
        if let s = secret { d.append(s) }
        return d
    }

    /// Comparaison en temps constant (la longueur du jeton est publique).
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Jeton aléatoire (32 octets du CSPRNG système, en hexadécimal).
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    mutating func append(uint32 v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
}

/// Aides POSIX pour les sockets Unix (blocage avec échéance).
enum UnixSocket {
    struct Failure: Error { var message: String }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &a.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
        return a
    }

    /// Lit exactement `count` octets avant `deadline`. nil = fin de flux, erreur ou échéance (`timedOut` renseigné).
    static func readExactly(_ fd: Int32, count: Int, deadline: Date, timedOut: inout Bool, cancelled: () -> Bool = { false }) -> [UInt8]? {
        var out = [UInt8](); out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: max(1, min(count, 4096)))
        while out.count < count {
            if cancelled() { return nil }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(remaining, 0.1) * 1000) + 1)
            if r < 0 { if errno == EINTR { continue }; return nil }
            if r == 0 { continue }
            let n = recv(fd, &buf, min(buf.count, count - out.count), 0)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            if n == 0 { return nil }
            out += buf[0..<n]
        }
        return out
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let r = poll(&p, 1, Int32(min(remaining, 0.1) * 1000) + 1)
            if r < 0 { if errno == EINTR { continue }; return false }
            if r == 0 { continue }
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
            sent += n
        }
        return true
    }
}
