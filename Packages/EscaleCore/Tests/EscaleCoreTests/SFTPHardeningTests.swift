import CryptoKit
import Foundation
import Testing
@testable import EscaleCore

// Durcissement du coeur SFTP : fenêtre adaptative, délai de requête, reprise vérifiée, progression/annulation,
// transfert de 1 Gio contre un sshd local non privilégié.

/// Canal qui ralentit les écritures (≈ 1 requête par `delay`) : transferts assez longs pour viser un point précis.
final class ThrottledChannel: ByteChannel, @unchecked Sendable {
    let base: ProcessByteChannel
    let delay: Duration
    init(_ base: ProcessByteChannel, delay: Duration = .milliseconds(1)) { self.base = base; self.delay = delay }
    func read(exactly count: Int) async throws -> Data { try await base.read(exactly: count) }
    func write(_ data: Data) async throws { try await Task.sleep(for: delay); try await base.write(data) }
    func close() async { await base.close() }
}

private func throttledClient(_ cfg: SFTPClientConfiguration = .init()) async throws -> (SFTPClient, ProcessByteChannel) {
    let base = try ProcessByteChannel()
    return (try await SFTPClient.connect(channel: ThrottledChannel(base), configuration: cfg), base)
}

/// Fichier de `mebibytes` Mio dont chaque bloc de 1 Mio est distinct (aléatoire + compteur) : génération rapide.
func writePatternFile(_ url: URL, mebibytes: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    var block = [UInt8](repeating: 0, count: 1 << 20)
    _ = SecRandomCopyBytes(kSecRandomDefault, block.count, &block)
    for i in 0..<mebibytes {
        var n = UInt64(i).bigEndian
        withUnsafeBytes(of: &n) { for (k, b) in $0.enumerated() { block[k] = b } }
        try h.write(contentsOf: Data(block))
    }
}

private func flipByte(_ url: URL, at offset: UInt64) throws {
    let h = try FileHandle(forUpdating: url)
    defer { try? h.close() }
    try h.seek(toOffset: offset)
    let b = try #require(try h.read(upToCount: 1))
    try h.seek(toOffset: offset)
    try h.write(contentsOf: Data([b[0] ^ 0xFF]))
}

private func fileSize(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
}

// MARK: - Fenêtre adaptative (simulation, sans réseau)

@Suite("SFTP fenêtre adaptative")
struct SFTPWindowControllerTests {
    /// Simule un lien (bande passante, latence) : débit = min(bande, fenêtre x bloc / latence).
    private func simulate(bandwidth: Double, rtt: Double, initial: Int, steps: Int = 600, lo: Int = 4, hi: Int = 256) -> (final: Int, seen: Set<Int>) {
        var c = SFTPWindowController(initial: initial, min: lo, max: hi, adaptive: true)
        var t = 0.0
        var seen: Set<Int> = []
        for _ in 0..<steps {
            let tp = min(bandwidth, Double(c.window) * 32768 / rtt)
            t += 0.01
            c.record(bytes: Int(tp * 0.01), at: t)
            seen.insert(c.window)
        }
        return (c.window, seen)
    }

    @Test func montePuisSeStabiliPresDuProduitBandePassanteLatence() {
        // 10 Mo/s x 50 ms / 32 Kio ≈ 15 requêtes en vol
        let r = simulate(bandwidth: 10e6, rtt: 0.05, initial: 4)
        #expect((15...30).contains(r.final), "fenêtre finale \(r.final)")
        // Lien à forte latence : 100 Mo/s x 200 ms / 32 Kio ≈ 610 → plafonné à la borne haute
        let far = simulate(bandwidth: 100e6, rtt: 0.2, initial: 32)
        #expect(far.final > 100 && far.seen.max()! <= 256, "fenêtre finale \(far.final)")
    }

    @Test func nAgrandissPasUneFenetreDejaSuffisante() {
        // Lien local : la fenêtre initiale sature déjà le lien, on ne la laisse pas partir vers le maximum.
        let r = simulate(bandwidth: 1e6, rtt: 0.001, initial: 32)
        #expect(r.final <= 48, "fenêtre finale \(r.final)")
        #expect(r.seen.min()! >= 32)
    }

