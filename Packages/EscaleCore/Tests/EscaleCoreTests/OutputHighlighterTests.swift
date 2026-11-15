import Foundation
import Testing
@testable import EscaleCore

private func run(_ chunks: [String], rules: HighlightRuleSet = .keywords, alt: Bool = false) -> String {
    var h = OutputHighlighter(rules: rules, alternateScreen: alt)
    var out = Data()
    for c in chunks { out += h.process(Data(c.utf8)) }
    out += h.flush()
    return String(decoding: out, as: UTF8.self)
}

/// Retire les séquences insérées par le filtre (3Xm et 39m) : doit redonner le flux d'origine.
private func stripInserted(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1b}\\[3[1-5]m|\u{1b}\\[39m", with: "", options: .regularExpression)
}

@Suite("Surlignage de la sortie")
struct OutputHighlighterTests {
    @Test func motsClesColores() {
        #expect(run(["ERROR: disk OK, warning\r\n"]) == "\u{1b}[31mERROR\u{1b}[39m: disk \u{1b}[32mOK\u{1b}[39m, \u{1b}[33mwarning\u{1b}[39m\r\n")
    }

    @Test func motsEntiersSeulement() {
        // « errors » oui, « terror », « okay », « error2 » non.
        #expect(run(["terror okay error2 errors\n"]) == "terror okay error2 \u{1b}[31merrors\u{1b}[39m\n")
        // Séparateurs de ponctuation : [FAILED], error:, (ok)
        #expect(run(["[FAILED] (ok)\n"]) == "[\u{1b}[31mFAILED\u{1b}[39m] (\u{1b}[32mok\u{1b}[39m)\n")
    }

    @Test func motsClesFrancaisAccentues() {
        #expect(run(["ÉCHEC réussi\n"]) == "\u{1b}[31mÉCHEC\u{1b}[39m \u{1b}[32mréussi\u{1b}[39m\n")
    }

    @Test func desactiveRendLeFluxIntact() {
        let s = "error \u{1b}[31mx\u{1b}[0m ok\n"
        #expect(run([s], rules: .off) == s)
    }

    @Test func motCoupeEntreDeuxPaquets() {
        #expect(run(["disk ER", "ROR here\n"]) == "disk \u{1b}[31mERROR\u{1b}[39m here\n")
        // Coupé octet par octet, accent compris.
        let bytes = Array("x échec\n".utf8)
        var h = OutputHighlighter(rules: .keywords)
        var out = Data()
        for b in bytes { out += h.process(Data([b])) }
        out += h.flush()
        #expect(String(decoding: out, as: UTF8.self) == "x \u{1b}[31méchec\u{1b}[39m\n")
    }

    @Test func motRetenuEnFinDePaquet() {
        var h = OutputHighlighter(rules: .keywords)
        #expect(h.process(Data("a err".utf8)) == Data("a ".utf8))
        #expect(h.hasPending)
        #expect(h.flush() == Data("\u{1b}[31merr\u{1b}[39m".utf8))
        #expect(!h.hasPending)
    }

    @Test func texteDejaColoreIntact() {
        let s = "\u{1b}[34mERROR\u{1b}[0m \u{1b}[1;38;5;196mfatal\u{1b}[m ok\n"
        #expect(run([s]) == "\u{1b}[34mERROR\u{1b}[0m \u{1b}[1;38;5;196mfatal\u{1b}[m \u{1b}[32mok\u{1b}[39m\n")
        // 38;5;1 : « 1 » est l'index de couleur, pas le gras ; 39 rend la couleur par défaut.
        #expect(run(["\u{1b}[38;5;1mx\u{1b}[39m error\n"]) == "\u{1b}[38;5;1mx\u{1b}[39m \u{1b}[31merror\u{1b}[39m\n")
        // Fond coloré, vidéo inverse, forme à deux-points.
        #expect(run(["\u{1b}[44merror\u{1b}[49m \u{1b}[7mok\u{1b}[27m \u{1b}[38:2::1:2:3mfail\u{1b}[0m\n"])
                == "\u{1b}[44merror\u{1b}[49m \u{1b}[7mok\u{1b}[27m \u{1b}[38:2::1:2:3mfail\u{1b}[0m\n")
        // Gras seul : le surlignage s'applique (le gras est conservé, seul 39 est émis après).
        #expect(run(["\u{1b}[1merror\u{1b}[0m\n"]) == "\u{1b}[1m\u{1b}[31merror\u{1b}[39m\u{1b}[0m\n")
    }

    @Test func sequencesEchappementJamaisTouchees() {
        // OSC titre contenant « error » (BEL et ST), CSI de déplacement, DCS.
        let s = "\u{1b}]0;error ok\u{07}\u{1b}]2;fail\u{1b}\\\u{1b}[10;20H\u{1b}Perror\u{1b}\\\u{1b}(B done\n"
        #expect(run([s]) == "\u{1b}]0;error ok\u{07}\u{1b}]2;fail\u{1b}\\\u{1b}[10;20H\u{1b}Perror\u{1b}\\\u{1b}(B \u{1b}[32mdone\u{1b}[39m\n")
        // Séquence coupée entre deux paquets.
        #expect(run(["\u{1b}]0;err", "or\u{07}ok\n"]) == "\u{1b}]0;error\u{07}\u{1b}[32mok\u{1b}[39m\n")
    }

    @Test func ecranAlternatifIgnore() {
        let s = "error \u{1b}[?1049herror ok\u{1b}[?1049l error\n"
        #expect(run([s]) == "\u{1b}[31merror\u{1b}[39m \u{1b}[?1049herror ok\u{1b}[?1049l \u{1b}[31merror\u{1b}[39m\n")
        // Démarré pendant que l'écran alternatif est actif (réglage changé sous vim).
        #expect(run(["error\n"], alt: true) == "error\n")
        #expect(run(["\u{1b}[?1;1049herror\n"]) == "\u{1b}[?1;1049herror\n")
    }

    @Test func reseauIPv4EtURL() {
        let s = "from 192.168.1.10:22 to 10.0.0.0/8 via https://exemple.fr/a?b=1). bad 999.1.1.1 1.2.3 1.2.3.4.5 v10.0.0.1\n"
        let out = run([s], rules: .keywordsAndNetwork)
        #expect(out.contains("\u{1b}[35m192.168.1.10:22\u{1b}[39m"))
        #expect(out.contains("\u{1b}[35m10.0.0.0/8\u{1b}[39m"))
        #expect(out.contains("\u{1b}[34mhttps://exemple.fr/a?b=1\u{1b}[39m)."))
        #expect(!out.contains("\u{1b}[35m999"))
        #expect(!out.contains("\u{1b}[35m1.2.3\u{1b}"))
        #expect(!out.contains("\u{1b}[35m1.2.3.4"))
        #expect(!out.contains("\u{1b}[35m10.0.0.1"))
        // Un mot-clé dans une URL reste dans la couleur de l'URL.
        #expect(run(["http://h/error\n"], rules: .keywordsAndNetwork) == "\u{1b}[34mhttp://h/error\u{1b}[39m\n")
        // Sans le jeu réseau, rien de tout cela.
        #expect(run(["192.168.1.1 http://x\n"], rules: .keywords) == "192.168.1.1 http://x\n")
    }

    @Test func fluxInchangeHorsSequencesInserees() {
        // Propriété : retirer les séquences insérées redonne exactement l'entrée, quel que soit le découpage.
        var rng = SystemRandomNumberGenerator()
        let words = ["error", "ok", "ÉCHEC", "warning", "\u{1b}[91m", "\u{1b}[0m", "\u{1b}]0;t\u{07}", "192.168.0.1", "http://a.b/c",
                     " ", "\r\n", "\t", "x", "日本", "\u{1b}[?1049h", "\u{1b}[?1049l", "fatal:", "\u{1b}[38;5;2m"]
        for _ in 0..<200 {
            var s = ""
            for _ in 0..<40 { s += words.randomElement(using: &rng)! }
            let bytes = Array(s.utf8)
            var h = OutputHighlighter(rules: .keywordsAndNetwork)
            var out = Data()
            var i = 0
            while i < bytes.count {
                let n = Int.random(in: 1...7, using: &rng)
                out += h.process(Data(bytes[i..<min(i + n, bytes.count)]))
                i += n
            }
            out += h.flush()
            #expect(stripInserted(String(decoding: out, as: UTF8.self)) == s)
        }
    }

    @Test func motTropLongPasseSansSurlignage() {
        let long = String(repeating: "a", count: 300) + "error"
        #expect(run([long + " error\n"]) == long + " \u{1b}[31merror\u{1b}[39m\n")
    }

    @Test func debitSuffisant() {
        // ~4 Mo de journal mêlé de mots-clés : le filtre doit rester loin devant le rendu.
        let line = "2026-11-15 10:00:00 host sshd[123]: error: connection from 192.168.1.10 port 22 refused OK done\r\n"
        let data = Data(String(repeating: line, count: 40_000).utf8)
        var h = OutputHighlighter(rules: .keywordsAndNetwork)
        let t0 = Date()
        var total = 0
        var i = 0
        while i < data.count {
            total += h.process(data.subdata(in: i..<min(i + 16_384, data.count))).count
            i += 16_384
        }
        let s = Date().timeIntervalSince(t0)
        #expect(total > data.count)
        #expect(s < 10, "débit : \(Double(data.count) / s / 1_048_576) Mo/s")
    }
}

