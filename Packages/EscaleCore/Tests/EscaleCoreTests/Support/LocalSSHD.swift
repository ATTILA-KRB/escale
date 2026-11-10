import Foundation
@testable import EscaleCore

/// sshd local non privilégié (127.0.0.1, port libre, sans sudo, sans PAM) pour les tests d'intégration.
/// Toutes les clés et la configuration vivent dans un dossier temporaire supprimé par `stop()`.
/// Ne touche JAMAIS `~/.ssh` et n'utilise aucune clé de l'utilisateur.
final class LocalSSHD: @unchecked Sendable {
    struct Options: Sendable {
        var allowTcpForwarding = true
        var maxSessions = 10
        /// Nombre de clés autorisées à se connecter (la clé « mauvaise » n'est jamais autorisée).
        var extra: [String] = []
        /// Active `PasswordAuthentication` : ssh pose alors l'invite de mot de passe (askpass), mais sans PAM (non privilégié)
        /// sshd ne peut JAMAIS valider un mot de passe : l'authentification échoue toujours.
        var passwordAuthentication = false
    }

    struct StartError: Error, CustomStringConvertible {
        var description: String
    }

    static let sshdPath = "/usr/sbin/sshd"
    static let keygenPath = "/usr/bin/ssh-keygen"

    /// nil si sshd peut démarrer ici ; sinon la raison (utilisée par `.enabled(if:)` pour désactiver explicitement).
    static let unavailableReason: String? = {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: sshdPath) else { return "\(sshdPath) introuvable" }
        guard fm.isExecutableFile(atPath: keygenPath) else { return "\(keygenPath) introuvable" }
        do { let d = try LocalSSHD.start(Options()); d.stop(); return nil }
        catch { return "sshd local non démarrable : \(error)" }
    }()
    static var isAvailable: Bool { unavailableReason == nil }

    let directory: String
    let port: Int
    let user = NSUserName()
    var clientKey: String { "\(directory)/client" }
    /// Clé valide côté client mais absente de authorized_keys (échec d'authentification).
    var wrongKey: String { "\(directory)/wrong" }
    /// Clé autorisée mais protégée par la phrase de passe `LocalSSHD.passphrase` (ssh la demande via askpass).
    var passphraseKey: String { "\(directory)/ppkey" }
    static let passphrase = "escale-test-passphrase"
    /// Clé publique d'hôte (`ssh-ed25519 AAAA…`) du sshd de test.
    func hostPublicKeyFields() throws -> String {
        try String(contentsOfFile: "\(directory)/hostkey.pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    }
    /// Crée un known_hosts de test : vide, ou avec une AUTRE clé d'hôte pour ce sshd (clé « modifiée »).
    func makeKnownHosts(named name: String, withChangedHostKey: Bool = false) throws -> String {
        let path = "\(directory)/\(name)"
        var content = ""
        if withChangedHostKey {
            let other = "\(directory)/otherhost"
            if !FileManager.default.fileExists(atPath: other) {
                try Self.run(Self.keygenPath, ["-q", "-t", "ed25519", "-N", "", "-C", "escale-other", "-f", other])
            }
            let fields = try String(contentsOfFile: other + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
            content = "[127.0.0.1]:\(port) \(fields)\n"
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    var knownHosts: String { "\(directory)/known_hosts" }
    var logPath: String { "\(directory)/sshd.log" }
    private var process: Process?

    private init(directory: String, port: Int) { self.directory = directory; self.port = port }

    static func start(_ options: Options = Options()) throws -> LocalSSHD {
        let base = NSTemporaryDirectory()
        var template = Array("\(base.hasSuffix("/") ? base : base + "/")escale-sshd-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw StartError(description: "mkdtemp a échoué (errno \(errno))") }
        let dir = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var lastError = "aucune tentative"
        do {
            for _ in 0..<4 {
                let port = try freePort()
                let d = LocalSSHD(directory: dir, port: port)
                do { try d.setUpAndLaunch(options); return d }
                catch { d.terminateProcess(); lastError = "\(error)" }
            }
        }
        try? FileManager.default.removeItem(atPath: dir)
        throw StartError(description: lastError)
    }

    private func setUpAndLaunch(_ options: Options) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        for name in ["hostkey", "client", "wrong"] where !fm.fileExists(atPath: "\(directory)/\(name)") {
            try Self.run(Self.keygenPath, ["-q", "-t", "ed25519", "-N", "", "-C", "escale-test", "-f", "\(directory)/\(name)"])
        }
        if !fm.fileExists(atPath: passphraseKey) {
            try Self.run(Self.keygenPath, ["-q", "-t", "ed25519", "-N", Self.passphrase, "-C", "escale-test-pp", "-f", passphraseKey])
        }
        let pub = try String(contentsOfFile: "\(directory)/client.pub", encoding: .utf8)
            + String(contentsOfFile: "\(directory)/ppkey.pub", encoding: .utf8)
        try pub.write(toFile: "\(directory)/authorized_keys", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: "\(directory)/authorized_keys")
        // Les tests ignorent known_hosts de l'utilisateur : on enregistre la clé d'hôte du sshd de test.
        let hostPub = try String(contentsOfFile: "\(directory)/hostkey.pub", encoding: .utf8)
        let hostFields = hostPub.split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(port) \(hostFields)\n".write(toFile: knownHosts, atomically: true, encoding: .utf8)

        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(directory)/hostkey
        PidFile \(directory)/sshd.pid
        UsePAM no
        PasswordAuthentication \(options.passwordAuthentication ? "yes" : "no")
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AuthorizedKeysFile \(directory)/authorized_keys
        StrictModes no
        Subsystem sftp /usr/libexec/sftp-server
        AllowTcpForwarding \(options.allowTcpForwarding ? "yes" : "no")
        MaxSessions \(options.maxSessions)
        MaxStartups 100:30:200
        PrintMotd no
        LogLevel VERBOSE

        """
        try config.write(toFile: "\(directory)/sshd_config", atomically: true, encoding: .utf8)
        fm.createFile(atPath: logPath, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.sshdPath)
        p.arguments = ["-D", "-e", "-f", "\(directory)/sshd_config"]
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        p.standardOutput = logHandle; p.standardError = logHandle; p.standardInput = FileHandle.nullDevice
        try p.run()
        try? logHandle.close()
        process = p

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !p.isRunning { throw StartError(description: "sshd a quitté (code \(p.terminationStatus)) : \(self.log())") }
            if Self.portAccepts(port) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw StartError(description: "sshd ne répond pas sur le port \(port) : \(log())")
    }

    private func terminateProcess() {
        guard let p = process else { return }
        // Les sessions sont des processus fils (sshd-session) : on les arrête d'abord.
        _ = try? Self.run("/usr/bin/pkill", ["-TERM", "-P", String(p.processIdentifier)])
        if p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        process = nil
    }

    /// Arrête sshd et supprime le dossier temporaire. Idempotent, sans erreur.
    func stop() {
        terminateProcess()
        try? FileManager.default.removeItem(atPath: directory)
    }

    func log() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    /// Nombre d'authentifications réussies vues par sshd (une par connexion TCP authentifiée).
    func acceptedAuthenticationCount() -> Int {
        log().components(separatedBy: "Accepted publickey").count - 1
    }

    // MARK: - Aides pour les tests

    func profile(auth: HostProfile.Auth? = nil, jumpHosts: [String] = []) -> HostProfile {
        HostProfile(name: "local", host: "127.0.0.1", port: port, user: user,
                    auth: auth ?? .keyFile(path: clientKey), jumpHosts: jumpHosts)
    }

    /// Options ssh isolées : pas de ~/.ssh/config, known_hosts de test, pas d'agent.
    func sshOptions(extra: [String] = []) -> OpenSSHOptions {
        OpenSSHOptions(
            configFile: "/dev/null", userKnownHostsFile: knownHosts, strictHostKeyChecking: .yes,
            connectTimeout: 5, extraOptions: ["IdentityAgent=none", "GlobalKnownHostsFile=/dev/null"] + extra)
    }

    /// Exécute `body` avec un sshd frais, et le nettoie même en cas d'échec ou d'annulation.
    static func with<T>(_ options: Options = Options(), _ body: (LocalSSHD) async throws -> T) async throws -> T {
        let d = try start(options)
        do { let r = try await body(d); d.stop(); return r }
        catch { d.stop(); throw error }
    }

    // MARK: - Interne

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 && path != "/usr/bin/pkill" { throw StartError(description: "\(path) code \(p.terminationStatus)") }
        return p.terminationStatus
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError(description: "socket errno \(errno)") }
        defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        let b = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0 else { throw StartError(description: "bind errno \(errno)") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    static func portAccepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = in_port_t(port).bigEndian
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
