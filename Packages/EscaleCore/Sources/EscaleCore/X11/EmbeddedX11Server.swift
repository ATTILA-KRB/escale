import Foundation
import CEscaleX11

/// Serveur X11 intégré : `Contents/Helpers/EscaleX11.app` (serveur Xquartz du paquet XQuartz, rendu autonome par
/// `scripts/x11-bundle.sh`). Remplace l'installation de XQuartz : aucun sudo, aucun `/opt/X11`, aucun `/tmp/.X11-unix`.
public struct EmbeddedX11Bundle: Sendable, Equatable {
    public let appPath: String
    /// Nom bootstrap (Mach) sous lequel le serveur s'enregistre : son CFBundleIdentifier.
    public let serviceName: String

    public init(appPath: String, serviceName: String) {
        self.appPath = appPath; self.serviceName = serviceName
    }

    public static let helperName = "EscaleX11.app"

    /// Le serveur embarqué dans `appBundle` (`Contents/Helpers/EscaleX11.app`), ou `nil` s'il manque.
    public static func inside(appBundle: URL, fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> EmbeddedX11Bundle? {
        let app = appBundle.appendingPathComponent("Contents/Helpers/\(helperName)").path
        let b = EmbeddedX11Bundle(appPath: app, serviceName: "")
        guard fileExists(b.serverPath), fileExists(b.xauthPath) else { return nil }
        let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        guard let id = plist?["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        return EmbeddedX11Bundle(appPath: app, serviceName: id)
    }

    public var macOSDir: String { appPath + "/Contents/MacOS" }
    public var serverPath: String { macOSDir + "/X11.bin" }
    public var xauthPath: String { macOSDir + "/xauth" }
    public var xkbDir: String { appPath + "/Contents/Resources/xkb" }
    public var fontDir: String { appPath + "/Contents/Resources/fonts/misc/" }
}

public enum EmbeddedX11Error: Error, Equatable, Sendable, CustomStringConvertible {
    case runtimeDirectory(String)
    case launch(String)
    case handoff(String)
    case socket(String)

    public var description: String {
        switch self {
        case .runtimeDirectory(let s): return "Dossier du serveur X11 intégré inutilisable : \(s)"
        case .launch(let s): return "Le serveur X11 intégré ne démarre pas : \(s)"
        case .handoff(let s): return s
        case .socket(let s): return "Socket X11 : \(s)"
        }
    }
}

/// Pilote du serveur intégré. Démarrage à la demande (`ensureRunning`, bloquant : hors du fil principal), arrêt
/// par pid (`stop`, invariant 9). Mécanisme : le serveur est lancé en `--listenonly` (attente Mach), Escale crée
/// elle-même le socket d'écoute dans un dossier privé 0700, le lui remet (SCM_RIGHTS), puis lui envoie ses arguments.
/// Un serveur déjà enregistré (instance précédente tuée, ou autre instance d'Escale) est réutilisé : on lui remet
/// simplement notre socket.
public final class EmbeddedX11Server: @unchecked Sendable {
    public let bundle: EmbeddedX11Bundle
    /// Dossier privé (0700) : socket `x11:0` (= DISPLAY), HOME du serveur (journaux, socket xtrans de secours).
    public let runtimeDirectory: String

    private let lock = NSLock()
    private var process: Process?
    private var handedOff = false
    private var displayNumber: Int?

    public init(bundle: EmbeddedX11Bundle, runtimeDirectory: String) {
        self.bundle = bundle; self.runtimeDirectory = runtimeDirectory
    }

    /// Dossier par défaut : court (socket limité à ~104 octets, invariant 6), propre à ce processus.
    public static func defaultRuntimeDirectory(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("escale-x11.\(pid)")
    }

    /// Valeur de DISPLAY : chemin du socket (forme XQuartz `…/nom:0`, comprise par ssh, xauth et xcb).
    public var display: String { runtimeDirectory + "/x11:0" }
    /// Fichier d'autorité privé (vide au départ) : évite que ssh et xauth écrivent ou réclament `~/.Xauthority`.
    public var xauthority: String { runtimeDirectory + "/Xauthority" }

    public var serverPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process.map { $0.isRunning ? $0.processIdentifier : nil } ?? nil
    }

    /// Réglages ssh correspondants.
    public func settings(trusted: Bool) -> X11Settings {
        X11Settings(trusted: trusted, xauthPath: bundle.xauthPath, display: display, xauthority: xauthority)
    }

    /// Garantit un serveur qui accepte les clients sur `display`. Idempotent ; BLOQUANT (jusqu'à `timeout`).
    public func ensureRunning(timeout: Double = 10) throws {
        lock.lock(); defer { lock.unlock() }
        let ms = Int32(max(timeout, 0.5) * 1000)
        let ownAlive = process?.isRunning ?? false
        if handedOff, FileManager.default.fileExists(atPath: display), ownAlive || Self.isRegistered(bundle.serviceName) {
            return
        }
        try prepareDirectory()

        var launchedHere = false
        if !Self.isRegistered(bundle.serviceName) {
            if let p = process, p.isRunning { Self.kill(p) }
            process = try launch()
            launchedHere = true
        }

        let fd = try listeningSocket()
        defer { close(fd) }
        var err = [CChar](repeating: 0, count: 512)
        let rc = escale_x11_handoff(bundle.serviceName, fd, ms, &err, err.count)
        guard rc == 0 else {
            if launchedHere, let p = process { Self.kill(p); process = nil }
            throw EmbeddedX11Error.handoff(String(cString: err))
        }
        if launchedHere { startServer() }
        handedOff = true
    }

    /// Arrête le serveur lancé par cette instance (pid précis ; SIGTERM est ignoré par Xquartz : SIGKILL) et
    /// supprime le dossier privé. Un serveur réutilisé appartenant à une autre instance n'est jamais touché.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let p = process {
            let pid = p.processIdentifier
            Self.kill(p)
            // SIGKILL laisse le verrou /tmp/.X<n>-lock : on retire le nôtre (il contient le pid du serveur).
            if let n = displayNumber, let lock = try? String(contentsOfFile: "/tmp/.X\(n)-lock", encoding: .utf8),
               Int32(lock.trimmingCharacters(in: .whitespacesAndNewlines)) == pid { unlink("/tmp/.X\(n)-lock") }
        }
        process = nil
        handedOff = false
        displayNumber = nil
        try? FileManager.default.removeItem(atPath: runtimeDirectory)
    }

    // MARK: Interne

    private func prepareDirectory() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory)
            // Le serveur journalise dans $HOME/Library/Logs/X11 (fatal si absent).
            try fm.createDirectory(atPath: runtimeDirectory + "/Library/Logs/X11", withIntermediateDirectories: true)
            if !fm.fileExists(atPath: xauthority) {
                guard fm.createFile(atPath: xauthority, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                    throw EmbeddedX11Error.runtimeDirectory("création de Xauthority")
                }
            }
        } catch let e as EmbeddedX11Error { throw e } catch {
            throw EmbeddedX11Error.runtimeDirectory(error.localizedDescription)
        }
        guard display.utf8.count < 104 else { throw EmbeddedX11Error.runtimeDirectory("chemin trop long : \(display)") }
    }

    private var serverEnvironment: [String: String] {
        // HOME : le serveur y fait chdir (socket xtrans relatif, journaux). PATH : xkbcomp du paquet.
        ["HOME": runtimeDirectory, "PATH": bundle.macOSDir + ":/usr/bin:/bin:/usr/sbin:/sbin",
         "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory()]
    }

    private func launch() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bundle.serverPath)
        p.arguments = ["--listenonly"]
        p.environment = serverEnvironment
        p.currentDirectoryURL = URL(fileURLWithPath: runtimeDirectory)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw EmbeddedX11Error.launch(error.localizedDescription) }
        return p
    }

    /// Envoie les arguments au serveur (appel Mach qui ne rend la main qu'à l'arrêt du serveur : fil dédié).
    private func startServer() {
        let n = Self.freeDisplayNumber()
        displayNumber = n
        let args = ["Xquartz", ":\(n)", "-nolisten", "tcp", "-noreset",
                    "-xkbdir", bundle.xkbDir, "-fp", bundle.fontDir]
        let env = serverEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        let service = bundle.serviceName
        let t = Thread {
            Self.withCStrings(args) { av in
                Self.withCStrings(env) { ev in
                    _ = escale_x11_start(service, av, Int32(args.count), ev, Int32(env.count))
                }
            }
        }
        t.name = "EscaleX11.start"
        t.start()
    }

    /// Socket Unix en écoute sur `display` (recréé : un ancien socket est remplacé).
    private func listeningSocket() throws -> Int32 {
        unlink(display)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmbeddedX11Error.socket(String(cString: strerror(errno))) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(display.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw EmbeddedX11Error.socket("chemin trop long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard ok == 0, listen(fd, 64) == 0 else {
            let e = String(cString: strerror(errno)); close(fd); throw EmbeddedX11Error.socket(e)
        }
        chmod(display, 0o600)
        return fd
    }

    /// Numéro d'écran sans verrou `/tmp/.X<n>-lock` (le serveur en crée un ; `-nolock` est réservé à root).
    /// Sans écoute TCP, le numéro ne sert qu'à ce verrou et au nom du journal.
    static func freeDisplayNumber(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        (64...199).first { !fileExists("/tmp/.X\($0)-lock") } ?? 64
    }

    static func isRegistered(_ service: String) -> Bool { escale_x11_lookup(service) == 0 }

    private static func kill(_ p: Process) {
        guard p.isRunning else { return }
        Darwin.kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let dup = strings.map { strdup($0) }
        defer { dup.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
