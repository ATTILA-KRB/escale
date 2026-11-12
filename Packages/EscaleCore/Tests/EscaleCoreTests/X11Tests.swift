import Foundation
import Testing
@testable import EscaleCore

private let sock = "/tmp/escale-x/m"
private let xauth = "/opt/X11/bin/xauth"
private let xdisplay = "/private/tmp/com.apple.launchd.AbC/org.xquartz:0"

@Suite("X11 : détection et arguments ssh")
struct X11ArgumentsTests {
    private func args(x11: Bool, settings: X11Settings?) throws -> OpenSSHCommandBuilder {
        try OpenSSHCommandBuilder(profile: HostProfile(name: "a", host: "h", x11Forwarding: x11), controlPath: sock,
                                  options: OpenSSHOptions(x11: settings))
    }

    @Test func maitreAvecX11PrudentParDefaut() throws {
        let b = try args(x11: true, settings: X11Settings(xauthPath: xauth, display: xdisplay))
        let m = b.masterArguments()
        let pairs = zip(m, m.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
        #expect(pairs.contains("ForwardX11=yes"))
        #expect(pairs.contains("ForwardX11Trusted=no"))
        #expect(pairs.contains("XAuthLocation=\(xauth)"))
        #expect(b.environment["DISPLAY"] == xdisplay)
        #expect(b.forwardsX11)
    }

    @Test func modeConfianceOptionnel() throws {
        let b = try args(x11: true, settings: X11Settings(trusted: true, xauthPath: xauth))
        #expect(b.masterArguments().contains("ForwardX11Trusted=yes"))
        #expect(b.environment["DISPLAY"] == nil, "DISPLAY hérité quand non fourni")
    }

    @Test func jamaisDeX11SiHoteDesactiveOuXQuartzAbsent() throws {
        for b in [try args(x11: false, settings: X11Settings(xauthPath: xauth)), try args(x11: true, settings: nil)] {
            #expect(!b.masterArguments().contains { $0.contains("X11") || $0.contains("XAuth") } && !b.forwardsX11)
            #expect(!b.execArguments(remoteCommand: "xeyes").contains { $0.contains("X11") })
            #expect(b.environment["DISPLAY"] == nil)
        }
    }

    @Test func clientSecondaireExecRespecteInvariant2() throws {
        let b = try args(x11: true, settings: X11Settings(xauthPath: xauth, display: xdisplay))
        let e = b.execArguments(remoteCommand: "xeyes -geometry 200x200")
        #expect(e.starts(with: ["-S", sock, "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false"]))
        #expect(e.contains("-n") && e.contains("ForwardX11=yes"))
        #expect(Array(e.suffix(3)) == ["--", "h", "xeyes -geometry 200x200"])
        // Le terminal d'un panneau demande aussi X11 : DISPLAY distant disponible dans le shell.
        #expect(b.shellArguments(remoteCommand: nil).contains("ForwardX11=yes"))
    }

    @Test func optionsInvalidesRefusees() throws {
        let b = try? args(x11: true, settings: X11Settings(xauthPath: "-oProxyCommand=x"))
        #expect(b == nil)
    }

    // MARK: Détection (système de fichiers injecté)

    @Test func xquartzAbsent() {
        let d = X11Detection.detect(fileExists: { _ in false }, environment: [:], launchctlDisplay: { nil }, listDirectory: { _ in [] })
        #expect(d.status == .notInstalled && !d.isReady)
        #expect(d.settings(trusted: false) == nil)
        #expect(d.explanation.contains("xquartz.org"))
    }

    @Test func xquartzPresentDisplayDeLEnvironnement() {
        let present: Set = ["/Applications/Utilities/XQuartz.app", xauth]
        let d = X11Detection.detect(fileExists: { present.contains($0) }, environment: ["DISPLAY": xdisplay], launchctlDisplay: { nil }, listDirectory: { _ in [] })
        #expect(d.status == .ready)
        #expect(d.settings(trusted: true) == X11Settings(trusted: true, xauthPath: xauth, display: xdisplay))
    }

    @Test func displayRetrouveViaLaunchctlPuisSocketLaunchd() {
        let sockPath = "/private/tmp/com.apple.launchd.ZZ/org.xquartz:0"
        let present: Set = ["/opt/X11", xauth, sockPath]
        let viaLaunchctl = X11Detection.detect(fileExists: { present.contains($0) }, environment: [:], launchctlDisplay: { "/x/y:0" }, listDirectory: { _ in [] })
        #expect(viaLaunchctl.display == "/x/y:0")
        let viaSocket = X11Detection.detect(fileExists: { present.contains($0) }, environment: [:], launchctlDisplay: { nil },
                                            listDirectory: { _ in ["autre", "com.apple.launchd.ZZ"] })
        #expect(viaSocket.display == sockPath && viaSocket.isReady)
    }

    @Test func xauthHomebrewDetecteMaisXQuartzReste_prefere() {
        let brew = "/opt/homebrew/bin/xauth"
        // XQuartz présent + seulement le xauth Homebrew (/opt/X11/bin/xauth absent) : celui de Homebrew est retenu.
        let seul = X11Detection.detect(fileExists: { $0 == "/opt/X11" || $0 == brew }, environment: ["DISPLAY": "/x/org.xquartz:0"], launchctlDisplay: { nil }, listDirectory: { _ in [] })
        #expect(seul.xauthPath == brew && seul.isReady)
        // Les deux : celui de XQuartz d'abord.
        let deux = X11Detection.detect(fileExists: { $0 == "/opt/X11" || $0 == brew || $0 == xauth }, environment: ["DISPLAY": "/x/org.xquartz:0"], launchctlDisplay: { nil }, listDirectory: { _ in [] })
        #expect(deux.xauthPath == xauth)
    }

    @Test func etatsIntermediaires() {
        let sansXauth = X11Detection.detect(fileExists: { $0 == "/opt/X11" }, environment: ["DISPLAY": ":0"], launchctlDisplay: { nil }, listDirectory: { _ in [] })
        #expect(sansXauth.status == .missingXauth)
        let sansDisplay = X11Detection.detect(fileExists: { $0 == "/opt/X11" || $0 == xauth }, environment: [:], launchctlDisplay: { nil }, listDirectory: { _ in [] })
        #expect(sansDisplay.status == .noDisplay)
    }

    @Test func commandeDeLancement() {
        #expect(X11LaunchCommand.validate("  xeyes ") == .success("xeyes"))
        #expect(X11LaunchCommand.validate("   ") != .success(""))
        if case .success = X11LaunchCommand.validate("xeyes\nrm -rf /") { Issue.record("saut de ligne accepté") }
        if case .success = X11LaunchCommand.validate(String(repeating: "a", count: 501)) { Issue.record("trop long accepté") }
    }
}

// MARK: - Intégration : sshd local + faux serveur X (aucun XQuartz requis)

/// Faux xauth : accepte tout et affiche un cookie pour `list`, de sorte que ssh puisse négocier la redirection.
private func writeFakeXauth(in dir: String) throws -> String {
    let path = "\(dir)/fake-xauth"
    // Côté serveur, sshd lui envoie « add … cookie » sur l'entrée standard : on le garde pour que la sonde l'utilise.
    let script = "#!/bin/sh\nif [ \"$1\" = \"-f\" ]; then shift 2; fi\ncase \"$*\" in *list*) echo 'mac/unix:0  MIT-MAGIC-COOKIE-1  00112233445566778899aabbccddeeff';; *\" -\") cat > \"\(dir)/xauth.stdin\";; esac\nexit 0\n"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
}

/// Serveur « X » Unix : accepte une connexion et mémorise les premiers octets reçus.
private final class FakeXServer: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var received = Data()

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 4) == 0 else { throw LocalSSHD.StartError(description: "faux X : errno \(errno)") }
        let lfd = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 256)
                let n = read(c, &buf, 256)
                if n > 0 { lock.withLock { received.append(contentsOf: buf[0..<n]) } }
                close(c)
            }
        }
    }

    var data: Data { lock.withLock { received } }
    func stop() { shutdown(fd, SHUT_RDWR); close(fd); unlink(path) }
}

