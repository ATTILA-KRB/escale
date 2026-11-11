import Foundation
import Network
import Testing
@testable import EscaleCore

/// Exécute son bloc une seule fois (états `ready`/`failed` répétés par NWListener).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { f() } }
}

/// Serveur Telnet minimal pour les tests : NWListener sur un port libre (0), une seule connexion.
private final class TestTelnetServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "test.telnet.server")
    private let lock = NSLock()
    private var conn: NWConnection?
    private var _received = Data()
    private var _port: UInt16 = 0
    /// Octets à envoyer dès l'acceptation.
    var greeting = Data()

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.lock.withLock { self.conn = c }
            c.start(queue: self.queue)
            c.send(content: self.greeting, completion: .contentProcessed { _ in })
            self.read(c)
        }
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { [listener] st in
                switch st {
                case .ready: once.run { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, complete, err in
            guard let self else { return }
            if let d { self.lock.withLock { self._received += d } }
            if complete || err != nil { return }
            self.read(c)
        }
    }

    var received: Data { lock.withLock { _received } }
    func send(_ d: Data) { lock.withLock { conn }?.send(content: d, completion: .contentProcessed { _ in }) }
    func closeClient() { lock.withLock { conn }?.cancel() }
    func stop() { listener.cancel(); lock.withLock { conn }?.cancel() }

    func waitReceived(contains needle: Data, timeout: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if received.range(of: needle) != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return received.range(of: needle) != nil
    }
}

private func collect(_ c: TelnetConnection, until needle: String, timeout: Double = 5) async -> String {
    let task = Task { () -> String in
        var text = ""
        for await d in c.output {
            text += String(decoding: d, as: UTF8.self)
            if text.contains(needle) { break }
        }
        return text
    }
    let timer = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); task.cancel() }
    let r = await task.value
    timer.cancel()
    return r
}

@Suite("Telnet : connexion TCP", .serialized)
struct TelnetConnectionTests {
    @Test func banniereNegociationSaisieEtFermeture() async throws {
        let server = try TestTelnetServer()
        // DO TTYPE, DO NAWS, WILL ECHO puis bannière avec un 0xFF doublé (octet de données).
        server.greeting = Data([255, 253, 24, 255, 253, 31, 255, 251, 1]) + Data("Bienvenue\r\n".utf8)
            + Data([255, 255]) + Data("\r\nlogin: ".utf8)
        let port = try await server.start()
        defer { server.stop() }

        let c = try await TelnetConnection.open(host: "127.0.0.1", port: Int(port), columns: 100, rows: 30)
        let text = await collect(c, until: "login: ")
        #expect(text.contains("Bienvenue"))
        #expect(text.contains("login: "))
        #expect(!text.contains("\u{1b}[31m"))

        // Offres du client + NAWS à la taille initiale + DO ECHO.
        #expect(await server.waitReceived(contains: Data([255, 250, 31, 0, 100, 0, 30, 255, 240])))
        server.send(Data([255, 250, 24, 1, 255, 240]))
        #expect(await server.waitReceived(contains: Data([255, 250, 24, 0]) + Data("XTERM-256COLOR".utf8) + Data([255, 240])))
        #expect(await server.waitReceived(contains: Data([255, 253, 1])))

        // Redimensionnement puis saisie avec 0xFF et Entrée.
        c.resize(columns: 132, rows: 43)
        #expect(await server.waitReceived(contains: Data([255, 250, 31, 0, 132, 0, 43, 255, 240])))
        c.write(Data([0x61, 0xff, 0x0d]))
        #expect(await server.waitReceived(contains: Data([0x61, 0xff, 0xff, 0x0d, 0x00])))

        // Fermeture côté serveur → fin normale.
        server.closeClient()
        let status = await c.waitForExit()
        #expect(status == .exited(0))
    }

    @Test func killEstIdempotentEtTermineLeFlux() async throws {
        let server = try TestTelnetServer()
        let port = try await server.start()
        defer { server.stop() }
        let c = try await TelnetConnection.open(host: "127.0.0.1", port: Int(port))
        c.kill(); c.kill()
        #expect(await c.waitForExit() == .exited(0))
        var n = 0
        for await _ in c.output { n += 1 }
        #expect(n >= 0) // le flux se termine (sinon le test ne rend jamais la main)
        c.write(Data("x".utf8)) // sans effet, sans plantage
    }

    @Test func connexionRefusee() async throws {
        // Port libre obtenu puis rendu : plus personne n'écoute.
        let l = try NWListener(using: .tcp, on: .any)
        let port: UInt16 = await withCheckedContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { st in
                if case .ready = st { once.run { cont.resume(returning: l.port?.rawValue ?? 0) } }
            }
            l.newConnectionHandler = { $0.cancel() }
            l.start(queue: .global())
        }
        l.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            _ = try await TelnetConnection.open(host: "127.0.0.1", port: Int(port), settings: TelnetSettings(connectTimeout: 5))
            Issue.record("la connexion aurait dû échouer")
        } catch let e as TelnetError {
            #expect(e == .refused(host: "127.0.0.1", port: Int(port)))
            #expect(e.description.contains("refusée"))
        }
    }

    @Test func hoteInexistant() async {
        do {
            _ = try await TelnetConnection.open(host: "hote-inexistant.invalid", port: 23, settings: TelnetSettings(connectTimeout: 5))
            Issue.record("la connexion aurait dû échouer")
        } catch let e as TelnetError {
            #expect(!e.description.isEmpty)
        } catch { Issue.record("erreur inattendue : \(error)") }
    }

    @Test func adresseInvalide() async {
        do { _ = try await TelnetConnection.open(host: "  ", port: 23); Issue.record("devrait échouer") }
        catch let e as TelnetError { #expect(e == .invalidEndpoint("hôte vide")) } catch { Issue.record("\(error)") }
        do { _ = try await TelnetConnection.open(host: "127.0.0.1", port: 0); Issue.record("devrait échouer") }
        catch let e as TelnetError { #expect(e == .invalidEndpoint("port 0")) } catch { Issue.record("\(error)") }
    }

    @Test func ipv6Loopback() async throws {
        // Le serveur de test écoute en dual-stack : on s'y connecte par l'adresse IPv6 de boucle.
        let server = try TestTelnetServer()
        server.greeting = Data("v6\r\n".utf8)
        let port = try await server.start()
        defer { server.stop() }
        let c = try await TelnetConnection.open(host: "[::1]", port: Int(port))
        let text = await collect(c, until: "v6")
        #expect(text.contains("v6"))
        c.kill()
    }
}
