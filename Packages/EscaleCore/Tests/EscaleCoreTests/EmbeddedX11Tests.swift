import Foundation
import Testing
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
}