@Suite("X11 : redirection réelle via sshd local", .enabled(if: LocalSSHD.isAvailable, "sshd local non privilégié indisponible"), .serialized)
struct X11IntegrationTests {
    /// Handshake X11 minimal (little-endian) : seul l'arrivée sur le faux serveur compte.
    /// Sonde distante : ouvre la connexion sur le DISPLAY créé par sshd, avec le cookie donné par sshd à xauth
    /// (sans cookie valide, ssh ferme la connexion X avant le serveur local).
    private static func remoteProbe(stdinFile: String) -> String {
        let py = "import os,socket,time;c=[l.split()[-1] for l in open('\(stdinFile)') if l.startswith('add')][-1];p=6000+int(os.environ['DISPLAY'].split(':')[1].split('.')[0]);s=socket.create_connection(('localhost',p));s.sendall(b'l\\0\\x0b\\0\\0\\0\\x12\\0\\x10\\0\\0\\0MIT-MAGIC-COOKIE-1\\0\\0'+bytes.fromhex(c)+b'XPROBE');time.sleep(0.3)"
        return "echo \"DISPLAY=$DISPLAY\"; python3 -c \"\(py)\"; echo fin"
    }

    private static func run(_ cmd: ShellCommand) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.executable)
        p.arguments = cmd.arguments
        p.environment = ProcessInfo.processInfo.environment.merging(cmd.environment) { _, n in n }
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "échec de lancement" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func lExecSurLeMaitreAtteintLeFauxServeurX() async throws {
        // Le dossier du sshd de test sert d'espace de travail ; l'e/s sur socket Unix reste sous 104 octets.
        let work = "/tmp/escale-x11-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let fake = try writeFakeXauth(in: work)
        let xserver = try FakeXServer(path: "\(work)/X0")
        defer { xserver.stop() }

        var o = LocalSSHD.Options()
        o.extraConfig = "X11Forwarding yes\nX11UseLocalhost yes\nXAuthLocation \(fake)"
        try await LocalSSHD.with(o) { d in
            var profile = d.profile(); profile.x11Forwarding = true
            let t = OpenSSHTransport(
                profile: profile,
                configuration: .init(ssh: {
                    var s = d.sshOptions(); s.x11 = X11Settings(trusted: true, xauthPath: fake, display: xserver.path); return s
                }(), masterReadyTimeout: 15, maxSessions: 10, forwardProbeTimeout: 0.5))
            try await t.connect()
            let cmd = try await t.execCommand(remoteCommand: Self.remoteProbe(stdinFile: "\(work)/xauth.stdin"))
            #expect(cmd.arguments.contains("ForwardX11=yes") && cmd.arguments.contains("ControlMaster=no"))
            #expect(cmd.environment["DISPLAY"] == xserver.path)

            let text = Self.run(cmd)
            cmd.lease?.release()
            #expect(text.contains("DISPLAY=localhost:10"), "sortie \(text) ; sshd doit créer DISPLAY=localhost:10.0 : \(text)")
            #expect(text.contains("fin"), "sortie : \(text)")
            // La connexion X ouverte sur le DISPLAY distant est ressortie chez nous, sur le faux serveur.
            let got = await eventuallyData { xserver.data.contains(Data("XPROBE".utf8)) }; #expect(got, "reçu : \(xserver.data) ; sortie : \(text)")
            await t.disconnect()
        }
    }

    @Test func sansX11DemandeLeDisplayDistantEstVide() async throws {
        let work = "/tmp/escale-x11-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let fake = try writeFakeXauth(in: work)
        var o = LocalSSHD.Options()
        o.extraConfig = "X11Forwarding yes\nXAuthLocation \(fake)"
        try await LocalSSHD.with(o) { d in
            let t = OpenSSHTransport(profile: d.profile(), configuration: .init(ssh: d.sshOptions(), masterReadyTimeout: 15, maxSessions: 10, forwardProbeTimeout: 0.5))
            try await t.connect()
            let cmd = try await t.execCommand(remoteCommand: "echo \"[$DISPLAY]\"")
            #expect(!cmd.arguments.contains("ForwardX11=yes"))
            let r = Self.run(cmd)
            cmd.lease?.release()
            #expect(r.contains("[]"), "\(r)")
            await t.disconnect()
        }
    }
}

