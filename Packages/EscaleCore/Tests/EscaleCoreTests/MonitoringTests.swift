import Testing
import Foundation
@testable import EscaleCore

/// Les deux blocs macOS ci-dessous sont la sortie réelle du script (`sh` local, Darwin, relevés espacés de 2 s).
private let macStream = """
@@ESC begin
os=Darwin
load=7.23
cpupct=13.9
mem=51539607552 30914297856
net=lo0 297029566227 297029566227
net=gif0 0 0
net=stf0 0 0
net=anpi0 0 0
net=anpi1 0 0
net=anpi2 0 0
net=en3 0 0
net=en4 0 0
net=en5 0 0
net=en1 0 0
net=en6 0 0
net=en2 0 0
net=bridge0 0 360
net=utun0 0 157840
net=utun1 0 157840
net=utun2 0 157840
net=utun3 0 80
net=utun4 248 85291
net=utun5 26462 93084
net=utun6 1084 53048
net=utun7 0 99045
net=utun8 0 98905
net=ap1 0 0
net=en0 96045342459 5168378690
net=nan0 0 13798
net=awdl0 3911997 1312939
net=llw0 0 0
net=utun9 0 74988
net=utun11 4781805 2966040
uptime=799244
disk=1995165736960 13659615232 2%
users=1
@@ESC end
@@ESC begin
os=Darwin
load=7.23
cpupct=9.8
mem=51539607552 30326030336
net=lo0 297029652443 297029652443
net=gif0 0 0
net=stf0 0 0
net=anpi0 0 0
net=anpi1 0 0
net=anpi2 0 0
net=en3 0 0
net=en4 0 0
net=en5 0 0
net=en1 0 0
net=en6 0 0
net=en2 0 0
net=bridge0 0 360
net=utun0 0 157840
net=utun1 0 157840
net=utun2 0 157840
net=utun3 0 80
net=utun4 248 85291
net=utun5 26462 93084
net=utun6 1084 53048
net=utun7 0 99045
net=utun8 0 98905
net=ap1 0 0
net=en0 96045355761 5168386033
net=nan0 0 13798
net=awdl0 3911997 1312939
net=llw0 0 0
net=utun9 0 74988
net=utun11 4781805 2966040
uptime=799246
disk=1995165736960 13659615232 2%
users=1
@@ESC end

"""

private func run(_ data: String, parser: inout MonitoringStreamParser, now: TimeInterval = 0) -> [MonitoringEvent] {
    parser.feed(Data(data.utf8), now: now)
}

@Suite struct MonitoringTests {
    @Test func analyseUneSortieMacReelle() throws {
        var p = MonitoringStreamParser()
        let events = run(macStream, parser: &p, now: 100)
        #expect(events.count == 2)
        guard case .sample(let a) = events[0], case .sample(let b) = events[1] else { Issue.record("deux relevés attendus"); return }
        #expect(a.os == "Darwin")
        #expect(a.load1 == 7.23)
        #expect(a.cpuPercentDirect == 13.9)
        #expect(a.memTotal == 51_539_607_552 && a.memUsed == 30_914_297_856)
        #expect(a.diskTotal == 1_995_165_736_960 && a.diskUsed == 13_659_615_232 && a.diskPercent == 2)
        #expect(a.users == 1)
        #expect(a.uptime == 799_244)
        // lo0, utun*, awdl0 sont écartées : il ne reste que les en* (en0 porte le trafic).
        #expect(a.netIn == 96_045_342_459 && a.netOut == 5_168_378_690)
        #expect(b.netIn == 96_045_355_761 && b.netOut == 5_168_386_033)
    }

    @Test func debitsEtCpuDirectSurDeuxRelevesMac() throws {
        var p = MonitoringStreamParser()
        let first = run(String(macStream.prefix(upTo: macStream.range(of: "@@ESC end\n")!.upperBound)), parser: &p, now: 100)
        let rest = run(String(macStream[macStream.range(of: "@@ESC end\n")!.upperBound...]), parser: &p, now: 102)
        guard case .sample(let a) = first[0], case .sample(let b) = rest[0] else { Issue.record("relevés manquants"); return }
        var calc = MonitoringCalculator()
        let s1 = calc.ingest(a)
        #expect(s1.netInRate == nil && s1.netOutRate == nil)   // pas de débit avant le second relevé
        #expect(s1.cpuPercent == 13.9)
        let s2 = calc.ingest(b)
        #expect(s2.netInRate == Double(13_302) / 2)
        #expect(s2.netOutRate == Double(7_343) / 2)
        #expect(s2.cpuPercent == 9.8)
        #expect(s2.memPercent! > 55 && s2.memPercent! < 65)
    }

