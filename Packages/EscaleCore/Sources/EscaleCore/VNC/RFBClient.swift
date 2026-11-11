import Foundation

// MARK: Types publics

public struct RFBCredentials: Sendable {
    public var username: String
    public var password: String
    public init(username: String = "", password: String) { self.username = username; self.password = password }
}

public struct RFBAuthRequest: Sendable {
    public enum Kind: Sendable { case vncPassword, appleRemoteDesktop }
    public let kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

/// Fournit les identifiants quand le serveur en demande (nil : l'utilisateur annule). Jamais appelé pour la sécurité « Aucune ».
public typealias RFBCredentialsProvider = @Sendable (RFBAuthRequest) async -> RFBCredentials?

public struct RFBServerInfo: Sendable, Equatable {
    public let name: String
    public let width: Int
    public let height: Int
    /// Version négociée (« 3.8 », « 3.7 » ou « 3.3 »).
    public let version: String
    /// Type de sécurité utilisé (1 aucune, 2 VNC, 30 Apple Remote Desktop).
    public let securityType: UInt8
}

public struct RFBCursor: Sendable, Equatable {
    public let hotspotX: Int, hotspotY: Int, width: Int, height: Int
    /// BGRA, alpha 255 où le masque est plein.
    public let bgra: [UInt8]
}

public enum RFBEvent: Sendable {
    /// Rectangles du framebuffer modifiés (le contenu est déjà dans `framebuffer`).
    case updated([RFBRect])
    case resized(width: Int, height: Int)
    /// Nouveau curseur distant ; nil : curseur masqué.
    case cursor(RFBCursor?)
    case clipboard(String)
    case bell
    /// Fin de session (nil : fermeture voulue). Dernier événement du flux.
    case disconnected(RFBError?)
}

public struct RFBConfiguration: Sendable {
    public var shared: Bool
    public var viewOnly: Bool
    public var encodings: [Int32]

    public init(shared: Bool = true, viewOnly: Bool = false, encodings: [Int32] = RFBEncoding.list(for: .auto)) {
        self.shared = shared; self.viewOnly = viewOnly; self.encodings = encodings
    }

    public init(settings: VNCSettings) {
        self.init(shared: settings.shared, viewOnly: settings.viewOnly, encodings: RFBEncoding.list(for: settings.encoding))
    }
}

// MARK: Client

/// Client RFB (RFC 6143) : poignée de main 3.3/3.7/3.8, sécurité Aucune / VNC / Apple Remote Desktop, ClientInit partagé,
/// format de pixels BGRA 32 bits, encodages Raw/CopyRect/RRE/Hextile/ZRLE et pseudo-encodages Cursor/DesktopSize.
///
/// Concurrence : acteur ; la réception tourne dans une tâche, les envois d'entrée (clavier, souris, presse-papiers) sont
/// mis en file de façon synchrone (`nonisolated`) puis écrits dans l'ordre par une tâche d'écriture.
public actor RFBClient {
    public nonisolated let framebuffer = RFBFramebuffer()
    public nonisolated let events: AsyncStream<RFBEvent>
    public nonisolated let configuration: RFBConfiguration

    private let transport: any RFBTransport
    private let eventSink: AsyncStream<RFBEvent>.Continuation
    private nonisolated let outbound: AsyncStream<[UInt8]>.Continuation
    private let outboundStream: AsyncStream<[UInt8]>
    private var buffer: [UInt8] = []
    private var start = 0
    private let inflater = RFBInflater()
    private var receiveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var finished = false
    public private(set) var info: RFBServerInfo?

    public init(transport: any RFBTransport, configuration: RFBConfiguration = RFBConfiguration()) {
        self.transport = transport
        self.configuration = configuration
        (events, eventSink) = AsyncStream.makeStream(of: RFBEvent.self, bufferingPolicy: .unbounded)
        (outboundStream, outbound) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)
    }

    deinit { receiveTask?.cancel(); writeTask?.cancel() }

    // MARK: Connexion

    /// Poignée de main complète jusqu'à ServerInit, puis démarre la réception. Lève en cas d'échec (le transport est fermé).
    public func connect(credentials: @escaping RFBCredentialsProvider) async throws -> RFBServerInfo {
        do {
            let info = try await handshake(credentials)
            self.info = info
            startLoops()
            return info
        } catch {
            transport.close()
            finish(nil)
            throw (error as? RFBError) ?? RFBError.transport("\(error)")
        }
    }