private func eventuallyData(_ seconds: Double = 5, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return cond()
}

@Suite("X11 : diagnostic d'une application terminée")
struct X11LaunchDiagnosticTests {
    @Test func refusEtProgrammeAbsent() {
        let d = X11LaunchDiagnostic.diagnose(code: 127, output: "X11 forwarding request failed\n/bin/bash: line 1: xeyes: command not found\n")
        #expect(d.causes == [.forwardingRefused, .commandNotFound("xeyes")])
        #expect(d.title == "Redirection X11 refusée par le serveur")
        #expect(d.message.contains("X11Forwarding yes") && d.message.contains("xauth"))
        #expect(d.message.contains("« xeyes » n'est pas installé") && d.message.contains("x11-apps"))
        #expect(d.message.contains("Sortie (code 127)"), "la sortie brute reste visible")
    }

    @Test func shellsUsuels() {
        #expect(X11LaunchDiagnostic.missingCommand(in: "zsh:1: command not found: xclock") == "xclock")
        #expect(X11LaunchDiagnostic.missingCommand(in: "sh: 1: xeyes: not found") == "xeyes")
        #expect(X11LaunchDiagnostic.missingCommand(in: "bash: foo: command not found") == "foo")
        #expect(X11LaunchDiagnostic.missingCommand(in: "tout va bien") == nil)
    }

