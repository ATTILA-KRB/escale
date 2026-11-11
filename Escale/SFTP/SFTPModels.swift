import Foundation
import EscaleCore

/// Un élément du dossier distant affiché dans le navigateur.
/// Les chemins restent des octets (`Data`) : un nom non UTF-8 reste adressable.
struct SFTPItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: Data
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64?
    var modified: Date?
    var permissions: UInt32?

    var id: Data { path }

    /// Droits façon `ls` (« rwxr-xr-x »).
    var permissionText: String {
        guard let p = permissions else { return "—" }
        let bits = Array("rwxrwxrwx")
        var out = ""
        for i in 0..<9 { out.append(p & (1 << UInt32(8 - i)) != 0 ? bits[i] : "-") }
        return out
    }
}

/// Opérations sur les chemins distants (POSIX, en octets).
enum SFTPPath {
    static func join(_ dir: Data, _ name: Data) -> Data {
        var d = dir
        if d.last != UInt8(ascii: "/") { d.append(UInt8(ascii: "/")) }
        d.append(name)
        return d
    }
    static func join(_ dir: Data, _ name: String) -> Data { join(dir, Data(name.utf8)) }

    static func parent(_ path: Data) -> Data {
        var p = path
        while p.count > 1, p.last == UInt8(ascii: "/") { p.removeLast() }
        guard let i = p.lastIndex(of: UInt8(ascii: "/")) else { return Data("/".utf8) }
        let idx = p.distance(from: p.startIndex, to: i)
        return idx == 0 ? Data("/".utf8) : Data(p.prefix(idx))
    }

    static func lastComponent(_ path: Data) -> String {
        var p = path
        while p.count > 1, p.last == UInt8(ascii: "/") { p.removeLast() }
        guard let i = p.lastIndex(of: UInt8(ascii: "/")) else { return String(decoding: p, as: UTF8.self) }
        return String(decoding: p.suffix(from: p.index(after: i)), as: UTF8.self)
    }

    static func string(_ path: Data) -> String { String(decoding: path, as: UTF8.self) }
}

/// Textes français des erreurs SFTP / transport.
@MainActor
enum SFTPMessages {
    static func describe(_ error: Error) -> String {
        if let e = error as? SFTPError {
            switch e {
            case .status(let code, let message):
                switch code {
                case .noSuchFile: return "Introuvable sur le serveur."
                case .permissionDenied: return "Permission refusée par le serveur."
                case .opUnsupported: return "Opération non supportée par le serveur."
                case .failure: return message.isEmpty ? "Le serveur a refusé l'opération." : message
                default: return message.isEmpty ? "Erreur SFTP (\(code))." : message
                }
            case .protocolViolation(let m): return "Réponse SFTP inattendue : \(m)"
            case .channelClosed: return "Canal SFTP fermé (connexion perdue)."
            case .negotiationTimeout: return "Le serveur SFTP ne répond pas."
            case .unsupportedVersion(let v): return "Version SFTP \(v) non supportée."
            case .localIO(let m): return m
            case .invalidResumeOffset(let m): return m
            case .cancelled: return "Annulé."
            }
        }
        if let t = error as? SSHTransportError {
            switch t {
            case .subsystemUnavailable(let m): return "Sous-système SFTP indisponible : \(m)"
            case .sessionRefused(let m): return "Session refusée : \(m)"
            case .notConnected: return "Connexion non établie."
            case .masterFailed(let m): return m
            case .forwardRefused(let m): return m
            }
        }
        return SSHLink.describe(error)
    }

    /// Le canal est mort : la session doit se rouvrir.
    static func isChannelLoss(_ error: Error) -> Bool {
        if case SFTPError.channelClosed = error { return true }
        if case SSHTransportError.notConnected = error { return true }
        return false
    }
}

enum SFTPFormat {
    static func size(_ bytes: UInt64?) -> String {
        guard let b = bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
    }
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
}
