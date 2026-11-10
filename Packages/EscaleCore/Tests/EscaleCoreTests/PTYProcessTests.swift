import Testing
import Foundation
import Darwin
@testable import EscaleCore

/// Accumulateur de la sortie d'un PTYProcess, consommé en tâche de fond.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private var task: Task<Void, Never>?
    init(_ p: PTYProcess) {
        task = Task { [self] in
            for await d in p.output { lock.withLock { buf.append(d) } }
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buf, as: UTF8.self) }
    func finish() async -> String { await task?.value; return text }
    /// Attend qu'une sous-chaîne apparaisse (vrai) ou expire (faux).
    func waitFor(_ s: String, timeout: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if text.contains(s) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return text.contains(s)
    }
}

private let baseEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"]

private func start(_ exe: String, _ args: [String] = [], env: [String: String] = baseEnv,
                   columns: Int = 80, rows: Int = 24) throws -> PTYProcess {
    try PTYProcess(executable: exe, arguments: args, environment: env, columns: columns, rows: rows)
}

/// Lance, attend la fin (avec garde-fou), renvoie sortie + statut.
private func run(_ exe: String, _ args: [String] = [], env: [String: String] = baseEnv) async throws -> (String, PTYExitStatus) {
    let p = try start(exe, args, env: env)
    let c = Collector(p)
    let guardTask = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); p.kill() }
    let st = await p.waitForExit()
    guardTask.cancel()
    return (await c.finish(), st)
}

/// Nombre de descripteurs de pty (maître ou esclave) ouverts dans ce processus.
/// On ne compte pas tous les fd : les autres suites tournent en parallèle et en ouvrent
/// (pipes, sockets), ce qui faussait un comptage global.
private func openPTYCount() -> Int {
    var n = 0
    for fd in 0..<getdtablesize() {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { continue }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if path.hasPrefix("/dev/ptmx") || path.hasPrefix("/dev/ttys") { n += 1 }
    }
    return n
}

// Sérialisé : le test de fuite compte les pty ouverts par cette suite.
@Suite("PTY", .serialized)
struct PTYProcessTests {
    @Test func echoRenvoieSortieEtCodeZero() async throws {
        let (out, st) = try await run("/bin/echo", ["bonjour", "escale"])
        #expect(out == "bonjour escale\r\n")
        #expect(st == .exited(0))
    }

    @Test func ttyRenvoieLePeripheriqueEsclave() async throws {
        let p = try start("/usr/bin/tty")
        let c = Collector(p)
        let st = await p.waitForExit()
        let out = await c.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(st == .exited(0))
        #expect(out.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil)
        #expect(out == p.slavePath)
    }

    @Test func terminalDeControleAcquis() async throws {
        // /dev/tty n'est ouvrable que si le processus a un terminal de contrôle.
        let (out, st) = try await run("/bin/sh", ["-c", "echo ok > /dev/tty"])
        #expect(out.contains("ok"))
        #expect(st == .exited(0))
    }

