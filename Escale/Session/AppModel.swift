import AppKit
import Foundation
import Observation
import EscaleCore

/// Demande d'ouverture d'une feuille d'édition.
enum EditorRequest: Identifiable {
    case newHost(folder: UUID?)
    case editHost(HostProfile)
    case newFolder(parent: UUID?)
    case renameFolder(HostFolder)

    var id: String {
        switch self {
        case .newHost(let f): "new-host-\(f?.uuidString ?? "root")"
        case .editHost(let h): "edit-\(h.id)"
        case .newFolder(let p): "new-folder-\(p?.uuidString ?? "root")"
        case .renameFolder(let f): "rename-\(f.id)"
        }
    }
}

/// Suppression en attente de confirmation.
enum DeletionRequest: Identifiable {
    case host(HostProfile)
    case folder(HostFolder)
    var id: UUID { switch self { case .host(let h): h.id; case .folder(let f): f.id } }
}

/// État racine : bibliothèque, connexions, onglets, et orchestration du cycle de vie des shells.
@MainActor
@Observable
final class AppModel {
    /// Identifiant de l'entrée « Terminal local » de la barre latérale.
    static let localTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let options: LaunchOptions
    let library: LibraryStore
    let connections: ConnectionManager
    let workspace = Workspace()

    var searchText = ""
    var editor: EditorRequest?
    var pendingDeletion: DeletionRequest?
    var collapsedFolders: Set<UUID> = []

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isShuttingDown = false

    init(options: LaunchOptions) {
        self.options = options
        let url = options.libraryPath.map { URL(fileURLWithPath: $0) } ?? ProvisionalJSONHostRepository.defaultURL
        library = LibraryStore(repository: ProvisionalJSONHostRepository(url: url))
        var ssh = OpenSSHOptions(
            configFile: options.sshConfig, userKnownHostsFile: options.knownHosts,
            strictHostKeyChecking: options.knownHosts != nil ? .yes : nil, extraOptions: options.sshOptions)
        // Auth par clés/agent uniquement pour l'instant : BatchMode (jamais d'invite) est le défaut du cœur.
        ssh.batchMode = true
        connections = ConnectionManager(sshOptions: ssh)
    }

