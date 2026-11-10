import Foundation
import Observation
import EscaleCore

/// État de l'unique fenêtre de terminal : moteur + session (shell local ou commande).
@MainActor
@Observable
final class AppModel {
    let options: LaunchOptions
    let engine: SwiftTermEngine
    private(set) var session: TerminalSession?
    private(set) var launchError: String?
    @ObservationIgnored private var selfTestStarted = false

    init(options: LaunchOptions) {
        self.options = options
        engine = SwiftTermEngine()
        let (exe, args): (String, [String])
        if options.selftestDirectory != nil {
            (exe, args) = ("/bin/zsh", ["-f", "-i"]) // shell reproductible, sans rc utilisateur
        } else if let cmd = options.command {
            (exe, args) = (Self.resolve(cmd[0]), Array(cmd.dropFirst()))
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            (exe, args) = (shell, ["-l"])
        }
        do {
            session = try TerminalSession.launch(
                engine: engine, executable: exe, arguments: args,
                environment: Self.environment(), currentDirectory: NSHomeDirectory())
        } catch {
            launchError = "Lancement de \(exe) impossible : \(error)"
        }
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

    func startSelfTestIfRequested() {
        guard let dir = options.selftestDirectory, !selfTestStarted, let session else { return }
        selfTestStarted = true
        let runner = SelfTest(directory: dir, engine: engine, session: session)
        Task { @MainActor in
            let ok = await runner.run()
            exit(ok ? 0 : 1)
        }
    }

    func windowClosing() { session?.kill() }
}