    @Test func terminalDeControleSansPasserParUnShell() async throws {
        // Exécutable lancé directement (pas de sh qui pourrait acquérir le tty lui-même) :
        // ouvre /dev/tty, ce qui échoue (ENXIO) sans terminal de contrôle.
        let (out, st) = try await run("/usr/bin/perl", ["-e", #"open(F, ">", "/dev/tty") or exit 3; print F "direct-ok\n"; close F"#])
        #expect(out.contains("direct-ok"))
        #expect(st == .exited(0))
    }

    @Test func descripteursDeLAppNeFuientPasVersLeFils() async throws {
        let leak = fcntl(Darwin.open("/dev/null", O_RDONLY), F_DUPFD, 40) // sans CLOEXEC, numéro élevé
        defer { Darwin.close(leak) }
        #expect(leak >= 40)
        let (out, st) = try await run("/bin/ls", ["/dev/fd"])
        #expect(st == .exited(0))
        let fds = out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        #expect(fds.contains(0) && !fds.contains(Int(leak)), "fd vus par le fils : \(fds), fuite attendue absente : \(leak)")
    }

    @Test func chefDeSessionEtGroupeDePremierPlan() async throws {
        // Le fils est chef de groupe/session (pgid == pid, « s ») et son groupe est celui du terminal (ps affiche « + »).
        let p = try start("/bin/sh", ["-c", "ps -o pgid=,pid=,stat= -p $$"])
        let c = Collector(p)
        _ = await p.waitForExit()
        let fields = (await c.finish()).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        #expect(fields.count >= 3)
        #expect(fields[0] == fields[1])
        #expect(fields[1] == String(p.pid))
        #expect(fields[2].contains("s"))
        #expect(fields[2].contains("+"))
    }

    @Test func tailleInitialePuisRedimensionnement() async throws {
        let script = #"trap 'stty size; exit 0' WINCH; stty size; while :; do sleep 0.1; done"#
        let p = try start("/bin/sh", ["-c", script], columns: 100, rows: 30)
        let c = Collector(p)
        #expect(await c.waitFor("30 100"))
        p.resize(columns: 132, rows: 43)
        let st = await p.waitForExit()
        let out = await c.finish()
        #expect(out.contains("43 132"))
        #expect(st == .exited(0))
    }

    @Test func ecritureVersCatRenvoyeeEnEcho() async throws {
        let p = try start("/bin/cat")
        let c = Collector(p)
        p.write(Data("salut\n".utf8))
        #expect(await c.waitFor("salut\r\nsalut\r\n")) // écho du terminal puis sortie de cat
        p.write(Data([0x04])) // Ctrl-D : EOF
        let st = await p.waitForExit()
        _ = await c.finish()
        #expect(st == .exited(0))
    }

    @Test func ctrlCInterrompt() async throws {
        let p = try start("/bin/sleep", ["100"])
        let c = Collector(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        p.write(Data([0x03]))
        let guardTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); p.kill() }
        let st = await p.waitForExit()
        guardTask.cancel()
        _ = await c.finish()
        #expect(st == .signaled(SIGINT))
    }

    @Test func codeDeSortieNonNul() async throws {
        let (_, st) = try await run("/bin/sh", ["-c", "exit 7"])
        #expect(st == .exited(7))
        #expect(st.exitCode == 7)
    }

    @Test func terminateEtPasDeZombie() async throws {
        let p = try start("/bin/sleep", ["100"])
        let c = Collector(p)
        try await Task.sleep(nanoseconds: 200_000_000)
        p.terminate()
        let st = await p.waitForExit()
        _ = await c.finish()
        #expect(st == .signaled(SIGTERM))
        // Réapé : le pid n'existe plus (un zombie répondrait à kill(pid, 0)).
        #expect(Darwin.kill(p.pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func variableDEnvironnementTransmise() async throws {
        var env = baseEnv
        env["ESCALE_TEST"] = "valeur-é-42"
        let (out, st) = try await run("/bin/sh", ["-c", "echo $ESCALE_TEST $TERM"], env: env)
        #expect(out == "valeur-é-42 xterm-256color\r\n")
        #expect(st == .exited(0))
    }

    @Test func executableInexistantLeve() {
        #expect(throws: PTYError.self) { _ = try start("/nexiste/pas") }
    }

    @Test func aucuneFuiteDeDescripteursSur200Lancements() async throws {
        // Chauffe (premières allocations de GCD, etc.)
        _ = try await run("/usr/bin/true")
        let avant = openPTYCount()
        for _ in 0..<200 {
            let (_, st) = try await run("/usr/bin/true")
            #expect(st == .exited(0))
        }
        let apres = openPTYCount()
        #expect(apres == avant, "pty ouverts avant \(avant), après \(apres)")
    }
}