    @Test func fluxCoupeEnMorceauxArbitraires() throws {
        var whole = MonitoringStreamParser()
        let expected = run(macStream, parser: &whole, now: 5)
        var chunked = MonitoringStreamParser()
        var got: [MonitoringEvent] = []
        let bytes = Array(macStream.utf8)
        var i = 0
        while i < bytes.count { let n = min(7, bytes.count - i); got += chunked.feed(Data(bytes[i..<i + n]), now: 5); i += n }
        #expect(got == expected)
    }

    @Test func bruitEtChampsIllisiblesIgnores() throws {
        var p = MonitoringStreamParser()
        let ev = run("Bienvenue sur le serveur\nload=9\n@@ESC begin\nload=abc\nmem=zz 1\nnet=eth0 5\nusers=2\nuptime=10.50\n@@ESC end\n", parser: &p, now: 3)
        guard case .sample(let s)? = ev.first else { Issue.record("relevé attendu"); return }
        #expect(s.load1 == nil && s.memTotal == nil && s.netIn == nil)
        #expect(s.users == 2 && s.uptime == 10.5)
        #expect(s.received == 10.5)   // uptime fractionnaire = horloge
    }

    @Test func systemeInconnu() throws {
        var p = MonitoringStreamParser()
        #expect(run("@@ESC unsupported FreeBSD\n", parser: &p) == [.unsupported("FreeBSD")])
    }

    @Test func compteurQuiReculePasDeDebit() throws {
        var a = MonitoringRawSample(); a.netIn = 1000; a.netOut = 1000; a.received = 10; a.cpuTotal = 1000; a.cpuIdle = 500
        var b = a; b.netIn = 10; b.netOut = 5000; b.received = 12; b.cpuTotal = 1200; b.cpuIdle = 600
        var calc = MonitoringCalculator()
        _ = calc.ingest(a)
        let s = calc.ingest(b)
        #expect(s.netInRate == nil)
        #expect(s.netOutRate == 2000)
        #expect(s.cpuPercent == 50)   // (1 - 100/200)
    }

