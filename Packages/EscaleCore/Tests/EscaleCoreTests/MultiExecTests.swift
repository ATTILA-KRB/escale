import Foundation
import Testing
@testable import EscaleCore

// MARK: - Filtre de diffusion (pur)

@Suite("MultiExec : filtre de diffusion")
struct BroadcastFilterTests {
    private func d(_ s: String) -> Data { Data(s.utf8) }

    @Test("la saisie normale et les touches spéciales sont diffusées")
    func keysPass() {
        for s in ["a", "ls -l\r", "\u{3}", "\u{1b}", "\u{1b}[A", "\u{1b}[1;5C", "\u{1b}[3~", "\u{1b}OP", "\u{1b}[1;2R", "é", "\u{1b}[200~coller\u{1b}[201~"] {
            #expect(!BroadcastFilter.isTerminalReport(d(s)), "\(s.debugDescription)")
        }
    }

    @Test("les réponses automatiques du terminal ne le sont pas")
    func reportsBlocked() {
        for s in ["\u{1b}[24;80R", "\u{1b}[?1;2c", "\u{1b}[>0;276;0c", "\u{1b}[I", "\u{1b}[O", "\u{1b}[<0;10;5M", "\u{1b}[<0;10;5m",
                  "\u{1b}[?2026;2$y", "\u{1b}]11;rgb:0000/0000/0000\u{7}", "\u{1b}P1$r0m\u{1b}\\"] {
            #expect(BroadcastFilter.isTerminalReport(d(s)), "\(s.debugDescription)")
        }
    }
}

// MARK: - Exécution contre un sshd local

private func makeTransport(_ d: LocalSSHD, name: String, maxSessions: Int = 10) -> OpenSSHTransport {
    var p = d.profile(); p.name = name
    return OpenSSHTransport(profile: p, configuration: .init(ssh: d.sshOptions(), masterReadyTimeout: 15, maxSessions: maxSessions))
}

@Suite("MultiExec : exécution groupée", .enabled(if: LocalSSHD.isAvailable, "sshd local indisponible"))
struct GroupExecIntegrationTests {
    @Test("exec : sortie, stderr séparé, code de sortie, sans pty")
    func execBasics() async throws {
        try await LocalSSHD.with { d in
            let t = makeTransport(d, name: "a")
            try await t.connect()
            defer { Task { await t.disconnect() } }
            let ok = try await t.exec("echo out; echo err >&2; exit 7")
            #expect(ok.exitCode == 7 && ok.stdout == "out\n" && ok.stderr == "err\n" && ok.failure == nil && !ok.timedOut)
            #expect(!ok.isSuccess)
            let tty = try await t.exec("test -t 0 && echo tty || echo notty")
            #expect(tty.stdout == "notty\n" && tty.isSuccess)
            // Une seule authentification : l'exec réutilise le maître.
            #expect(d.acceptedAuthenticationCount() == 1)
            #expect(await t.execSessionCount == 0)
        }
    }

    @Test("exec : sortie tronquée mais le fils n'est pas bloqué")
    func execTruncation() async throws {
        try await LocalSSHD.with { d in
            let t = makeTransport(d, name: "a")
            try await t.connect()
            defer { Task { await t.disconnect() } }
            let r = try await t.exec("head -c 300000 /dev/zero | tr '\\0' x; echo fin >&2", timeout: 20, maxOutputBytes: 1000)
            #expect(r.stdout.utf8.count == 1000 && r.stdoutTruncated && !r.stderrTruncated && r.stderr == "fin\n" && r.exitCode == 0)
        }
    }

    @Test("exec : plafond de sessions (invariant 5) et non connecté")
    func execCaps() async throws {
        try await LocalSSHD.with { d in
            let t = makeTransport(d, name: "a", maxSessions: 2)
            await #expect(throws: SSHTransportError.notConnected) { try await t.exec("true") }
            try await t.connect()
            defer { Task { await t.disconnect() } }
            // Deux commandes longues occupent les deux places ; la troisième est refusée localement.
            async let a = t.exec("sleep 1.5", timeout: 10)
            async let b = t.exec("sleep 1.5", timeout: 10)
            try await Task.sleep(for: .milliseconds(400))
            #expect(await t.execSessionCount == 2)
            await #expect(throws: SSHTransportError.self) { try await t.exec("true") }
            let (ra, rb) = try await (a, b)
            #expect(ra.exitCode == 0 && rb.exitCode == 0)
            #expect(await t.execSessionCount == 0)
        }
    }

