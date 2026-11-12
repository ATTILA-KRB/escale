import Foundation
import Testing
@testable import EscaleCore

@Suite struct RecentSessionListTests {
    @Test func ordreEtUnicite() {
        var l = RecentSessionList()
        let a = UUID(), b = UUID()
        l.record(a, at: Date(timeIntervalSince1970: 10))
        l.record(b, at: Date(timeIntervalSince1970: 20))
        l.record(a, at: Date(timeIntervalSince1970: 30))
        #expect(l.entries.map(\.hostID) == [a, b])
        #expect(l.entries[0].date == Date(timeIntervalSince1970: 30))
    }

    @Test func borneEtNettoyage() {
        var l = RecentSessionList()
        let ids = (0..<20).map { _ in UUID() }
        for id in ids { l.record(id) }
        #expect(l.entries.count == l.limit)
        #expect(l.entries.first?.hostID == ids.last)
        let changed = l.prune(keeping: [ids[19], ids[18]])
        #expect(changed)
        #expect(l.entries.map(\.hostID) == [ids[19], ids[18]])
        let again = l.prune(keeping: [ids[19], ids[18]])
        #expect(!again)
    }

    @Test func allerRetourEtFichierIllisible() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("escale-recents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = RecentSessionList.url(besideLibrary: dir.appendingPathComponent("library.json"))
        #expect(url.lastPathComponent == "recents.json")
        #expect(RecentSessionList.load(from: url).entries.isEmpty)
        var l = RecentSessionList()
        let a = UUID()
        l.record(a, at: Date(timeIntervalSince1970: 1_700_000_000))
        try l.save(to: url)
        #expect(RecentSessionList.load(from: url) == l)
        try Data("{pas du json".utf8).write(to: url)
        #expect(RecentSessionList.load(from: url).entries.isEmpty)
        try Data(#"{"version":99,"entries":[]}"#.utf8).write(to: url)
        #expect(RecentSessionList.load(from: url).entries.isEmpty)
    }
}
