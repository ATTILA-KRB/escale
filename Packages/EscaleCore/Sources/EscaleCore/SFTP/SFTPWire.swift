import Foundation

// Encodage/décodage binaire SFTP (entiers big-endian, chaînes préfixées par leur longueur).

struct SFTPWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                                 UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }
    mutating func u64(_ v: UInt64) { u32(UInt32(truncatingIfNeeded: v >> 32)); u32(UInt32(truncatingIfNeeded: v)) }
    mutating func bytes(_ b: Data) { u32(UInt32(b.count)); data.append(b) }
    mutating func string(_ s: String) { bytes(Data(s.utf8)) }
    /// ATTRS : drapeaux, puis permissions et/ou (atime, mtime).
    mutating func attrs(permissions: UInt32?, accessTime: UInt32?, modificationTime: UInt32?) {
        var flags: UInt32 = 0
        if permissions != nil { flags |= 0x4 }
        if accessTime != nil, modificationTime != nil { flags |= 0x8 }
        u32(flags)
        if let p = permissions { u32(p) }
        if let a = accessTime, let m = modificationTime { u32(a); u32(m) }
    }
}

struct SFTPReader {
    private let d: Data
    private var p: Int
    init(_ d: Data) { self.d = d; p = d.startIndex }

    var remaining: Int { d.endIndex - p }

    /// Tout le reste de la trame, copié (indices repartant de 0).
    mutating func bytesRemaining() throws -> Data {
        defer { p = d.endIndex }
        return Data(d[p..<d.endIndex])
    }

    mutating func u8() throws -> UInt8 {
        guard p < d.endIndex else { throw SFTPError.protocolViolation("trame tronquée") }
        defer { p += 1 }
        return d[p]
    }
    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.protocolViolation("trame tronquée") }
        var v: UInt32 = 0
        for _ in 0..<4 { v = v << 8 | UInt32(d[p]); p += 1 }
        return v
    }
    mutating func u64() throws -> UInt64 {
        let h = UInt64(try u32())
        return h << 32 | UInt64(try u32())
    }
    mutating func bytes() throws -> Data {
        let n = Int(try u32())
        guard n <= remaining else { throw SFTPError.protocolViolation("chaîne tronquée") }
        defer { p += n }
        return Data(d[p..<p + n])
    }
    /// Chaîne décodée en UTF-8 (remplacement U+FFFD si invalide ; pour les noms, utiliser `bytes()`).
    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try u32()
        var a = SFTPAttributes()
        if flags & 0x1 != 0 { a.size = try u64() }
        if flags & 0x2 != 0 { a.uid = try u32(); a.gid = try u32() }
        if flags & 0x4 != 0 { a.permissions = try u32() }
        if flags & 0x8 != 0 {
            a.accessTime = Date(timeIntervalSince1970: TimeInterval(try u32()))
            a.modificationTime = Date(timeIntervalSince1970: TimeInterval(try u32()))
        }
        if flags & 0x8000_0000 != 0 {
            let n = Int(try u32())
            guard n <= remaining / 8 else { throw SFTPError.protocolViolation("attributs étendus invalides") }
            for _ in 0..<n { _ = try bytes(); _ = try bytes() }
        }
        return a
    }
}

enum SFTPPacket {
    static let initialize: UInt8 = 1, version: UInt8 = 2
    static let open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5, write: UInt8 = 6
    static let lstat: UInt8 = 7, setstat: UInt8 = 9, opendir: UInt8 = 11, readdir: UInt8 = 12
    static let remove: UInt8 = 13, mkdir: UInt8 = 14, rmdir: UInt8 = 15, realpath: UInt8 = 16
    static let stat: UInt8 = 17, rename: UInt8 = 18, readlink: UInt8 = 19, extended: UInt8 = 200
    static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104
    static let attrs: UInt8 = 105, extendedReply: UInt8 = 201
}