    @Test("exec : délai maximal interrompt la commande")
    func execTimeout() async throws {
        try await LocalSSHD.with { d in
            let t = makeTransport(d, name: "a")
            try await t.connect()
            defer { Task { await t.disconnect() } }
            let r = try await t.exec("sleep 30", timeout: 1)
            #expect(r.timedOut && r.exitCode == nil && !r.isSuccess && r.duration < 6, "durée \(r.duration)")
            // Le maître reste utilisable.
            let again = try await t.exec("echo apres")
            #expect(again.stdout == "apres\n")
        }
    }

    @Test("groupe : 3 hôtes (3 maîtres), codes de sortie distincts, en parallèle, délai")
    func groupOfThree() async throws {
        try await LocalSSHD.with { d in
            let ts = ["alpha", "beta", "gamma"].map { makeTransport(d, name: $0) }
            for t in ts { try await t.connect() }
            defer { Task { for t in ts { await t.disconnect() } } }
            let ids = ts.map { _ in UUID() }
            // Commande propre à chaque hôte : codes 0, 3 et 7.
            let cmds = ["echo salut; exit 0", "echo bof >&2; exit 3", "echo $SSH_CONNECTION; exit 7"]
            let targets = ts.indices.map { GroupExecTarget.transport(ts[$0], id: ids[$0], name: ["alpha", "beta", "gamma"][$0], command: cmds[$0]) }
            let events = EventLog()
            let t0 = Date()
            let res = await GroupExec.run(command: "true", targets: targets, limits: GroupExecLimits(timeout: 10)) { id, e in events.add(id, e) }
            #expect(res.count == 3)
            #expect(res[ids[0]]?.exitCode == 0 && res[ids[0]]?.stdout == "salut\n")
            #expect(res[ids[1]]?.exitCode == 3 && res[ids[1]]?.stderr == "bof\n")
            #expect(res[ids[2]]?.exitCode == 7 && res[ids[2]]?.isSuccess == false)
            #expect(events.count(.started) == 3 && events.count(.finished) == 3)
            #expect(d.acceptedAuthenticationCount() == 3)   // un maître par hôte, aucune authentification de plus
            #expect(Date().timeIntervalSince(t0) < 8)

            // Même commande partout, un hôte trop lent : seul celui-là échoue par délai, les autres répondent.
            let slowTargets = ts.indices.map { i in
                GroupExecTarget.transport(ts[i], id: ids[i], name: "h\(i)", command: i == 1 ? "sleep 30" : "echo ok")
            }
            let start = Date()
            let r2 = await GroupExec.run(command: "echo ok", targets: slowTargets, limits: GroupExecLimits(timeout: 1.5))
            #expect(r2[ids[0]]?.isSuccess == true && r2[ids[2]]?.isSuccess == true)
            #expect(r2[ids[1]]?.timedOut == true && r2[ids[1]]?.exitCode == nil)
            #expect(Date().timeIntervalSince(start) < 8)
        }
    }

    @Test("groupe : parallélisme réel (3 × sleep 1 en moins de 3 s) et plafond maxConcurrent")
    func groupParallel() async throws {
        try await LocalSSHD.with { d in
            let ts = (0..<3).map { makeTransport(d, name: "p\($0)") }
            for t in ts { try await t.connect() }
            defer { Task { for t in ts { await t.disconnect() } } }
            let targets = ts.indices.map { GroupExecTarget.transport(ts[$0], name: "p\($0)") }
            let t0 = Date()
            let r = await GroupExec.run(command: "sleep 1", targets: targets, limits: GroupExecLimits(timeout: 10))
            let par = Date().timeIntervalSince(t0)
            #expect(r.values.allSatisfy(\.isSuccess) && par < 2.8, "durée \(par)")
            let t1 = Date()
            _ = await GroupExec.run(command: "sleep 1", targets: targets, limits: GroupExecLimits(timeout: 10, maxConcurrent: 1))
            #expect(Date().timeIntervalSince(t1) >= 2.9)
        }
    }

    @Test("rapport copiable")
    func report() {
        let t = GroupExecReport.text(command: "uname", entries: [
            ("a", RemoteExecResult(exitCode: 0, stdout: "Linux\n", duration: 0.2)),
            ("b", RemoteExecResult(failure: "connexion refusée")),
        ])
        #expect(t.contains("=== a — code 0") && t.contains("Linux") && t.contains("=== b — connexion refusée"))
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(UUID, GroupExecEvent)] = []
    func add(_ id: UUID, _ e: GroupExecEvent) { lock.lock(); items.append((id, e)); lock.unlock() }
    enum Kind { case started, finished }
    func count(_ k: Kind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.filter { if case .started = $0.1 { return k == .started } else { return k == .finished } }.count
    }
}
