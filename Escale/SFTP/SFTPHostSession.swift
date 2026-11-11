import AppKit
import Foundation
import Observation
import EscaleCore

/// Politique en cas de fichier distant déjà présent lors d'un envoi.
enum SFTPOverwritePolicy { case ask, replace }

/// Navigateur SFTP d'un hôte : un client SFTP porté par un lien maître (jamais de nouvelle authentification),
/// le dossier courant, sa liste, l'historique et les opérations de fichiers.
@MainActor
@Observable
final class SFTPHostSession: Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        /// Connexion perdue : le canal est rouvert dès que le lien est rétabli.
        case lost
        case failed(String)
    }

    let profile: HostProfile
    let id: UUID

    private(set) var state: State = .idle
    /// Dossier courant (octets).
    private(set) var path = Data("/".utf8)
    private(set) var items: [SFTPItem] = []
    private(set) var isLoading = false
    /// Dernière erreur d'une opération (affichée en bandeau, effaçable).
    var errorMessage: String?
    var selection: Set<Data> = []
    var showHidden = false
    private(set) var home: String?
    private(set) var back: [Data] = []
    private(set) var forward: [Data] = []
    /// SFTP, ou repli sur des commandes shell quand le serveur refuse le sous-système SFTP.
    private(set) var fsKind: RemoteFileSystemKind = .sftp
    /// Raison du repli (bandeau « Mode shell »).
    private(set) var shellReason: String?
    /// Tri de la liste (persistant, commun à tous les hôtes). Les dossiers restent toujours en premier.
    var sort: SFTPSort = SFTPSort.stored {
        didSet {
            guard sort != oldValue else { return }
            sort.save()
            items = sort.sorted(items)
        }
    }
    /// Repli déjà constaté : on ne retente pas le SFTP à chaque réouverture (une session du maître de moins).
    @ObservationIgnored private var shellForced = false

    @ObservationIgnored private(set) var client: (any RemoteFileSystem)?
    @ObservationIgnored private(set) var link: SSHLink?
    /// Lien pris par le navigateur seul (aucun onglet de l'hôte) : relâché à la fermeture.
    @ObservationIgnored private var ownedLink: SSHLink?
    @ObservationIgnored private unowned let feature: SFTPFeature
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPath: Data?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Nombre de canaux SFTP ouverts depuis le début (tests : un seul par connexion).
    @ObservationIgnored private(set) var channelsOpened = 0

    init(profile: HostProfile, feature: SFTPFeature) {
        self.profile = profile; self.id = profile.id; self.feature = feature
    }

    var pathString: String { SFTPPath.string(path) }
    var visibleItems: [SFTPItem] { showHidden ? items : items.filter { !$0.name.hasPrefix(".") } }
    var canGoUp: Bool { path != Data("/".utf8) }
    var selectedItems: [SFTPItem] { items.filter { selection.contains($0.id) } }
    var isReady: Bool { state == .ready }
    var isShellMode: Bool { fsKind == .shell }

    // MARK: Ouverture du canal

    /// Ouvre (ou rouvre) le canal SFTP sur la connexion maître de l'hôte. Idempotent.
    func open() async {
        if let t = openTask { await t.value; return }
        if state == .ready, client != nil { return }
        let t = Task { @MainActor in await self.doOpen() }
        openTask = t
        await t.value
        openTask = nil
    }

    private func doOpen() async {
        state = .connecting
        errorMessage = nil
        do {
            let (client, link) = try await openClient()
            self.client = client
            self.link = link
            fsKind = client.kind
            channelsOpened += 1
            if home == nil { home = try await client.canonicalPath(Data(".".utf8)) }
            let target = pendingPath ?? (path == Data("/".utf8) && items.isEmpty ? Data((home ?? "/").utf8) : path)
            pendingPath = nil
            state = .ready
            // Reprise automatique des transferts interrompus par la perte du lien.
            feature.transfers.resumeInterrupted(for: self)
            await load(target, record: false)
        } catch {
            client = nil
            state = .failed(SFTPMessages.describe(error))
        }
    }

    /// Choisit le lien (celui des onglets de l'hôte, sinon un lien pris pour l'occasion), attend qu'il soit connecté,
    /// puis ouvre le canal. Le transport compte la session (`sessionCount`, plafond MaxSessions : invariant 5).
    private func openClient() async throws -> (any RemoteFileSystem, SSHLink) {
        let model = feature.requireModel
        let conn = model.connections.connection(for: profile)
        var candidates: [SSHLink] = []
        for tab in model.workspace.tabs(forHost: profile.id) { for p in tab.panes { if let l = p.link, !candidates.contains(where: { $0 === l }) { candidates.append(l) } } }
        for l in conn.links where !candidates.contains(where: { $0 === l }) { candidates.append(l) }
        if candidates.isEmpty {
            let l = conn.acquireLink()
            ownedLink = l
            candidates = [l]
        }
        var lastError: Error = SSHTransportError.notConnected
        for l in candidates {
            do {
                try await l.ensureConnected()
                let opening = try await RemoteFileSystemOpener.open(transport: l.transport, forceShell: shellForced)
                if opening.kind == .shell { shellForced = true }
                shellReason = opening.fallbackReason
                return (opening.fileSystem, l)
            } catch SSHTransportError.sessionRefused(let m) {
                lastError = SSHTransportError.sessionRefused(m) // lien plein : on essaie le suivant
            }
        }
        throw lastError
    }

    /// Ferme le canal et relâche le lien éventuellement possédé.
    func close() async {
        openTask?.cancel()
        refreshTask?.cancel()
        if let c = client { client = nil; await c.close() }
        state = .idle
        if let l = ownedLink { ownedLink = nil; l.release() }
        link = nil
    }

    /// Le canal est mort (lien perdu, ssh tué) : on attend le rétablissement du lien.
    func channelLost() {
        guard state != .lost else { return }
        if let c = client { client = nil; Task { await c.close() } }
        state = .lost
        isLoading = false
        if let l = link, l.state == .connected {
            // Seul le canal est mort : on le rouvre sans attendre.
            Task { await self.reopen() }
        }
    }

    /// Lien rétabli : nouveau canal, rechargement du dossier courant.
    func reopen() async {
        guard state == .lost || { if case .failed = state { true } else { false } }() else { return }
        await open()
    }

    // MARK: Navigation

    private func load(_ p: Data, record: Bool = true) async {
        guard let client else { return }
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let entries = try await client.listEntries(in: p)
            guard gen == generation else { return }
            var built: [SFTPItem] = []
            var symlinks = 0
            // En mode shell chaque `stat` est une session exec : on n'en résout qu'un petit nombre.
            let symlinkBudget = client.kind == .shell ? 40 : 300
            for e in entries {
                var isDir = e.type == .directory
                let isLink = e.type == .symlink
                var attrs = e.attributes
                let full = SFTPPath.join(p, e.nameBytes)
                if isLink, symlinks < symlinkBudget {
                    symlinks += 1
                    if let target = try? await client.attributes(of: full) { isDir = target.type == .directory; attrs = target }
                }
                built.append(SFTPItem(name: e.name, path: full, isDirectory: isDir, isSymlink: isLink,
                                      size: attrs.size, modified: attrs.modificationTime, permissions: e.attributes.permissions))
            }
            guard gen == generation else { return }
            built = sort.sorted(built)
            if record, p != path { back.append(path); forward.removeAll() }
            path = p
            items = built
            selection = selection.intersection(Set(built.map(\.id)))
            errorMessage = nil
        } catch {
            guard gen == generation else { return }
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if SFTPMessages.isChannelLoss(error) { channelLost() } else { errorMessage = SFTPMessages.describe(error) }
    }

    /// Va à un chemin saisi (`~`, relatif au dossier courant, ou absolu) après l'avoir canonisé.
    func navigate(to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var target = trimmed
        if target == "~" { target = home ?? "/" } else if target.hasPrefix("~/") { target = (home ?? "") + target.dropFirst(1) }
        else if !target.hasPrefix("/") { target = SFTPPath.string(SFTPPath.join(path, target)) }
        await navigate(toPath: Data(target.utf8))
    }

    func navigate(toPath p: Data) async {
        guard let client else { pendingPath = p; return }
        do {
            let real = Data(try await client.canonicalPath(p).utf8)
            let attrs = try await client.attributes(of: real)
            guard attrs.type == .directory else { errorMessage = "« \(SFTPPath.lastComponent(real)) » n'est pas un dossier."; return }
            await load(real)
        } catch { handle(error) }
    }

    func open(_ item: SFTPItem) async { if item.isDirectory { await navigate(toPath: item.path) } }
    func goUp() async { await navigate(toPath: SFTPPath.parent(path)) }
    func goBack() async {
        guard let p = back.popLast() else { return }
        forward.append(path)
        await load(p, record: false)
    }
    func goForward() async {
        guard let p = forward.popLast() else { return }
        back.append(path)
        await load(p, record: false)
    }
    func refresh() async { await load(path, record: false) }

    /// Nouveau dossier courant du terminal de l'hôte (OSC 7) : navigation silencieuse (pas d'erreur bavarde).
    func follow(directory p: String) async {
        let data = Data(p.utf8)
        if data == path { return }
        guard client != nil else { pendingPath = data; return }
        guard let client else { return }
        // Plusieurs `cd` rapprochés : seule la dernière demande compte (un `stat` plus lent ne doit pas l'écraser).
        followToken &+= 1
        let token = followToken
        if let attrs = try? await client.attributes(of: data), attrs.type == .directory, token == followToken { await load(data) }
    }
    @ObservationIgnored private var followToken = 0

    // MARK: Opérations

    func makeDirectory(_ name: String) async {
        guard let client, valid(name) else { return }
        let p = SFTPPath.join(path, name)
        do {
            try await client.makeDirectory(p)
            await refresh()
            selection = [p]
        } catch { handle(error) }
    }

    func rename(_ item: SFTPItem, to newName: String) async {
        guard let client, valid(newName), newName != item.name else { return }
        let dest = SFTPPath.join(SFTPPath.parent(item.path), newName)
        do {
            if (try? await client.attributes(of: dest, followLinks: false)) != nil { errorMessage = "« \(newName) » existe déjà."; return }
            try await client.renameItem(item.path, to: dest)
            await refresh()
            selection = [dest]
        } catch { handle(error) }
    }

    func delete(_ list: [SFTPItem]) async {
        guard let client else { return }
        do {
            for it in list {
                if it.isDirectory && !it.isSymlink { try await client.removeTree(it.path) } else { try await client.removeFile(it.path) }
            }
            await refresh()
        } catch { handle(error); await refresh() }
    }

    private func valid(_ name: String) -> Bool {
        if name.isEmpty || name.contains("/") || name == "." || name == ".." {
            errorMessage = "Nom invalide."
            return false
        }
        return true
    }

    // MARK: Transferts

    /// Envoie des fichiers/dossiers locaux dans `directory` (dossier courant par défaut).
    @discardableResult
    func upload(_ urls: [URL], into directory: Data? = nil, policy: SFTPOverwritePolicy = .ask) async -> [SFTPTransfer] {
        guard let client else { errorMessage = "Canal SFTP non ouvert."; return [] }
        let dir = directory ?? path
        if policy == .ask {
            var existing: [String] = []
            for u in urls where (try? await client.attributes(of: SFTPPath.join(dir, u.lastPathComponent), followLinks: false)) != nil { existing.append(u.lastPathComponent) }
            if !existing.isEmpty, !(await feature.confirmReplace(existing)) { return [] }
        }
        var made: [SFTPTransfer] = []
        do {
            for u in urls { made += try await expandUpload(u, to: SFTPPath.join(dir, u.lastPathComponent), client: client) }
        } catch { handle(error) }
        for t in made { feature.transfers.enqueue(t) }
        return made
    }

    private func expandUpload(_ local: URL, to remote: Data, client: any RemoteFileSystem) async throws -> [SFTPTransfer] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else {
            throw SFTPError.localIO("fichier introuvable : \(local.lastPathComponent)")
        }
        if !isDir.boolValue {
            return [SFTPTransfer(direction: .upload, name: local.lastPathComponent, local: local, remote: remote, session: self)]
        }
        do { try await client.makeDirectory(remote) } catch {
            guard let a = try? await client.attributes(of: remote), a.type == .directory else { throw error }
        }
        var out: [SFTPTransfer] = []
        let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
        for c in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            out += try await expandUpload(c, to: SFTPPath.join(remote, c.lastPathComponent), client: client)
        }
        return out
    }

    /// Télécharge dans `directory` (dossiers récursivement). Noms en collision : suffixe « 2 », « 3 »…
    @discardableResult
    func download(_ list: [SFTPItem], to directory: URL) async -> [SFTPTransfer] {
        guard let client else { errorMessage = "Canal SFTP non ouvert."; return [] }
        var made: [SFTPTransfer] = []
        do {
            for it in list {
                let dest = Self.uniqueURL(directory, it.name)
                made += try await expandDownload(path: it.path, isDirectory: it.isDirectory, name: it.name, to: dest, client: client)
            }
        } catch { handle(error) }
        for t in made { feature.transfers.enqueue(t) }
        return made
    }

    private func expandDownload(path: Data, isDirectory: Bool, name: String, to dest: URL, client: any RemoteFileSystem) async throws -> [SFTPTransfer] {
        guard isDirectory else {
            return [SFTPTransfer(direction: .download, name: name, local: dest, remote: path, session: self)]
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var out: [SFTPTransfer] = []
        for e in try await client.listEntries(in: path) {
            var isDir = e.type == .directory
            let full = SFTPPath.join(path, e.nameBytes)
            if e.type == .symlink, let t = try? await client.attributes(of: full) { isDir = t.type == .directory }
            if e.type == .other { continue }
            out += try await expandDownload(path: full, isDirectory: isDir, name: e.name,
                                            to: dest.appendingPathComponent(e.name, isDirectory: isDir), client: client)
        }
        return out
    }

    /// Téléchargement par défaut : ~/Downloads.
    @discardableResult
    func downloadToDownloads(_ list: [SFTPItem]) async -> [SFTPTransfer] {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        return await download(list, to: dir)
    }

    static func uniqueURL(_ dir: URL, _ name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        var n = 2
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Un transfert de cette session est terminé : recharge le dossier (regroupé) pour voir le résultat.
    func transferFinished(_ t: SFTPTransfer) {
        guard t.state == .done, t.direction == .upload else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.state == .ready else { return }
            await self.refresh()
        }
    }

    /// Télécharge un fichier dans un dossier temporaire (glisser vers le Finder) et rend son URL.
    func exportForDrag(_ item: SFTPItem) async throws -> URL {
        guard let client else { throw SFTPError.channelClosed("canal SFTP non ouvert") }
        let dir = feature.cachesRoot.appendingPathComponent("drag/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(item.name)
        try await client.download(item.path, to: dest)
        return dest
    }

    // MARK: Déplacer / copier (distant → distant)

    /// Déplace (renommage) ou copie `list` dans le dossier `directory` du même hôte. Un élément déjà présent à la
    /// destination n'est jamais écrasé (erreur affichée, les autres éléments sont traités). Renvoie le nombre traité.
    @discardableResult
    func move(_ list: [SFTPItem], into directory: Data, copy: Bool) async -> Int {
        guard let client else { errorMessage = "Canal SFTP non ouvert."; return 0 }
        var done = 0
        var problems: [String] = []
        for it in list {
            let dest = SFTPPath.join(directory, it.name)
            if SFTPPath.parent(it.path) == SFTPPath.normalized(directory) && !copy { continue } // déjà là
            if it.path == dest || SFTPPath.isInside(directory, of: it.path) {
                problems.append("« \(it.name) » ne peut pas être placé dans lui-même."); continue
            }
            do {
                if (try? await client.attributes(of: dest, followLinks: false)) != nil {
                    problems.append("« \(it.name) » existe déjà dans le dossier de destination."); continue
                }
                if copy { try await copyItem(it, to: dest, client: client) } else { try await client.renameItem(it.path, to: dest) }
                done += 1
            } catch {
                if SFTPMessages.isChannelLoss(error) { channelLost(); return done }
                problems.append("« \(it.name) » : \(SFTPMessages.describe(error))")
            }
        }
        await refresh()
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n") }
        if done > 0 { selection = Set(list.map { SFTPPath.join(directory, $0.name) }) }
        return done
    }

    /// Copie : `cp -a` par exec quand le serveur le permet (rapide, conserve droits et dates), sinon lecture/écriture SFTP.
    private func copyItem(_ it: SFTPItem, to dest: Data, client: any RemoteFileSystem) async throws {
        if client.kind == .sftp, let link {
            do { try await ShellFileSystem(executor: link.transport).copyItem(from: it.path, to: dest); return }
            catch {
                // Pas de shell (ou connexion perdue) : on ne retombe sur SFTP que si rien n'a été créé.
                if SFTPMessages.isChannelLoss(error) { throw error }
                if (try? await client.attributes(of: dest, followLinks: false)) != nil { throw error }
            }
        }
        try await client.copyItem(from: it.path, to: dest)
    }

    // MARK: Aides pour les tests

    func waitUntil(timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return cond()
    }
}