    /// Environnement du fils : celui de l'app + TERM/COLORTERM (+ LANG UTF-8 si absent, cas Finder).
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Escale"
        if env["LANG"] == nil && env["LC_ALL"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    private static func resolve(_ name: String) -> String {
        if name.contains("/") { return name }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let c = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return name
    }

    // MARK: Démarrage

    /// Appelé une fois par la fenêtre : charge la bibliothèque puis lance l'éventuel scénario ou `--command`.
    func start() async {
        guard !started else { return }
        started = true
        await library.load()
        if let dir = options.selftestSSHDirectory {
            let runner = SSHSelfTest(directory: dir, model: self)
            Task { @MainActor in
                let ok = await runner.run()
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let dir = options.selftestDirectory {
            let tab = openLocalTab(command: ["/bin/zsh", "-f", "-i"]) // shell reproductible, sans rc utilisateur
            let runner = SelfTest(directory: dir, model: self, tab: tab)
            Task { @MainActor in
                let ok = await runner.run()
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let cmd = options.command {
            openLocalTab(command: cmd)
        }
    }

    // MARK: Ouverture d'onglets

    @discardableResult
    func openLocalTab(command: [String]? = nil) -> TerminalTab {
        let title = command.map { ($0[0] as NSString).lastPathComponent } ?? "Terminal local"
        let tab = TerminalTab(kind: .local(command: command), baseTitle: title)
        workspace.add(tab)
        start(tab)
        return tab
    }

    /// « Connecter » : réutilise l'onglet existant de l'hôte s'il y en a un, sinon en ouvre un.
    func connect(_ host: HostProfile) {
        if let t = workspace.tabs(forHost: host.id).first { workspace.select(t.id) } else { newTab(host) }
    }

    @discardableResult
    func newTab(_ host: HostProfile) -> TerminalTab {
        // Plusieurs onglets du même hôte : « Hôte », « Hôte 2 », « Hôte 3 »… (titres distinguables).
        var n = workspace.tabs(forHost: host.id).count + 1
        while workspace.tabs.contains(where: { $0.hostID == host.id && $0.baseTitle == (n == 1 ? host.name : "\(host.name) \(n)") }) { n += 1 }
        let tab = TerminalTab(kind: .host(host), baseTitle: n == 1 ? host.name : "\(host.name) \(n)")
        workspace.add(tab)
        start(tab)
        return tab
    }

    func start(_ tab: TerminalTab) {
        tab.startTask?.cancel()
        tab.status = .connecting
        tab.startTask = Task { await self.run(tab) }
    }

    /// Fermeture d'un onglet : tue le pty (le gestionnaire de fin appelle `shellSessionDidEnd()` une fois)
    /// et libère la connexion (déconnexion différée si c'était le dernier).
    func close(_ tab: TerminalTab) {
        guard !tab.isClosing else { return }
        tab.isClosing = true
        tab.startTask?.cancel()
        workspace.remove(tab)
        tab.session.kill()
        if let link = tab.link { tab.link = nil; link.release() }
    }

    func closeActiveTab() { if let t = workspace.activeTab { close(t) } }

    func disconnect(_ host: HostProfile) {
        for t in workspace.tabs(forHost: host.id) { close(t) }
        if let c = connections.existing(host.id) { Task { await c.shutdown() } }
    }

    func deleteHost(_ host: HostProfile) {
        disconnect(host)
        library.deleteHost(host.id)
    }

    // MARK: Cycle de vie d'un shell

    private func run(_ tab: TerminalTab) async {
        switch tab.kind {
        case .local(let command):
            launchLocal(tab, command: command)
        case .host(let profile):
            let conn = connections.connection(for: profile)
            let link = tab.link ?? conn.acquireLink()
            tab.link = link
            await launchRemote(tab, link: link)
        }
    }

    private func launchLocal(_ tab: TerminalTab, command: [String]?) {
        let (exe, args): (String, [String])
        if let cmd = command { (exe, args) = (Self.resolve(cmd[0]), Array(cmd.dropFirst())) } else {
            (exe, args) = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", ["-l"])
        }
        let s = tab.session.engine.size
        do {
            let p = try PTYProcess(executable: exe, arguments: args, environment: Self.environment(),
                                   columns: s.columns, rows: s.rows, currentDirectory: NSHomeDirectory())
            tab.session.attach(p) { [weak tab] status in
                guard let tab, !tab.isClosing else { return }
                tab.status = .ended(status)
            }
            tab.status = .running
        } catch {
            tab.status = .failed("lancement de \(exe) impossible : \(error)")
        }
    }

    /// Connexion (si besoin) puis shell distant dans un pty ; reprend en boucle si le maître meurt entre-temps.
    private func launchRemote(_ tab: TerminalTab, link: SSHLink) async {
        var attempts = 0
        while !tab.isClosing, !Task.isCancelled {
            do {
                try await link.ensureConnected()
                if tab.isClosing { return }
                let cmd = try await link.transport.shellCommand()
                connections.shellsStarted += 1
                var env = Self.environment()
                for (k, v) in cmd.environment { env[k] = v }
                let s = tab.session.engine.size
                let p: PTYProcess
                do {
                    p = try PTYProcess(executable: cmd.executable, arguments: cmd.arguments, environment: env,
                                       columns: s.columns, rows: s.rows)
                } catch {
                    await link.transport.shellSessionDidEnd()
                    connections.shellsEnded += 1
                    tab.status = .failed("lancement de ssh impossible : \(error)")
                    return
                }
                tab.launchEpoch = link.epoch
                tab.session.attach(p) { [weak self, weak tab] status in
                    guard let self, let tab else { return }
                    Task { await self.remoteShellEnded(tab, link: link, status: status) }
                }
                tab.status = .running
                return
            } catch SSHTransportError.notConnected where attempts < 3 {
                // Le maître est mort sans que personne ne s'en soit aperçu : même chemin qu'une coupure.
                attempts += 1
                tab.status = .reconnecting
                link.handleConnectionLost()
                _ = await link.waitReconnect()
            } catch {
                if tab.isClosing || Task.isCancelled { return }
                tab.status = .failed(SSHLink.describe(error))
                return
            }
        }
    }

    /// Fin d'un shell distant (appelée une fois par processus).
    private func remoteShellEnded(_ tab: TerminalTab, link: SSHLink, status: PTYExitStatus) async {
        await link.transport.shellSessionDidEnd()
        connections.shellsEnded += 1
        if tab.isClosing || isShuttingDown { return }
        let alive = await link.transport.isAlive()
        let lost = !alive || link.epoch != tab.launchEpoch
        guard lost else { tab.status = .ended(status); return }
        // Connexion tombée : l'écran est conservé, tous les onglets du maître partagent une seule reconnexion.
        tab.status = .reconnecting
        link.handleConnectionLost()
        let ok = await link.waitReconnect()
        if tab.isClosing || isShuttingDown { return }
        guard ok else { tab.status = .failed("reconnexion abandonnée"); return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space))
        tab.session.appendSeparator("Connexion rétablie le \(stamp)")
        await launchRemote(tab, link: link)
    }

    /// « Reconnecter maintenant » (bandeau) ou « Réessayer » (échec).
    func retry(_ tab: TerminalTab) {
        switch tab.status {
        case .reconnecting: tab.link?.retryNow()
        case .failed, .ended: start(tab)
        default: break
        }
    }

    // MARK: Arrêt

    /// Tue tous les pty et déconnecte tous les maîtres (aucun ssh résiduel).
    func shutdown() async {
        isShuttingDown = true
        for t in workspace.tabs { t.isClosing = true; t.startTask?.cancel(); t.session.kill() }
        await connections.shutdownAll()
        // Laisse les gestionnaires de fin de pty compter leurs shells.
        for _ in 0..<40 where connections.shellsEnded < connections.shellsStarted {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
