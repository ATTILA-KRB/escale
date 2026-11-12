import Foundation
import Testing
@testable import EscaleCore

@Suite struct QuickConnectTargetTests {
    @Test func formesCourantes() {
        #expect(QuickConnectTarget.parse("serveur") == QuickConnectTarget(host: "serveur"))
        #expect(QuickConnectTarget.parse("  root@10.0.0.5  ") == QuickConnectTarget(user: "root", host: "10.0.0.5"))
        #expect(QuickConnectTarget.parse("rayan@nas.local:35000") == QuickConnectTarget(user: "rayan", host: "nas.local", port: 35000))
        #expect(QuickConnectTarget.parse("ssh://deploy@build-01:2222/") == QuickConnectTarget(user: "deploy", host: "build-01", port: 2222))
        #expect(QuickConnectTarget.parse("SSH://hote") == QuickConnectTarget(host: "hote"))
    }

    @Test func ipv6() {
        #expect(QuickConnectTarget.parse("::1") == QuickConnectTarget(host: "::1"))
        #expect(QuickConnectTarget.parse("root@[fe80::1%en0]:2200") == QuickConnectTarget(user: "root", host: "fe80::1%en0", port: 2200))
        #expect(QuickConnectTarget.parse("[2001:db8::2]") == QuickConnectTarget(host: "2001:db8::2"))
        #expect(QuickConnectTarget.parse("[2001:db8::2") == nil)
        #expect(QuickConnectTarget.parse("[hote]:22") == nil)
    }

    @Test func refus() {
        for bad in ["", "   ", "-oProxyCommand=id", "root@-hote", "-l@hote", "hote avec espace", "hote;id", "hote\nid",
                    "hote:0", "hote:65536", "hote:22x", "hote:", "@hote", "u ser@hote", "hote$(id)", "a`b`", ".hote",
                    "hote/chemin", "root@", "hote\u{0}"] {
            #expect(QuickConnectTarget.parse(bad) == nil, "accepté à tort : \(bad.debugDescription)")
        }
    }

    @Test func affichageEtProfil() {
        let t = QuickConnectTarget(user: "root", host: "fe80::1", port: 2200)
        #expect(t.display == "root@[fe80::1]:2200")
        #expect(QuickConnectTarget(host: "::1").display == "::1")
        let p = QuickConnectTarget.parse("rayan@nas:35000")!.makeProfile()
        #expect(p.name == "rayan@nas:35000" && p.host == "nas" && p.port == 35000 && p.user == "rayan")
        #expect(p.connectionProtocol == .ssh && p.auth == .openSSHDefaults)
    }

    @Test func correspondance() {
        let t = QuickConnectTarget.parse("rayan@NAS")!
        #expect(t.matches(HostProfile(name: "x", host: "nas", port: 22, user: "rayan")))
        #expect(!t.matches(HostProfile(name: "x", host: "nas", port: 2222, user: "rayan")))
        #expect(!t.matches(HostProfile(name: "x", host: "nas", user: "root")))
        #expect(!t.matches(HostProfile(name: "x", host: "nas", user: "rayan", connectionProtocol: .telnet)))
    }
}