    @Test func respecteLesBornesEtLeMode() {
        var fixed = SFTPWindowController(initial: 7, min: 4, max: 256, adaptive: false)
        for i in 1...100 { fixed.record(bytes: 1 << 20, at: Double(i) * 0.1) }
        #expect(fixed.window == 7)
        let bounded = simulate(bandwidth: 1e12, rtt: 1, initial: 4, hi: 40)
        #expect(bounded.seen.max()! <= 40 && bounded.seen.min()! >= 4)
        let clamped = SFTPWindowController(initial: 1000, min: 4, max: 64, adaptive: true)
        #expect(clamped.window == 64)
    }
}

// MARK: - Délai, reprise, progression : sftp-server direct

@Suite("SFTP durci", .serialized)
struct SFTPHardeningTests {

    // MARK: Délai de requête

    @Test func requeteSansReponseEchoueEnDelaiPuisLeCanalResteCoherent() async throws {
        var cfg = SFTPClientConfiguration()
        cfg.requestTimeout = .milliseconds(300)
        let (c, ch) = try await makeClient(cfg)
        _ = try await c.realpath("/tmp")
        ch.suspend()
        let start = ContinuousClock.now
        do { _ = try await c.stat("/tmp"); Issue.record("la requête aurait dû échouer") }
        catch let e as SFTPError {
            guard case .requestTimeout(let s) = e else { Issue.record("erreur inattendue \(e)"); return }
            #expect(abs(s - 0.3) < 0.05)
        }
        let took = ContinuousClock.now - start
        #expect(took < .seconds(3), "délai observé \(took)")
        // Le serveur reprend : la réponse tardive de la requête libérée est ignorée, le canal sert à nouveau.
        kill(ch.pid, SIGCONT)
        let a = try await c.stat("/tmp")
        #expect(a.type == .directory)
        let real = try await c.realpath("/tmp")
        #expect(real == "/private/tmp")
        await c.close()
    }

    @Test func plusieursDelaisSansReponseDeclarentLeCanalMort() async throws {
        var cfg = SFTPClientConfiguration()
        cfg.requestTimeout = .milliseconds(150)
        cfg.maxConsecutiveTimeouts = 3
        let (c, ch) = try await makeClient(cfg)
        ch.suspend()
        var timeouts = 0
        for _ in 0..<3 {
            do { _ = try await c.stat("/tmp") } catch SFTPError.requestTimeout { timeouts += 1 }
        }
        #expect(timeouts == 3)
        try await Task.sleep(for: .milliseconds(100))
        await #expect { try await c.stat("/tmp") } throws: { if case SFTPError.channelClosed = $0 { true } else { false } }
        kill(ch.pid, SIGCONT)
        ch.kill9()
    }

    @Test func unLienLentMaisVivantNeDeclenchePasLeDelai() async throws {
        // 8 Mio à ~1 requête/ms ≈ quelques centaines de ms avec un délai de 200 ms : aucune requête ne doit expirer.
        var cfg = SFTPClientConfiguration()
        cfg.requestTimeout = .milliseconds(200)
        let sb = try Sandbox()
        try writePatternFile(sb.file("a.bin"), mebibytes: 8)
        let (c, _) = try await throttledClient(cfg)
        _ = try await c.upload(localURL: sb.file("a.bin"), to: sb.file("b.bin").path)
        #expect(try sha256(of: sb.file("a.bin")) == sha256(of: sb.file("b.bin")))
        await c.close()
    }

    // MARK: Progression et annulation