    @Test func interfacesComptees() {
        for n in ["eth0", "en0", "ens3", "enp3s0", "bond0", "wlan0", "wlp2s0"] { #expect(MonitoringStreamParser.isCountedInterface(n), "\(n)") }
        for n in ["lo", "lo0", "veth12ab", "docker0", "br-1a2b3c", "virbr0", "utun4", "awdl0", "bridge0", "ap1", "gif0"] { #expect(!MonitoringStreamParser.isCountedInterface(n), "\(n)") }
    }

    @Test func formats() {
        #expect(MonitoringFormat.bytes(UInt64(0)) == "0 o")
        #expect(MonitoringFormat.bytes(1536.0) == "1,5 Ko")
        #expect(MonitoringFormat.bytes(UInt64(30_914_297_856)) == "29 Go")
        #expect(MonitoringFormat.rate(6651) == "6,5 Ko/s")
        #expect(MonitoringFormat.rate(nil) == "—")
        #expect(MonitoringFormat.percent(12.5) == "13 %" || MonitoringFormat.percent(12.5) == "12 %")
        #expect(MonitoringFormat.load(0.5) == "0,50")
        #expect(MonitoringFormat.uptime(93_784) == "1 j 2 h")
        #expect(MonitoringFormat.uptime(4_500) == "1 h 15 min")
        #expect(MonitoringFormat.uptime(90) == "1 min")
        #expect(MonitoringFormat.uptime(nil) == "—")
    }

    @Test func commandeDistanteProtegeLesApostrophes() {
        let c = MonitoringScript.remoteCommand()
        #expect(c.hasPrefix("exec sh -c '") && c.hasSuffix("'"))
        // Le shell local relit la commande à l'identique : le script reçu par `sh -c` est le corps d'origine.
        let out = Process.run(["/bin/sh", "-c", "set -- " + String(c.dropFirst("exec sh -c ".count)) + "; printf %s \"$1\""])
        #expect(out == MonitoringScript.body)
    }

    // MARK: Script réel (sh local)

    /// Linux : le script est exécuté pour de bon avec `ESC_PROC` pointant sur une arborescence au format du noyau.
    /// ATTENTION : fixtures écrites à la main au format documenté de /proc (aucun Linux joignable pendant le
    /// développement), valeurs choisies pour des résultats exacts ; le format macOS ci-dessus, lui, est capturé.
    @Test func scriptLinuxSurArborescenceProcAuFormatNoyau() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esc-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("net"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ rel: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(rel), atomically: true, encoding: .utf8) }
        func relevé(cpu: String, rx: Int, tx: Int, lorx: Int, up: String) throws -> MonitoringRawSample {
            try write("loadavg", "0.52 0.40 0.31 2/345 12345\n")
            try write("stat", "cpu  \(cpu)\ncpu0 1 2 3 4 5 6 7 8 0 0\nintr 1\n")
            try write("meminfo", "MemTotal:        8000000 kB\nMemFree:          500000 kB\nMemAvailable:    2000000 kB\nBuffers:          100000 kB\nCached:          1000000 kB\n")
            try write("net/dev", "Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: \(lorx) 10 0 0 0 0 0 0 \(lorx) 10 0 0 0 0 0 0\n  eth0:\(rx) 100 0 0 0 0 0 0 \(tx) 90 0 0 0 0 0 0\ndocker0: 777 1 0 0 0 0 0 0 888 1 0 0 0 0 0 0\n")
            try write("uptime", "\(up) 9999.00\n")
            let out = Process.run(["/bin/sh", "-c", MonitoringScript.remoteCommand()], env: ["ESC_PROC": dir.path, "ESC_OS": "Linux", "ESC_ONCE": "1"])
            var p = MonitoringStreamParser()
            guard case .sample(let s)? = p.feed(Data(out.utf8), now: 0).first else { throw ScriptError(out: out) }
            return s
        }
        let a = try relevé(cpu: "1000 100 400 8000 500 0 0 0 0 0", rx: 1_000_000, tx: 500_000, lorx: 5, up: "1000.00")
        #expect(a.os == "Linux" && a.load1 == 0.52 && a.users != nil && a.diskPercent != nil)
        #expect(a.cpuTotal == 10_000 && a.cpuIdle == 8_500)
        #expect(a.memTotal == 8_000_000 * 1024 && a.memUsed == 6_000_000 * 1024)
        #expect(a.netIn == 1_000_000 && a.netOut == 500_000)   // lo et docker0 écartées
        #expect(a.uptime == 1000 && a.received == 1000)
        let b = try relevé(cpu: "1100 100 500 8200 600 0 0 0 0 0", rx: 1_200_000, tx: 540_000, lorx: 9_999, up: "1002.00")
        var calc = MonitoringCalculator()
        _ = calc.ingest(a)
        let s = calc.ingest(b)
        // delta total 500 (100 + 0 + 100 + 200 + 100), inactif +300 (200 + 100) → occupé 200/500 = 40 %
        #expect(s.cpuPercent == 40)
        #expect(s.netInRate == 100_000 && s.netOutRate == 20_000)   // sur 2 s d'uptime distant
    }

    @Test func scriptSystemeInconnu() throws {
        let out = Process.run(["/bin/sh", "-c", MonitoringScript.remoteCommand()], env: ["ESC_OS": "SunOS"])
        var p = MonitoringStreamParser()
        #expect(p.feed(Data(out.utf8), now: 0) == [.unsupported("SunOS")])
    }

    @Test func scriptMacLocalProduitUnReleveComplet() throws {
        #if os(macOS)
        let out = Process.run(["/bin/sh", "-c", MonitoringScript.remoteCommand()], env: ["ESC_ONCE": "1"])
        var p = MonitoringStreamParser()
        guard case .sample(let s)? = p.feed(Data(out.utf8), now: 0).first else { throw ScriptError(out: out) }
        #expect(s.os == "Darwin" && s.load1 != nil && s.cpuPercentDirect != nil && s.memTotal != nil && s.memUsed != nil)
        #expect(s.diskPercent != nil && s.netIn != nil && s.users != nil && s.uptime != nil)
        #endif
    }
}

private struct ScriptError: Error { let out: String }

private extension Process {
    /// Lance un exécutable et rend sa sortie standard (stdin fermé).
    static func run(_ argv: [String], env: [String: String] = [:]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardInput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