@Suite("Thèmes de terminal")
struct TerminalThemeTests {
    @Test func prereglagesComplets() {
        #expect(Set(TerminalTheme.all.map(\.id)).count == TerminalTheme.all.count)
        for t in TerminalTheme.all {
            #expect(t.ansi.count == 16)
            #expect(TerminalTheme.named(t.id) == t)
            if t.id == "system" { #expect(!t.hasFixedColors) } else { #expect(t.hasFixedColors) }
        }
        #expect(TerminalTheme.named("inconnu") == nil)
    }

    @Test func contrasteLisible() {
        for t in TerminalTheme.all where t.hasFixedColors {
            let bg = t.background!, fg = t.foreground!
            #expect(fg.contrast(with: bg) >= 4.5, "\(t.id) texte \(fg) sur \(bg)")
            // Couleurs utilisées par le surlignage (rouge, vert, jaune, bleu, magenta normaux) : lisibles sur le fond.
            for i in 1...5 { #expect(t.ansi[i].contrast(with: bg) >= 2.5, "\(t.id) ansi \(i) \(t.ansi[i]) sur \(bg)") }
            if let sb = t.selectionBackground, let sf = t.selectionForeground {
                #expect(sf.contrast(with: sb) >= 4.5, "\(t.id) sélection")
            }
        }
    }

    @Test func hexadecimal() {
        #expect(TerminalRGB(hex: 0x12abef) == TerminalRGB(0x12, 0xab, 0xef))
        #expect(TerminalRGB(hex: 0x12abef).description == "#12abef")
    }
}