    private func handshake(_ credentials: RFBCredentialsProvider) async throws -> RFBServerInfo {
        // Version
        let hello = try await readBytes(12)
        guard hello.count == 12, hello[0..<4] == [0x52, 0x46, 0x42, 0x20], hello[7] == 0x2e, hello[11] == 0x0a,
              let major = Int(String(decoding: hello[4..<7], as: UTF8.self)), let minor = Int(String(decoding: hello[8..<11], as: UTF8.self)) else {
            throw RFBError.unsupportedVersion(String(decoding: hello.prefix(11), as: UTF8.self))
        }
        guard major == 3 else { throw RFBError.unsupportedVersion("RFB \(major).\(minor)") }
        // 3.889 (Apple) et toute version ≥ 3.8 : on parle 3.8 ; 3.7 ; le reste (3.3 à 3.6) : 3.3.
        let version: Int = minor >= 8 ? 8 : (minor == 7 ? 7 : 3)
        try await transport.send(Array("RFB 003.00\(version)\n".utf8))

        // Sécurité
        var security: UInt8
        if version == 3 {
            let t = try await readU32()
            if t == 0 { throw RFBError.refused(try await readReason()) }
            guard t <= 255 else { throw RFBError.unsupportedSecurity([]) }
            security = UInt8(t)
            guard [1, 2, 30].contains(security) else { throw RFBError.unsupportedSecurity([security]) }
        } else {
            let n = Int(try await readBytes(1)[0])
            if n == 0 { throw RFBError.refused(try await readReason()) }
            let types = try await readBytes(n)
            guard let chosen = [1, 2, 30].first(where: { types.contains($0) }) else { throw RFBError.unsupportedSecurity(types) }
            security = chosen
            try await transport.send([security])
        }

        switch security {
        case 1: break
        case 2:
            let challenge = try await readBytes(16)
            guard let c = await credentials(RFBAuthRequest(kind: .vncPassword)) else { throw RFBError.authenticationCancelled }
            try await transport.send(VNCDES.vncResponse(challenge: challenge, password: c.password))
        default: // 30 : Apple Remote Desktop
            let head = try await readBytes(4)
            let generator = Int(head[0]) << 8 | Int(head[1]), keyLength = Int(head[2]) << 8 | Int(head[3])
            guard keyLength >= 16, keyLength <= 1024 else { throw RFBError.protocolViolation("longueur de clé ARD invalide") }
            let prime = try await readBytes(keyLength), serverKey = try await readBytes(keyLength)
            guard let c = await credentials(RFBAuthRequest(kind: .appleRemoteDesktop)) else { throw RFBError.authenticationCancelled }
            try await transport.send(try RFBAppleAuth.response(
                generator: generator, prime: prime, serverPublicKey: serverKey, username: c.username, password: c.password))
        }

        // Résultat : toujours en 3.8 ; en 3.3/3.7 seulement pour une authentification réelle.
        if version >= 8 || security != 1 {
            let result = try await readU32()
            if result != 0 {
                let reason = version >= 8 ? ((try? await readReason()) ?? "") : ""
                throw RFBError.authenticationFailed(reason.isEmpty ? "Mot de passe ou identifiants refusés par le serveur." : "Authentification refusée : \(reason)")
            }
        }

        // ClientInit / ServerInit
        try await transport.send([configuration.shared ? 1 : 0])
        let initial = try await readBytes(24)
        let width = Int(initial[0]) << 8 | Int(initial[1]), height = Int(initial[2]) << 8 | Int(initial[3])
        let nameLength = Int(initial[20]) << 24 | Int(initial[21]) << 16 | Int(initial[22]) << 8 | Int(initial[23])
        guard nameLength <= 1 << 16 else { throw RFBError.protocolViolation("nom de bureau démesuré") }
        let name = String(decoding: try await readBytes(nameLength), as: UTF8.self)
        try framebuffer.resize(width: width, height: height)

        // SetPixelFormat, SetEncodings, première demande complète.
        try await transport.send([0, 0, 0, 0] + RFBPixelFormat.bgra32.wireBytes)
        let enc = configuration.encodings
        var setEncodings: [UInt8] = [2, 0, UInt8(enc.count >> 8), UInt8(enc.count & 0xff)]
        for e in enc { setEncodings += Self.be32(UInt32(bitPattern: e)) }
        try await transport.send(setEncodings)
        try await transport.send(Self.updateRequest(incremental: false, width: width, height: height))
        return RFBServerInfo(name: name, width: width, height: height, version: "3.\(version == 3 ? 3 : version)", securityType: security)
    }

