import Foundation
import Testing
@testable import EscaleCore

/// File d'octets asynchrone (un consommateur) : un côté d'un tube mémoire.
actor VNCByteQueue {
    private var chunks: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var closed = false

    func push(_ bytes: [UInt8]) {
        guard !closed else { return }
        if let w = waiter { waiter = nil; w.resume(returning: bytes) } else { chunks.append(bytes) }
    }

    func close() {
        closed = true
        if let w = waiter { waiter = nil; w.resume(throwing: RFBError.connectionClosed) }
    }

    func pop() async throws -> [UInt8] {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if closed { throw RFBError.connectionClosed }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

/// Extrémité d'un tube mémoire : implémente le transport du client, et sert de « serveur » scripté dans les tests.
final class VNCLoopbackEnd: RFBTransport, @unchecked Sendable {
    let incoming = VNCByteQueue()
    nonisolated(unsafe) var peer: VNCLoopbackEnd?
    nonisolated(unsafe) private var pending: [UInt8] = []
    /// Taille maximale d'un morceau livré à l'autre bout (1 : octet par octet, pour tester les lectures partielles).
    nonisolated(unsafe) var chunkSize = Int.max

    static func pair() -> (client: VNCLoopbackEnd, server: VNCLoopbackEnd) {
        let a = VNCLoopbackEnd(), b = VNCLoopbackEnd()
        a.peer = b; b.peer = a
        return (a, b)
    }

    func receive() async throws -> [UInt8] { try await incoming.pop() }

    func send(_ bytes: [UInt8]) async throws {
        guard let peer else { throw RFBError.connectionClosed }
        var i = 0
        while i < bytes.count {
            let n = min(chunkSize, bytes.count - i)
            await peer.incoming.push(Array(bytes[i..<i + n])); i += n
            if chunkSize < 64 { await Task.yield() }
        }
    }

    func close() { Task { await peer?.incoming.close(); await incoming.close() } }

    // Côté serveur : lecture exacte (un seul lecteur à la fois).
    func read(_ n: Int) async throws -> [UInt8] {
        while pending.count < n { pending += try await incoming.pop() }
        let out = Array(pending.prefix(n)); pending.removeFirst(n); return out
    }
}

func hexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []; var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

/// ServerInit 3.8 standard : taille, format de pixels du serveur (ignoré par le client), nom.
func vncServerInit(width: Int, height: Int, name: String) -> [UInt8] {
    be16(width) + be16(height) + RFBPixelFormat.bgra32.wireBytes + be32(UInt32(name.utf8.count)) + Array(name.utf8)
}

/// Message FramebufferUpdate avec une liste de (rect, encodage, données).
func vncUpdate(_ rects: [(RFBRect, Int32, [UInt8])]) -> [UInt8] {
    var out: [UInt8] = [0, 0] + be16(rects.count)
    for (r, e, d) in rects { out += be16(r.x) + be16(r.y) + be16(r.width) + be16(r.height) + be32(UInt32(bitPattern: e)) + d }
    return out
}
