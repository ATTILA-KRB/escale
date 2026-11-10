import Foundation
import Testing
@testable import EscaleCore

/// Dossier temporaire unique, supprimé par l'appelant.
func libraryTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("escale-lib-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func librarySample() -> HostLibrary {
    let f = HostFolder(name: "Prod")
    return HostLibrary(folders: [f], hosts: [
        HostProfile(name: "web", host: "web.example.com", port: 2222, user: "deploy",
                    auth: .keyFile(path: "/k/id"), jumpHosts: ["bastion"], tags: ["prod"], folderID: f.id),
        HostProfile(name: "db", host: "10.0.0.5", auth: .keychainPassword(account: "db")),
        HostProfile(name: "alias", host: "alias"),
    ])
}

@Suite struct LibraryRepositoryTests {
    @Test func roundTrip() async throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = FileHostRepository(url: dir.appendingPathComponent("sub/deep/library.json"))
        #expect(try await repo.load() == HostLibrary())  // absent → vide
        let lib = librarySample()
        try await repo.save(lib)
        #expect(try await repo.load() == lib)
        // Une nouvelle instance relit la même chose.
        #expect(try await FileHostRepository(url: repo.url).load() == lib)
    }

    @Test func permissions0600() async throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = FileHostRepository(url: dir.appendingPathComponent("a/library.json"))
        try await repo.save(librarySample())
        try await repo.save(librarySample())
        let attrs = try FileManager.default.attributesOfItem(atPath: repo.url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func stableJSONAndVersion() async throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = FileHostRepository(url: dir.appendingPathComponent("library.json"))
        let lib = librarySample()
        try await repo.save(lib)
        let a = try Data(contentsOf: repo.url)
        try await repo.save(lib)
        #expect(a == (try Data(contentsOf: repo.url)))
        let text = String(decoding: a, as: UTF8.self)
        #expect(text.contains("\n"))
        #expect(text.contains("\"version\" : 1"))
        // Clés triées : "folders" avant "hosts" avant "version".
        let f = try #require(text.range(of: "\"folders\""))
        let h = try #require(text.range(of: "\"hosts\""))
        let v = try #require(text.range(of: "\"version\""))
        #expect(f.lowerBound < h.lowerBound && h.lowerBound < v.lowerBound)
    }

    @Test func corruptedFileIsPreservedThenSetAside() async throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        let garbage = Data("{ pas du json".utf8)
        try garbage.write(to: url)
        let repo = FileHostRepository(url: url)
        do { _ = try await repo.load(); Issue.record("aurait dû échouer") }
        catch let e as HostRepositoryError {
            guard case .corrupted = e else { Issue.record("mauvaise erreur \(e)"); return }
        }
        #expect(try Data(contentsOf: url) == garbage)  // load n'écrase rien

        let lib = librarySample()
        try await repo.save(lib)
        #expect(try await repo.load() == lib)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("library.json.corrupt-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside[0])) == garbage)
    }

    @Test func futureVersionIsRejectedAndPreserved() async throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        let future = Data(#"{"version": 99, "folders": [], "hosts": [], "nouveau": true}"#.utf8)
        try future.write(to: url)
        let repo = FileHostRepository(url: url)
        await #expect(throws: HostRepositoryError.unsupportedVersion(found: 99, supported: 1)) {
            _ = try await repo.load()
        }
        #expect(try Data(contentsOf: url) == future)
        try await repo.save(HostLibrary())
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside[0])) == future)
    }

    @Test func concurrentSaves() async throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = FileHostRepository(url: dir.appendingPathComponent("library.json"))
        let libs = (0..<40).map { i in
            HostLibrary(hosts: (0...i).map { HostProfile(name: "h\($0)", host: "h\($0).test") })
        }
        await withTaskGroup(of: Void.self) { group in
            for l in libs { group.addTask { try? await repo.save(l) } }
        }
        let loaded = try await repo.load()
        #expect(libs.contains(loaded))  // jamais un mélange
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["library.json"])  // ni temporaire ni mise de côté
    }
}