    private func readReason() async throws -> String {
        let n = Int(try await readU32())
        guard n <= 1 << 16 else { throw RFBError.protocolViolation("message du serveur démesuré") }
        return String(decoding: try await readBytes(n), as: UTF8.self)
    }

    // MARK: Boucles

    private func startLoops() {
        let stream = outboundStream, transport = self.transport
        writeTask = Task.detached {
            for await message in stream {
                do { try await transport.send(message) } catch { return }
            }
        }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.receiveLoop(); await self.finish(nil) }
            catch is CancellationError { await self.finish(nil) }
            catch { await self.finish((error as? RFBError) ?? .transport("\(error)")) }
        }
    }

    /// Ferme la session (idempotent). Le flux d'événements se termine par `.disconnected(nil)`.
    public func disconnect() {
        guard !finished else { return }
        transport.close()
        finish(nil)
    }

    private func finish(_ error: RFBError?) {
        guard !finished else { return }
        finished = true
        eventSink.yield(.disconnected(error))
        eventSink.finish()
        outbound.finish()
        receiveTask?.cancel()
        transport.close()
    }

    private func receiveLoop() async throws {
        while !Task.isCancelled {
            let type = try await readBytes(1)[0]
            switch type {
            case 0: try await frameBufferUpdate()
            case 1: // SetColourMapEntries : inutile en couleurs vraies, on consomme.
                let h = try await readBytes(5)
                let n = Int(h[3]) << 8 | Int(h[4])
                _ = try await readBytes(n * 6)
            case 2: eventSink.yield(.bell)
            case 3:
                let h = try await readBytes(7)
                let n = Int(h[3]) << 24 | Int(h[4]) << 16 | Int(h[5]) << 8 | Int(h[6])
                guard n >= 0, n <= 16 << 20 else { throw RFBError.protocolViolation("presse-papiers démesuré") }
                let text = try await readBytes(n)
                eventSink.yield(.clipboard(String(text.map { Character(Unicode.Scalar($0)) })))
            default: throw RFBError.protocolViolation("message serveur inconnu (\(type))")
            }
        }
    }

    private func frameBufferUpdate() async throws {
        let head = try await readBytes(3)
        let count = Int(head[1]) << 8 | Int(head[2])
        var dirty: [RFBRect] = []
        for _ in 0..<count {
            let h = try await readBytes(12)
            let rect = RFBRect(x: Int(h[0]) << 8 | Int(h[1]), y: Int(h[2]) << 8 | Int(h[3]),
                               width: Int(h[4]) << 8 | Int(h[5]), height: Int(h[6]) << 8 | Int(h[7]))
            let encoding = Int32(bitPattern: UInt32(h[8]) << 24 | UInt32(h[9]) << 16 | UInt32(h[10]) << 8 | UInt32(h[11]))
            switch encoding {
            case RFBEncoding.raw, RFBEncoding.copyRect, RFBEncoding.rre, RFBEncoding.hextile, RFBEncoding.zrle:
                guard !rect.isEmpty else { continue }
                let fb = framebuffer
                try await decode { reader in
                    try fb.withPixels { buf in
                        switch encoding {
                        case RFBEncoding.raw: try RFBDecoders.decodeRaw(&reader, rect: rect, into: buf)
                        case RFBEncoding.copyRect: try RFBDecoders.decodeCopyRect(&reader, rect: rect, into: buf)
                        case RFBEncoding.rre: try RFBDecoders.decodeRRE(&reader, rect: rect, into: buf)
                        case RFBEncoding.hextile: try RFBDecoders.decodeHextile(&reader, rect: rect, into: buf)
                        default: try RFBDecoders.decodeZRLE(&reader, rect: rect, into: buf, inflater: self.inflater)
                        }
                    }
                }
                dirty.append(rect)
            case RFBEncoding.desktopSize:
                try framebuffer.resize(width: rect.width, height: rect.height)
                dirty = [RFBRect(x: 0, y: 0, width: rect.width, height: rect.height)]
                eventSink.yield(.resized(width: rect.width, height: rect.height))
                outbound.yield(Self.updateRequest(incremental: false, width: rect.width, height: rect.height))
            case RFBEncoding.cursor:
                guard rect.width * rect.height <= 1 << 20 else { throw RFBError.protocolViolation("curseur démesuré") }
                var cursor: RFBCursor?
                try await decode { reader in
                    if rect.width == 0 || rect.height == 0 { cursor = nil; return }
                    let px = try RFBDecoders.decodeCursor(&reader, width: rect.width, height: rect.height)
                    cursor = RFBCursor(hotspotX: rect.x, hotspotY: rect.y, width: rect.width, height: rect.height, bgra: px)
                }
                eventSink.yield(.cursor(cursor))
            default:
                throw RFBError.protocolViolation("encodage \(encoding) non pris en charge")
            }
        }
        if !dirty.isEmpty { eventSink.yield(.updated(dirty)) }
        outbound.yield(Self.updateRequest(incremental: true, width: framebuffer.width, height: framebuffer.height))
    }

    /// Décode un rectangle en attendant, au besoin, les octets manquants (relance depuis le début du rectangle).
    private func decode(_ body: (inout RFBByteReader) throws -> Void) async throws {
        while true {
            var reader = RFBByteReader(buffer, position: start)
            do {
                try body(&reader)
                start = reader.position
                reader = RFBByteReader([])
                compact()
                return
            } catch let need as RFBNeedMoreData {
                reader = RFBByteReader([])
                try await ensure(need.total)
            }
        }
    }

    // MARK: Entrées (ordre garanti : file synchrone)

    public nonisolated func sendKey(keysym: UInt32, down: Bool) {
        guard !configuration.viewOnly else { return }
        outbound.yield([4, down ? 1 : 0, 0, 0] + Self.be32(keysym))
    }

    /// `buttons` : bits 0 gauche, 1 milieu, 2 droit, 3 molette haut, 4 molette bas, 5-6 horizontale.
    public nonisolated func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard !configuration.viewOnly else { return }
        let cx = UInt16(max(0, min(65535, x))), cy = UInt16(max(0, min(65535, y)))
        outbound.yield([5, buttons, UInt8(cx >> 8), UInt8(cx & 0xff), UInt8(cy >> 8), UInt8(cy & 0xff)])
    }

    /// Presse-papiers vers le serveur (latin-1 : les caractères hors latin-1 deviennent « ? »).
    public nonisolated func sendClipboard(_ text: String) {
        guard !configuration.viewOnly else { return }
        let bytes = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        guard bytes.count <= 16 << 20 else { return }
        outbound.yield([6, 0, 0, 0] + Self.be32(UInt32(bytes.count)) + bytes)
    }

    /// Demande une mise à jour complète (après un redimensionnement de fenêtre, par exemple).
    public nonisolated func requestFullUpdate(width: Int, height: Int) {
        outbound.yield(Self.updateRequest(incremental: false, width: width, height: height))
    }

    // MARK: Lecture

    private func ensure(_ n: Int) async throws {
        while buffer.count - start < n {
            try Task.checkCancellation()
            buffer.append(contentsOf: try await transport.receive())
        }
    }

    private func readBytes(_ n: Int) async throws -> [UInt8] {
        try await ensure(n)
        defer { start += n; compact() }
        return Array(buffer[start..<start + n])
    }

    private func readU32() async throws -> UInt32 {
        let b = try await readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func compact() {
        if start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        else if start > 1 << 20, start * 2 > buffer.count { buffer.removeFirst(start); start = 0 }
    }

    // MARK: Messages

    nonisolated static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    nonisolated static func updateRequest(incremental: Bool, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8 & 0xff), UInt8(width & 0xff), UInt8(height >> 8 & 0xff), UInt8(height & 0xff)]
    }
}
