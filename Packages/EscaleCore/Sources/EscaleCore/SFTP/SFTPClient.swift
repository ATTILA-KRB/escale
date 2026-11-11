import Foundation

/// Réponse brute déjà décorrélée (type + charge utile, sans type ni request-id).
struct SFTPResponse: Sendable {
    let type: UInt8
    let payload: Data
}

/// Client SFTP v3 au-dessus d'un `ByteChannel`.
///
/// Une seule boucle de lecture dispatche les réponses par request-id ; plusieurs requêtes peuvent être en vol.
/// Les écritures passent par une file unique (trames jamais entrelacées). À la fermeture du canal, toutes les
/// requêtes en attente échouent aussitôt avec `SFTPError.channelClosed`.
public actor SFTPClient {
    struct Slot {
        var continuation: CheckedContinuation<SFTPResponse, any Error>?
        var result: Result<SFTPResponse, any Error>?
    }

    let channel: any ByteChannel
    let configuration: SFTPClientConfiguration
    var pending: [UInt32: Slot] = [:]
    var nextID: UInt32 = 1
    var closedError: SFTPError?
    var outgoing: AsyncStream<Data>.Continuation?
    var readerTask: Task<Void, Never>?
    var writerTask: Task<Void, Never>?
    var watchdogTask: Task<Void, Never>?
    /// Dernier signe de vie : réponse reçue, ou envoi d'une requête quand plus rien n'était en attente.
    var lastActivity = ContinuousClock.now
    /// Délais successifs sans la moindre réponse entre-temps.
    var consecutiveTimeouts = 0

    /// Extensions annoncées par le serveur dans VERSION (nom → données).
    public private(set) var serverExtensions: [String: String] = [:]
    /// Taille effective des requêtes READ / WRITE, après prise en compte de `limits@openssh.com`.
    var readChunk: Int
    var writeChunk: Int
    static let maxPacket = 16 * 1024 * 1024

    init(channel: any ByteChannel, configuration: SFTPClientConfiguration) {
        self.channel = channel
        self.configuration = configuration
        readChunk = max(1024, configuration.chunkSize)
        writeChunk = max(1024, configuration.chunkSize)
    }

    deinit {
        outgoing?.finish()
        readerTask?.cancel()
        writerTask?.cancel()
        watchdogTask?.cancel()
        let c = channel
        Task { await c.close() }
    }

    /// Ouvre le client : lance les boucles d'E/S, négocie INIT/VERSION (échoue en `negotiationTimeout` si le serveur est muet).
    public static func connect(channel: any ByteChannel,
                               configuration: SFTPClientConfiguration = .init()) async throws -> SFTPClient {
        let client = SFTPClient(channel: channel, configuration: configuration)
        await client.start()
        try await client.negotiate()
        return client
    }

    public func supportsExtension(_ name: String) -> Bool { serverExtensions[name] != nil }

    /// Ferme le canal ; les requêtes en vol échouent avec `channelClosed`.
    public func close() async {
        fail(.channelClosed("client SFTP fermé"))
        await channel.close()
    }

    // MARK: - Boucles d'E/S

    func start() {
        let channel = self.channel
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        outgoing = continuation
        writerTask = Task { [weak self] in
            for await frame in stream {
                do { try await channel.write(frame) } catch {
                    await self?.fail(Self.map(error)); return
                }
            }
        }
        if let timeout = configuration.requestTimeout {
            // Pas de minuterie par requête : une veille unique (quelques ticks par délai) qui compare à `lastActivity`.
            let tick = min(max(timeout / 4, .milliseconds(20)), .seconds(1))
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: tick)
                    guard let me = self, await me.checkTimeouts() else { return }
                }
            }
        }
        readerTask = Task { [weak self] in
            do {
                while true {
                    let header = try await channel.read(exactly: 4)
                    var hr = SFTPReader(header)
                    let length = Int(try hr.u32())
                    guard length >= 1, length <= Self.maxPacket else {
                        throw SFTPError.protocolViolation("longueur de trame invalide : \(length)")
                    }
                    let body = try await channel.read(exactly: length)
                    guard let me = self else { return }
                    try await me.dispatch(body)
                }
            } catch {
                await self?.fail(Self.map(error))
            }
        }
    }

    static func map(_ error: any Error) -> SFTPError {
        if let e = error as? SFTPError { return e }
        if case ByteChannelError.closed(let reason) = error { return .channelClosed(reason) }
        if error is CancellationError { return .channelClosed("lecture interrompue") }
        return .channelClosed(String(describing: error))
    }

    /// Route une trame reçue vers la requête qui l'attend. Une réponse à un id inconnu (abandonné) est ignorée.
    func dispatch(_ body: Data) throws {
        guard closedError == nil else { return }
        lastActivity = .now
        consecutiveTimeouts = 0
        var r = SFTPReader(body)
        let type = try r.u8()
        let id: UInt32 = type == SFTPPacket.version ? 0 : try r.u32()
        let payload = try r.bytesRemaining()
        guard var slot = pending[id] else { return }
        let response = SFTPResponse(type: type, payload: payload)
        if let c = slot.continuation {
            pending[id] = nil
            c.resume(returning: response)
        } else {
            slot.result = .success(response)
            pending[id] = slot
        }
    }

    /// Passe en état fermé (une seule fois) : toutes les requêtes en attente, y compris sans continuation encore posée, échouent.
    func fail(_ error: SFTPError) {
        guard closedError == nil else { return }
        closedError = error
        outgoing?.finish()
        readerTask?.cancel()
        watchdogTask?.cancel()
        let all = pending
        for (id, slot) in all {
            if let c = slot.continuation {
                pending[id] = nil
                c.resume(throwing: error)
            } else if slot.result == nil {
                pending[id] = Slot(continuation: nil, result: .failure(error))
            }
        }
        let c = channel
        Task { await c.close() }
    }

    // MARK: - Requêtes

    func negotiate() async throws {
        var w = SFTPWriter(); w.u8(SFTPPacket.initialize); w.u32(3)
        pending[0] = Slot()
        try enqueue(w.data)
        let timeout = configuration.negotiationTimeout
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(.negotiationTimeout)
        }
        defer { timer.cancel() }
        let resp = try await receive(0, cancellable: false)
        guard resp.type == SFTPPacket.version else { throw SFTPError.protocolViolation("réponse INIT inattendue : type \(resp.type)") }
        var r = SFTPReader(resp.payload)
        let version = try r.u32()
        guard version == 3 else { throw SFTPError.unsupportedVersion(version) }
        while r.remaining > 0 {
            let name = String(decoding: try r.bytes(), as: UTF8.self)
            serverExtensions[name] = String(decoding: try r.bytes(), as: UTF8.self)
        }
        if serverExtensions["limits@openssh.com"] != nil { await applyLimits() }
    }

    /// Respecte les limites annoncées par limits@openssh.com (échec silencieux : on garde les valeurs par défaut).
    func applyLimits() async {
        guard let resp = try? await call(SFTPPacket.extended, { $0.string("limits@openssh.com") }),
              resp.type == SFTPPacket.extendedReply else { return }
        var r = SFTPReader(resp.payload)
        guard let _ = try? r.u64(), let rl = try? r.u64(), let wl = try? r.u64() else { return }
        if rl > 0 { readChunk = max(1, min(readChunk, Int(min(rl, UInt64(Int32.max))))) }
        if wl > 0 { writeChunk = max(1, min(writeChunk, Int(min(wl, UInt64(Int32.max))))) }
    }

    func enqueue(_ body: Data) throws {
        if let e = closedError { throw e }
        var frame = SFTPWriter()
        frame.u32(UInt32(body.count))
        frame.data.append(body)
        outgoing?.yield(frame.data)
    }

    /// Envoie une requête et réserve sa place ; la réponse se récupère avec `receive`.
    func send(_ type: UInt8, _ build: (inout SFTPWriter) -> Void) throws -> UInt32 {
        if let e = closedError { throw e }
        if pending.isEmpty { lastActivity = .now }
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        var w = SFTPWriter()
        w.u8(type); w.u32(id); build(&w)
        pending[id] = Slot()
        do { try enqueue(w.data) } catch { pending[id] = nil; throw error }
        return id
    }

    /// Veille des délais. Renvoie false quand le client est fermé (la veille s'arrête).
    /// Si des requêtes attendent et que rien n'est arrivé depuis `requestTimeout`, elles échouent toutes en
    /// `requestTimeout` (libérées : une réponse tardive sera ignorée, ids jamais réutilisés tant qu'ils circulent).
    /// Après `maxConsecutiveTimeouts` délais sans réponse entre-temps, le canal est déclaré mort.
    func checkTimeouts() -> Bool {
        guard closedError == nil, let timeout = configuration.requestTimeout else { return false }
        let now = ContinuousClock.now
        let waiting = pending.filter { $0.key != 0 && $0.value.result == nil }
        guard !waiting.isEmpty, now - lastActivity >= timeout else { return true }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let error = SFTPError.requestTimeout(seconds: seconds)
        for (id, slot) in waiting {
            if let c = slot.continuation { pending[id] = nil; c.resume(throwing: error) }
            else { pending[id] = Slot(continuation: nil, result: .failure(error)) }
        }
        lastActivity = now
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= max(1, configuration.maxConsecutiveTimeouts) {
            fail(.channelClosed("le serveur ne répond plus (\(consecutiveTimeouts) délais de \(Int(seconds)) s sans réponse)"))
            return false
        }
        return true
    }

    /// Abandonne une requête en vol (sa réponse éventuelle sera ignorée).
    func discard(_ id: UInt32) {
        if let c = pending[id]?.continuation { c.resume(throwing: CancellationError()) }
        pending[id] = nil
    }

    /// Attend la réponse. `cancellable: false` pour le nettoyage (fermeture de handle) après une annulation.
    func receive(_ id: UInt32, cancellable: Bool = true) async throws -> SFTPResponse {
        if let result = pending[id]?.result {
            pending[id] = nil
            return try result.get()
        }
        guard pending[id] != nil else { throw closedError ?? SFTPError.protocolViolation("requête inconnue \(id)") }
        guard cancellable else { return try await waitForResponse(id, cancellable: false) }
        return try await withTaskCancellationHandler {
            try await self.waitForResponse(id, cancellable: true)
        } onCancel: {
            Task { await self.cancelWait(id) }
        }
    }

    private func waitForResponse(_ id: UInt32, cancellable: Bool) async throws -> SFTPResponse {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<SFTPResponse, any Error>) in
            if cancellable && Task.isCancelled { pending[id] = nil; c.resume(throwing: CancellationError()); return }
            guard pending[id] != nil else { c.resume(throwing: closedError ?? CancellationError()); return }
            pending[id]!.continuation = c
        }
    }

    private func cancelWait(_ id: UInt32) {
        if let c = pending[id]?.continuation {
            pending[id] = nil
            c.resume(throwing: CancellationError())
        }
    }

    func call(_ type: UInt8, _ build: (inout SFTPWriter) -> Void) async throws -> SFTPResponse {
        try await receive(try send(type, build))
    }

    // MARK: - Décodage des réponses

    static func statusError(_ resp: SFTPResponse) throws -> SFTPError? {
        var r = SFTPReader(resp.payload)
        let code = SFTPStatusCode(rawValue: try r.u32())
        let message = (try? r.string()) ?? ""
        return code == .ok ? nil : .status(code, message: message)
    }

    /// Exige un statut OK.
    func expectOK(_ resp: SFTPResponse) throws {
        guard resp.type == SFTPPacket.status else { throw SFTPError.protocolViolation("STATUS attendu, reçu \(resp.type)") }
        if let e = try Self.statusError(resp) { throw e }
    }

    func expectHandle(_ resp: SFTPResponse) throws -> Data {
        if resp.type == SFTPPacket.status { if let e = try Self.statusError(resp) { throw e } }
        guard resp.type == SFTPPacket.handle else { throw SFTPError.protocolViolation("HANDLE attendu, reçu \(resp.type)") }
        var r = SFTPReader(resp.payload)
        let h = try r.bytes()
        guard h.count <= 256 else { throw SFTPError.protocolViolation("handle trop long") }
        return h
    }

    func expectAttributes(_ resp: SFTPResponse) throws -> SFTPAttributes {
        if resp.type == SFTPPacket.status { if let e = try Self.statusError(resp) { throw e } }
        guard resp.type == SFTPPacket.attrs else { throw SFTPError.protocolViolation("ATTRS attendu, reçu \(resp.type)") }
        var r = SFTPReader(resp.payload)
        return try r.attributes()
    }

    func expectNames(_ resp: SFTPResponse) throws -> [SFTPDirectoryEntry] {
        guard resp.type == SFTPPacket.name else { throw SFTPError.protocolViolation("NAME attendu, reçu \(resp.type)") }
        var r = SFTPReader(resp.payload)
        let count = Int(try r.u32())
        guard count <= r.remaining / 12 else { throw SFTPError.protocolViolation("nombre d'entrées invalide") }
        var out: [SFTPDirectoryEntry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let name = try r.bytes()
            _ = try r.bytes() // longname, ignoré
            out.append(SFTPDirectoryEntry(nameBytes: name, attributes: try r.attributes()))
        }
        return out
    }

    /// Ferme un handle (jamais annulable : sert au nettoyage). Erreurs avalées si `ignoringErrors`.
    func closeHandle(_ handle: Data, ignoringErrors: Bool) async throws {
        do {
            let id = try send(SFTPPacket.close) { $0.bytes(handle) }
            try expectOK(try await receive(id, cancellable: false))
        } catch { if !ignoringErrors { throw error } }
    }

    // MARK: - Opérations publiques

    /// Chemin canonique absolu (REALPATH). Décodé en UTF-8 (lossy).
    public func realpath(_ path: some SFTPPathRepresentable) async throws -> String {
        let p = path.sftpBytes
        let resp = try await call(SFTPPacket.realpath) { $0.bytes(p) }
        if resp.type == SFTPPacket.status { try expectOK(resp); throw SFTPError.protocolViolation("OK inattendu") }
        guard let first = try expectNames(resp).first else { throw SFTPError.protocolViolation("REALPATH vide") }
        return first.name
    }

    /// Attributs en suivant les liens symboliques.
    public func stat(_ path: some SFTPPathRepresentable) async throws -> SFTPAttributes {
        let p = path.sftpBytes
        return try expectAttributes(try await call(SFTPPacket.stat) { $0.bytes(p) })
    }

    /// Attributs sans suivre les liens symboliques.
    public func lstat(_ path: some SFTPPathRepresentable) async throws -> SFTPAttributes {
        let p = path.sftpBytes
        return try expectAttributes(try await call(SFTPPacket.lstat) { $0.bytes(p) })
    }

    /// Cible d'un lien symbolique.
    public func readlink(_ path: some SFTPPathRepresentable) async throws -> String {
        let p = path.sftpBytes
        let resp = try await call(SFTPPacket.readlink) { $0.bytes(p) }
        if resp.type == SFTPPacket.status { try expectOK(resp); throw SFTPError.protocolViolation("OK inattendu") }
        guard let first = try expectNames(resp).first else { throw SFTPError.protocolViolation("READLINK vide") }
        return first.name
    }

    /// Liste un dossier (OPENDIR/READDIR/CLOSE) sans `.` ni `..`. Les types viennent des permissions (sans suivre les liens).
    public func listDirectory(_ path: some SFTPPathRepresentable) async throws -> [SFTPDirectoryEntry] {
        let p = path.sftpBytes
        let handle = try expectHandle(try await call(SFTPPacket.opendir) { $0.bytes(p) })
        var entries: [SFTPDirectoryEntry] = []
        do {
            while true {
                let resp = try await call(SFTPPacket.readdir) { $0.bytes(handle) }
                if resp.type == SFTPPacket.status {
                    var r = SFTPReader(resp.payload)
                    if SFTPStatusCode(rawValue: try r.u32()) == .eof { break }
                    try expectOK(resp)
                    throw SFTPError.protocolViolation("OK inattendu pendant READDIR")
                }
                for e in try expectNames(resp) where e.nameBytes != Data(".".utf8) && e.nameBytes != Data("..".utf8) {
                    entries.append(e)
                }
            }
        } catch {
            try? await closeHandle(handle, ignoringErrors: true)
            throw error
        }
        try await closeHandle(handle, ignoringErrors: true)
        return entries
    }

    public func mkdir(_ path: some SFTPPathRepresentable, permissions: UInt32 = 0o755) async throws {
        let p = path.sftpBytes
        try expectOK(try await call(SFTPPacket.mkdir) { $0.bytes(p); $0.attrs(permissions: permissions, accessTime: nil, modificationTime: nil) })
    }

    public func rmdir(_ path: some SFTPPathRepresentable) async throws {
        let p = path.sftpBytes
        try expectOK(try await call(SFTPPacket.rmdir) { $0.bytes(p) })
    }

    /// Supprime un fichier (ou lien).
    public func remove(_ path: some SFTPPathRepresentable) async throws {
        let p = path.sftpBytes
        try expectOK(try await call(SFTPPacket.remove) { $0.bytes(p) })
    }

    /// Renomme ; remplace la destination si `posix-rename@openssh.com` est annoncée, sinon SSH_FXP_RENAME
    /// (qui échoue si la destination existe, selon le serveur).
    public func rename(_ from: some SFTPPathRepresentable, to: some SFTPPathRepresentable) async throws {
        let a = from.sftpBytes, b = to.sftpBytes
        if serverExtensions["posix-rename@openssh.com"] != nil {
            try expectOK(try await call(SFTPPacket.extended) { $0.string("posix-rename@openssh.com"); $0.bytes(a); $0.bytes(b) })
        } else {
            try expectOK(try await call(SFTPPacket.rename) { $0.bytes(a); $0.bytes(b) })
        }
    }

    /// Modifie permissions et/ou dates. En v3 atime et mtime vont ensemble : si une seule est donnée, l'autre prend la même valeur.
    public func setstat(_ path: some SFTPPathRepresentable, permissions: UInt32? = nil,
                        modificationTime: Date? = nil, accessTime: Date? = nil) async throws {
        let p = path.sftpBytes
        let m = (modificationTime ?? accessTime).map { UInt32(clamping: Int64($0.timeIntervalSince1970)) }
        let a = (accessTime ?? modificationTime).map { UInt32(clamping: Int64($0.timeIntervalSince1970)) }
        try expectOK(try await call(SFTPPacket.setstat) { $0.bytes(p); $0.attrs(permissions: permissions, accessTime: a, modificationTime: m) })
    }
}
