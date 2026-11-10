import Foundation
import Testing
@testable import EscaleCore

@Suite struct LibrarySearchTests {
    private func h(_ name: String, host: String = "x.test", user: String? = nil, tags: [String] = []) -> HostProfile {
        HostProfile(name: name, host: host, user: user, tags: tags)
    }

    @Test func emptyQueryReturnsAllInOrder() {
        let hosts = [h("c"), h("a"), h("b")]
        #expect(HostSearch.search("", in: hosts).map(\.host.name) == ["c", "a", "b"])
        #expect(HostSearch.search("   ", in: hosts).count == 3)
    }

    @Test func rankingPrefixThenWordStartThenSubsequence() {
        let hosts = [
            h("xdbx", host: "q1.test"),          // sous-chaîne
            h("d-b-x", host: "q2.test"),         // sous-séquence "db"
            h("my-db", host: "q3.test"),         // début de mot
            h("db-main", host: "q4.test"),       // préfixe
        ]
        let r = HostSearch.search("db", in: hosts).map(\.host.name)
        #expect(r == ["db-main", "my-db", "xdbx", "d-b-x"])
    }

    @Test func stableOrderOnTies() {
        let hosts = [h("web1"), h("web2"), h("web3")]
        #expect(HostSearch.search("web", in: hosts).map(\.host.name) == ["web1", "web2", "web3"])
    }

    @Test func caseAndDiacriticsInsensitive() {
        let hosts = [h("Café Münster"), h("autre")]
        #expect(HostSearch.search("cafe", in: hosts).map(\.host.name) == ["Café Münster"])
        #expect(HostSearch.search("MUNSTER", in: hosts).map(\.host.name) == ["Café Münster"])
        #expect(HostSearch.search("é", in: [h("ecole")]).count == 1)
    }

    @Test func rangesPointIntoOriginalStrings() throws {
        let host = h("Café Münster", host: "srv.test")
        let r = try #require(HostSearch.search("mun", in: [host]).first)
        let m = try #require(r.matches.first { $0.field == .name })
        #expect(m.ranges.map { String(host.name[$0]) } == ["Mün"])

        let sub = try #require(HostSearch.search("cfe", in: [host]).first)  // sous-séquence C,f,é (f et é adjacents fusionnés)
        let ranges = try #require(sub.matches.first { $0.field == .name }).ranges
        #expect(ranges.map { String(host.name[$0]) } == ["C", "fé"])
    }

    @Test func searchesUserAndTags() {
        let hosts = [h("a", user: "deploy"), h("b", tags: ["Production", "eu"]), h("c")]
        #expect(HostSearch.search("deploy", in: hosts).map(\.host.name) == ["a"])
        let r = HostSearch.search("prod", in: hosts)
        #expect(r.map(\.host.name) == ["b"])
        #expect(r[0].matches.first?.field == .tag(0))
    }

    @Test func multipleTermsAreAnded() {
        let hosts = [h("web", host: "prod.example.com"), h("web", host: "dev.example.com")]
        let r = HostSearch.search("web prod", in: hosts)
        #expect(r.map(\.host.host) == ["prod.example.com"])
        #expect(HostSearch.search("web zzz", in: hosts).isEmpty)
    }

    @Test func noMatch() {
        #expect(HostSearch.search("zzz", in: [h("abc")]).isEmpty)
        #expect(HostSearch.search("abcd", in: [h("abc", host: "q")]).isEmpty)
    }

    @Test func performance5000Hosts() {
        let words = ["alpha", "bravo", "charlie", "delta", "écho", "foxtrot", "golf", "hôtel"]
        let hosts = (0..<5000).map { i in
            HostProfile(name: "\(words[i % 8])-\(words[(i / 8) % 8])-\(i)",
                        host: "srv\(i).\(words[i % 5]).example.com", user: i % 3 == 0 ? "admin" : nil,
                        tags: [words[i % 7], "env\(i % 4)"])
        }
        var best = Double.infinity
        var count = 0
        for q in ["alp", "srv42", "hotel", "xyz", "ab 12", "dlt"] {
            let t0 = ContinuousClock.now
            count += HostSearch.search(q, in: hosts).count
            let dt = ContinuousClock.now - t0
            let s = Double(dt.components.seconds) + Double(dt.components.attoseconds) / 1e18
            best = min(best, s)
            print("LIBRARY-PERF requête \(q): \(Int(s * 1000)) ms")
            #expect(s < 2.0)
        }
        #expect(count > 0)
    }
}