    @Test func affichageEtCasInconnu() {
        #expect(X11LaunchDiagnostic.diagnose(code: 1, output: "Error: Can't open display: ").causes == [.cannotOpenDisplay])
        let refus = X11LaunchDiagnostic.diagnose(code: 1, output: "X11 forwarding request failed on channel 0\nError: Can't open display:")
        #expect(refus.causes == [.forwardingRefused], "l'affichage absent découle du refus : une seule cause")
        let autre = X11LaunchDiagnostic.diagnose(code: 3, output: "boom")
        #expect(autre.causes.isEmpty && autre.title == "Application X11 terminée (code 3)" && autre.message == "boom")
        #expect(X11LaunchDiagnostic.diagnose(code: 127, output: "").causes == [.commandNotFound(nil)])
    }
}

@Suite("X11 : refus de redirection dans le terminal")
struct X11ForwardingRefusalScannerTests {
    private func run(_ chunks: [String], limit: Int = 16 * 1024) -> [Bool] {
        var s = X11ForwardingRefusalScanner(limit: limit)
        return chunks.map { s.consume(Data($0.utf8)) }
    }

    @Test func ligneEntiereEtVarianteCanal() {
        #expect(run(["X11 forwarding request failed\r\n$ "]) == [true])
        #expect(run(["Last login: hier\r\nX11 forwarding request failed on channel 0\r\nuser@h:~$ "]) == [true])
    }

    @Test func ligneDecoupeeEnMorceauxArbitraires() {
        let line = "bienvenue\r\nX11 forwarding request failed on channel 3\r\n$ "
        // Toutes les coupures en deux, puis octet par octet : détecté exactement une fois.
        for cut in 1..<line.utf8.count {
            let b = Array(line.utf8)
            var s = X11ForwardingRefusalScanner()
            let hits = [s.consume(Data(b[..<cut])), s.consume(Data(b[cut...]))]
            #expect(hits.filter { $0 }.count == 1, "coupure \(cut)")
        }
        var s = X11ForwardingRefusalScanner()
        let hits = line.utf8.map { s.consume(Data([$0])) }
        #expect(hits.filter { $0 }.count == 1 && s.detected)
    }

    @Test func uneSeuleFoisEtRienSansRefus() {
        #expect(run(["X11 forwarding request failed\r\n", "X11 forwarding request failed\r\n"]) == [true, false])
        #expect(run(["Last login\r\n", "$ ls\r\nX11 forwarding\r\n", "request ok\r\n"]) == [false, false, false])
        #expect(run([""]) == [false])
    }

    @Test func limiteDuDebutDeSortie() {
        // Au-delà de la limite (fichier affiché plus tard par l'utilisateur) : aucun avertissement.
        #expect(run([String(repeating: "a", count: 32), "X11 forwarding request failed\r\n"], limit: 32) == [false, false])
        // Ligne à cheval sur la limite : seule la partie lue compte.
        #expect(run([String(repeating: "a", count: 20), "X11 forwarding request failed"], limit: 40) == [false, false])
    }

    @Test func refusPendantQueLeProgrammeTourne() {
        let d = X11LaunchDiagnostic.refusalWhileRunning(output: "X11 forwarding request failed on channel 1\n")
        #expect(d?.causes == [.forwardingRefused])
        #expect(d?.title == "Redirection X11 refusée par le serveur")
        #expect(d?.message.contains("X11Forwarding yes") == true && d?.message.contains("on channel 1") == true)
        #expect(X11LaunchDiagnostic.refusalWhileRunning(output: "tout va bien") == nil)
        #expect(X11LaunchDiagnostic.refusalWhileRunning(output: "") == nil)
    }
}
