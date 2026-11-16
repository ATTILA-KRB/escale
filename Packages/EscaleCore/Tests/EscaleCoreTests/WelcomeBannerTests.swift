import Testing
@testable import EscaleCore

@Suite struct WelcomeBannerTests {
    @Test func logoAligne() {
        #expect(WelcomeBanner.logo.count == 6)
        #expect(Set(WelcomeBanner.logo.map(\.count)) == [48])
        #expect(WelcomeBanner.logo[0].hasPrefix("███████╗███████╗ ██████╗"))
    }

    @Test func largeAvecLogoEtCadre() {
        let out = WelcomeBanner.render(columns: 100, version: "0.1.0", shell: "zsh")
        let plain = WelcomeBanner.stripANSI(out).components(separatedBy: "\r\n")
        #expect(plain.contains("  " + WelcomeBanner.logo[0]))
        #expect(out.contains("\u{1b}[38;2;255;228;92m"))   // jaune doré (24 bits)
        let box = plain.filter { $0.hasPrefix("  │") || $0.hasPrefix("  ┌") || $0.hasPrefix("  └") }
        #expect(box.count == 7)
        #expect(Set(box.map(\.count)).count == 1)     // cadre droit : toutes les lignes ont la même largeur
        #expect(box.allSatisfy { $0.count <= 100 })
        #expect(plain.contains { $0.contains("Escale 0.1.0") && $0.contains("client SSH") })
        #expect(plain.contains { $0.contains("Terminal local : zsh") })
        #expect(!out.contains("\n") || out.components(separatedBy: "\n").dropLast().allSatisfy { $0.hasSuffix("\r") })
    }

    @Test func etroitSansLogoNiCadreCasse() {
        let out = WelcomeBanner.stripANSI(WelcomeBanner.render(columns: 40, version: "1.2.3", shell: "bash"))
        #expect(out.contains("▌ ESCALE"))
        #expect(!out.contains("███"))
        #expect(!out.contains("┌"))
    }
}
