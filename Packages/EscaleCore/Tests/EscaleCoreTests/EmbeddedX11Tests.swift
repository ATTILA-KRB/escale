import Foundation
import Testing
import CoreGraphics
@testable import EscaleCore

/// Serveur X11 intégré. Les tests réels ne tournent que si `ESCALE_X11_TEST_APP` désigne un paquet installé et signé
/// (`scripts/x11-bundle.sh --install DIR` puis `ESCALE_X11_TEST_APP=DIR/EscaleX11.app`) : `scripts/test.sh` le fournit.
@Suite("X11 intégré", .serialized)
struct EmbeddedX11Tests {
    @Test func bundleAbsentDonneNil() {
        #expect(EmbeddedX11Bundle.inside(appBundle: URL(fileURLWithPath: "/nulle/part.app")) == nil)
    }

    @Test func detectionIntegreeToujoursPrete() {
        let b = EmbeddedX11Bundle(appPath: "/A/EscaleX11.app", serviceName: "x.y")
        let s = EmbeddedX11Server(bundle: b, runtimeDirectory: "/tmp/escale-x11.1")
        let d = X11Detection.embedded(s)
        #expect(d.isReady && d.embedded)
        #expect(d.display == "/tmp/escale-x11.1/x11:0")
        #expect(d.explanation.contains("intégré"))
        #expect(d.settings(trusted: false) == X11Settings(trusted: false, xauthPath: "/A/EscaleX11.app/Contents/MacOS/xauth",
                                                          display: "/tmp/escale-x11.1/x11:0", xauthority: "/tmp/escale-x11.1/Xauthority"))
    }

    @Test func environnementSshAvecXauthority() throws {
        let x = X11Settings(xauthPath: "/A/xauth", display: "/d/x11:0", xauthority: "/d/Xauthority")
        let b = try OpenSSHCommandBuilder(profile: HostProfile(name: "a", host: "h", x11Forwarding: true), controlPath: "/tmp/e/m",
                                          options: OpenSSHOptions(x11: x))
        #expect(b.environment["DISPLAY"] == "/d/x11:0" && b.environment["XAUTHORITY"] == "/d/Xauthority")
        let sans = try OpenSSHCommandBuilder(profile: HostProfile(name: "a", host: "h"), controlPath: "/tmp/e/m", options: OpenSSHOptions(x11: x))
        #expect(sans.environment["XAUTHORITY"] == nil)
        #expect(throws: OpenSSHCommandBuilderError.self) {
            try OpenSSHCommandBuilder(profile: HostProfile(name: "a", host: "h", x11Forwarding: true), controlPath: "/tmp/e/m",
                                      options: OpenSSHOptions(x11: X11Settings(xauthPath: "/A/xauth", xauthority: "a\nb")))
        }
    }

    @Test func numeroEcranLibre() {
        #expect(EmbeddedX11Server.freeDisplayNumber { _ in false } == 64)
        #expect(EmbeddedX11Server.freeDisplayNumber { $0 == "/tmp/.X64-lock" || $0 == "/tmp/.X65-lock" } == 66)
    }

    // MARK: Réel

    private static var testApp: String? { ProcessInfo.processInfo.environment["ESCALE_X11_TEST_APP"] }

    private static func run(_ tool: String, _ args: [String], env: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test(.enabled(if: testApp != nil)) func serveurReelDemarreSansTCPEtSArrete() throws {
        let app = try #require(Self.testApp)
        let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        let bundle = EmbeddedX11Bundle(appPath: app, serviceName: try #require(plist?["CFBundleIdentifier"] as? String))
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ex11t.\(getpid())")
        let server = EmbeddedX11Server(bundle: bundle, runtimeDirectory: dir)
        defer { server.stop() }

        try server.ensureRunning()
        let pid = try #require(server.serverPID)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        try server.ensureRunning() // idempotent : même processus
        #expect(server.serverPID == pid)

        let xdpyinfo = bundle.macOSDir + "/xdpyinfo"
        let env = ["DISPLAY": server.display, "XAUTHORITY": server.xauthority, "PATH": "/usr/bin:/bin"]
        let (rc, out) = Self.run(xdpyinfo, [], env: env)
        #expect(rc == 0 && out.contains("X.Org Foundation") && out.contains("XKEYBOARD"), "\(out.prefix(400))")
        // Aucune écoute TCP ni socket dans /tmp/.X11-unix.
        let (_, lsof) = Self.run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"], env: [:])
        #expect(!lsof.contains("LISTEN"), "\(lsof)")

        let locks = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        let ours = locks.filter { $0.hasSuffix("-lock") }.first { (try? String(contentsOfFile: "/tmp/\($0)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "\(pid)" }
        #expect(ours != nil)
        server.stop()
        #expect(server.serverPID == nil)
        if let ours { #expect(!FileManager.default.fileExists(atPath: "/tmp/\(ours)")) }
        #expect(Darwin.kill(pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    /// xeyes (150×100 sans décoration) sur un serveur neuf : (fenêtre du serveur nommée « xeyes », ses bornes), pids.
    private static func xeyesWindow(app: String, windowManager: Bool) throws -> (title: String, height: Double, wmPID: Int32?, serverPID: Int32, dirGone: Bool, wmGone: Bool, serverGone: Bool) {
        let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        let bundle = EmbeddedX11Bundle(appPath: app, serviceName: try #require(plist?["CFBundleIdentifier"] as? String))
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ex11w.\(getpid())")
        let server = EmbeddedX11Server(bundle: bundle, runtimeDirectory: dir, windowManager: windowManager)
        defer { server.stop() }
        try server.ensureRunning()
        let spid = try #require(server.serverPID)
        let wm = server.windowManagerPID
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bundle.macOSDir + "/xeyes")
        p.environment = ["DISPLAY": server.display, "XAUTHORITY": server.xauthority, "PATH": "/usr/bin:/bin"]
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        // quartz-wm pose le titre et la barre de titre après l'apparition de la fenêtre : avec gestionnaire,
        // attendre la décoration (sinon course, ~40 % d'échecs), en gardant le dernier état vu pour le diagnostic.
        var found: (String, Double)?
        var decorated = false
        let deadline = Date().addingTimeInterval(20)
        while !decorated && Date() < deadline {
            usleep(200_000)
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == spid {
                guard let b = w[kCGWindowBounds as String] as? [String: Double], abs((b["Width"] ?? 0) - 150) <= 4, (b["Height"] ?? 0) >= 90,
                      (b["Height"] ?? 0) < 200 else { continue }
                let title = w[kCGWindowName as String] as? String ?? ""
                found = (title, b["Height"] ?? 0)
                decorated = !windowManager || (!title.isEmpty && (b["Height"] ?? 0) >= 115)
            }
        }
        p.terminate()
        server.stop()
        let f = try #require(found, "fenêtre xeyes introuvable")
        return (f.0, f.1, wm, spid, !FileManager.default.fileExists(atPath: dir),
                wm.map { Darwin.kill($0, 0) != 0 } ?? true, Darwin.kill(spid, 0) != 0)
    }

    @Test(.enabled(if: testApp != nil)) func gestionnaireDeFenetresDecoreXeyesEtSArrete() throws {
        let r = try Self.xeyesWindow(app: try #require(Self.testApp), windowManager: true)
        let wm = try #require(r.wmPID, "quartz-wm non lancé")
        #expect(wm != r.serverPID)
        #expect(r.title == "xeyes", "titre « \(r.title) »")
        #expect(r.height >= 115, "hauteur \(r.height) : barre de titre absente ?") // 100 + barre de titre (22 mesurés)
        #expect(r.wmGone && r.serverGone && r.dirGone)
    }

    @Test(.enabled(if: testApp != nil)) func sansGestionnaireDeFenetresPasDeDecoration() throws {
        let r = try Self.xeyesWindow(app: try #require(Self.testApp), windowManager: false)
        #expect(r.wmPID == nil)
        #expect(r.title.isEmpty && r.height < 110, "titre « \(r.title) » hauteur \(r.height)")
        #expect(r.serverGone && r.dirGone)
    }
}