    @Test func progressionEnFluxPuisAnnulationPuisRepriseVerifiee() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), dst = sb.file("dst.bin")
        try writePatternFile(src, mebibytes: 24)
        let (c, _) = try await throttledClient()
        let t = c.startDownload(remotePath: src.path, to: dst)
        var snaps: [SFTPTransferSnapshot] = []
        for await s in t.progress {
            snaps.append(s)
            if s.bytesTransferred >= 4 << 20 { t.cancel() }
        }
        do { _ = try await t.outcome; Issue.record("annulation attendue") }
        catch let e as SFTPError {
            guard case .cancelled(let partial, let n) = e else { Issue.record("erreur \(e)"); return }
            #expect(partial == dst && n >= 4 << 20 && n < 24 << 20)
        }
        let partial = fileSize(dst)
        #expect(partial >= 4 << 20 && partial < 24 << 20, "partiel \(partial)")
        #expect(snaps.contains { $0.bytesPerSecond > 0 } && snaps.allSatisfy { $0.window >= 4 && $0.totalBytes == 24 << 20 })
        #expect(zip(snaps, snaps.dropFirst()).allSatisfy { $0.bytesTransferred <= $1.bytesTransferred })

        // Reprise : repart du partiel (préfixe vérifié), progression complète jusqu'au bout.
        let t2 = c.startDownload(remotePath: src.path, to: dst)
        var last: SFTPTransferSnapshot?
        for await s in t2.progress { last = s }
        let out = try await t2.outcome
        #expect(out.resumedFrom == partial && out.restartReason == nil && out.totalBytes == 24 << 20)
        #expect(last?.bytesTransferred == 24 << 20 && last?.fraction == 1)
        #expect(try sha256(of: src) == sha256(of: dst))
        await c.close()
    }

    @Test func annulationDUnEnvoiLaisseLeDistantPartielReprenable() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), dst = sb.file("dst.bin")
        try writePatternFile(src, mebibytes: 48)
        let (c, _) = try await throttledClient()
        let t = c.startUpload(localURL: src, to: dst.path)
        for await s in t.progress where s.bytesTransferred >= 4 << 20 { t.cancel(); break }
        await #expect { try await t.outcome } throws: { if case SFTPError.cancelled = $0 { true } else { false } }
        let partial = fileSize(dst)
        #expect(partial >= 4 << 20 && partial < 48 << 20)
        let out = try await c.startUpload(localURL: src, to: dst.path).outcome
        #expect(out.resumedFrom == partial && out.totalBytes == 48 << 20)
        #expect(try sha256(of: src) == sha256(of: dst))
        await c.close()
    }

    // MARK: Reprise après coupure du canal

    @Test func repriseDeTelechargementApresMortDuServeur() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), dst = sb.file("dst.bin")
        try writePatternFile(src, mebibytes: 64)
        let (c1, ch1) = try await throttledClient()
        let cut = Box(false)
        do {
            _ = try await c1.download(remotePath: src.path, to: dst, progress: { p in
                if p.bytesTransferred >= 10 << 20, !cut.value { cut.value = true; ch1.kill9() }
            })
            Issue.record("la coupure aurait dû interrompre le transfert")
        } catch let e as SFTPError { guard case .channelClosed = e else { Issue.record("erreur \(e)"); return } }
        let partial = fileSize(dst)
        #expect(partial >= 10 << 20 && partial < 64 << 20)

        let (c2, _) = try await makeClient()
        let out = try await c2.downloadResuming(remotePath: src.path, to: dst)
        #expect(out.resumedFrom == partial && out.restartReason == nil)
        #expect(try sha256(of: src) == sha256(of: dst))
        await c2.close()
    }

    @Test func repriseDEnvoiApresMortDuServeur() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), dst = sb.file("dst.bin")
        try writePatternFile(src, mebibytes: 64)
        let (c1, ch1) = try await throttledClient()
        let cut = Box(false)
        do {
            _ = try await c1.upload(localURL: src, to: dst.path, progress: { p in
                if p.bytesTransferred >= 10 << 20, !cut.value { cut.value = true; ch1.kill9() }
            })
            Issue.record("la coupure aurait dû interrompre le transfert")
        } catch let e as SFTPError { guard case .channelClosed = e else { Issue.record("erreur \(e)"); return } }
        let partial = fileSize(dst)
        #expect(partial >= 10 << 20 && partial < 64 << 20)

        let (c2, _) = try await makeClient()
        let out = try await c2.uploadResuming(localURL: src, to: dst.path)
        #expect(out.resumedFrom == partial && out.restartReason == nil)
        #expect(try sha256(of: src) == sha256(of: dst))
        await c2.close()
    }

    // MARK: Reprise refusée

    /// Prépare un partiel local (téléchargement) ou distant (envoi) de `partialMiB` Mio, copie exacte du début de la source.
    private func makePartial(_ sb: Sandbox, total: Int, partialMiB: Int) throws -> (src: URL, part: URL) {
        let src = sb.file("src.bin"), part = sb.file("part.bin")
        try writePatternFile(src, mebibytes: total)
        let h = try FileHandle(forReadingFrom: src); defer { try? h.close() }
        try (try #require(try h.read(upToCount: partialMiB << 20))).write(to: part)
        return (src, part)
    }

    @Test func repriseDeTelechargementRefuseeSiLePrefixeEstModifie() async throws {
        let (c, _) = try await makeClient()
        // Octet modifié dans la queue, dans la tête, puis au milieu (vu seulement en vérification complète).
        let cases: [(UInt64, SFTPResumeVerification, Bool)] = [
            ((4 << 20) - 1, .default, true), (10, .default, true), (2 << 20, .default, false), (2 << 20, .full, true),
        ]
        for (offset, verification, restart) in cases {
            let sb = try Sandbox()
            let (src, part) = try makePartial(sb, total: 8, partialMiB: 4)
            try flipByte(part, at: offset)
            let out = try await c.downloadResuming(remotePath: src.path, to: part, verification: verification)
            #expect((out.restartReason != nil) == restart, "offset \(offset) \(verification) : \(out)")
            #expect(out.resumedFrom == (restart ? 0 : 4 << 20))
            if restart { #expect(try sha256(of: src) == sha256(of: part)) }
        }
        await c.close()
    }

    @Test func repriseDEnvoiRefuseeSiLePrefixeEstModifie() async throws {
        let (c, _) = try await makeClient()
        let cases: [(UInt64, SFTPResumeVerification, Bool)] = [
            ((4 << 20) - 1, .default, true), (10, .default, true), (2 << 20, .default, false), (2 << 20, .full, true),
        ]
        for (offset, verification, restart) in cases {
            let sb = try Sandbox()
            let (src, remote) = try makePartial(sb, total: 8, partialMiB: 4)  // « distant » = fichier local de test
            try flipByte(remote, at: offset)
            let out = try await c.uploadResuming(localURL: src, to: remote.path, verification: verification)
            #expect((out.restartReason != nil) == restart, "offset \(offset) \(verification) : \(out)")
            #expect(out.resumedFrom == (restart ? 0 : 4 << 20))
            if restart { #expect(try sha256(of: src) == sha256(of: remote)) }
        }
        await c.close()
    }

    @Test func repriseRefuseeSiLePartielDepasseLaSource() async throws {
        let (c, _) = try await makeClient()
        let sb = try Sandbox()
        let (src, big) = try makePartial(sb, total: 4, partialMiB: 4)
        try Data(count: 6 << 20).write(to: big)   // 6 Mio > 4 Mio de la source
        let out = try await c.downloadResuming(remotePath: src.path, to: big)
        #expect(out.resumedFrom == 0 && out.restartReason != nil)
        #expect(try sha256(of: src) == sha256(of: big))
        let out2 = try await c.uploadResuming(localURL: src, to: sb.file("autre.bin").path)
        #expect(out2.resumedFrom == 0 && out2.restartReason == nil)   // rien de partiel : départ normal, pas un refus
        await c.close()
    }

    @Test func repriseNeChangeRienQuandLeFichierEstDejaComplet() async throws {
        let (c, _) = try await makeClient()
        let sb = try Sandbox()
        try writePatternFile(sb.file("src.bin"), mebibytes: 3)
        try FileManager.default.copyItem(at: sb.file("src.bin"), to: sb.file("dst.bin"))
        let out = try await c.downloadResuming(remotePath: sb.file("src.bin").path, to: sb.file("dst.bin"))
        #expect(out.resumedFrom == 3 << 20 && out.totalBytes == 3 << 20 && out.restartReason == nil)
        await c.close()
    }
}

// MARK: - 1 Gio contre un vrai sshd local, avec coupure du maître

@Suite("SFTP gros transferts (sshd local)", .enabled(if: LocalSSHD.isAvailable, "sshd local non privilégié indisponible"), .serialized)
struct SFTPBigTransferTests {
    private func connect(_ d: LocalSSHD) async throws -> (OpenSSHTransport, SFTPClient) {
        let t = OpenSSHTransport(profile: d.profile(), configuration: .init(ssh: d.sshOptions(), masterReadyTimeout: 15))
        try await t.connect()
        return (t, try await SFTPClient.connect(channel: try await t.openSFTPChannel()))
    }

    @Test func unGioAllerEtRetourSHA256() async throws {
        let sb = try Sandbox()
        let src = sb.file("gio.bin"), remote = sb.file("distant.bin"), back = sb.file("retour.bin")
        try writePatternFile(src, mebibytes: 1024)
        let expected = try sha256(of: src)
        try await LocalSSHD.with { d in
            let (t, c) = try await connect(d)
            let clock = ContinuousClock()
            let t0 = clock.now
            let upTask = c.startUpload(localURL: src, to: remote.path, resume: false)
            var maxWindow = 0
            for await s in upTask.progress { maxWindow = max(maxWindow, s.window) }
            let upOut = try await upTask.outcome
            let tUp = clock.now - t0
            #expect(upOut.totalBytes == 1 << 30)
            #expect(try sha256(of: remote) == expected, "empreinte distante après envoi")

            let t1 = clock.now
            let downTask = c.startDownload(remotePath: remote.path, to: back, resume: false)
            for await s in downTask.progress { maxWindow = max(maxWindow, s.window) }
            let downOut = try await downTask.outcome
            let tDown = clock.now - t1
            #expect(downOut.totalBytes == 1 << 30)
            #expect(try sha256(of: back) == expected, "empreinte après retour")

            func rate(_ d: Duration) -> String {
                let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                return String(format: "%.1f s, %.0f Mio/s", s, 1024 / s)
            }
            print("1 Gio via sshd local : envoi \(rate(tUp)) ; retour \(rate(tDown)) ; fenêtre max \(maxWindow)")
            await c.close(); await t.disconnect()
        }
    }

    @Test func repriseApresCoupureDuMaitre() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), remote = sb.file("distant.bin"), back = sb.file("retour.bin")
        try writePatternFile(src, mebibytes: 256)
        let expected = try sha256(of: src)
        try await LocalSSHD.with { d in
            // Envoi interrompu par la mort du ssh maître.
            let (t1, c1) = try await connect(d)
            let master = try #require(await t1.masterProcessIdentifier)
            let cut = Box(false)
            do {
                _ = try await c1.upload(localURL: src, to: remote.path, progress: { p in
                    if p.bytesTransferred >= 32 << 20, !cut.value { cut.value = true; kill(master, SIGKILL) }
                })
                Issue.record("la coupure du maître aurait dû interrompre l'envoi")
            } catch let e as SFTPError { guard case .channelClosed = e else { Issue.record("erreur \(e)"); return } }
            await t1.disconnect()
            let partial = fileSize(remote)
            #expect(partial >= 32 << 20 && partial < 256 << 20, "distant partiel \(partial)")

            let (t2, c2) = try await connect(d)
            let out = try await c2.uploadResuming(localURL: src, to: remote.path)
            #expect(out.resumedFrom == partial && out.restartReason == nil, "\(out)")
            #expect(try sha256(of: remote) == expected)

            // Téléchargement interrompu de la même façon, puis repris.
            let master2 = try #require(await t2.masterProcessIdentifier)
            let cut2 = Box(false)
            do {
                _ = try await c2.download(remotePath: remote.path, to: back, progress: { p in
                    if p.bytesTransferred >= 32 << 20, !cut2.value { cut2.value = true; kill(master2, SIGKILL) }
                })
                Issue.record("la coupure du maître aurait dû interrompre le téléchargement")
            } catch let e as SFTPError { guard case .channelClosed = e else { Issue.record("erreur \(e)"); return } }
            await t2.disconnect()
            let partialDown = fileSize(back)
            #expect(partialDown >= 32 << 20 && partialDown < 256 << 20)
            let (t3, c3) = try await connect(d)
            let out2 = try await c3.downloadResuming(remotePath: remote.path, to: back)
            #expect(out2.resumedFrom == partialDown && out2.restartReason == nil)
            #expect(try sha256(of: back) == expected)
            await c3.close(); await t3.disconnect()
        }
    }
}
