import Foundation
import Testing
@testable import EscaleCore

@Suite struct LibraryOperationsTests {
    @Test func hostCRUD() throws {
        var lib = HostLibrary()
        let folder = try lib.addFolder(name: "F")
        var h = HostProfile(name: "a", host: "a.test", folderID: folder.id)
        try lib.addHost(h)
        #expect(throws: HostLibraryError.duplicateID(h.id)) { try lib.addHost(h) }
        #expect(throws: HostLibraryError.unknownFolder(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try lib.addHost(HostProfile(name: "x", host: "x", folderID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        }
        h.name = "renamed"
        try lib.updateHost(h)
        #expect(lib.hosts.first?.name == "renamed")
        #expect(throws: HostLibraryError.self) { try lib.updateHost(HostProfile(name: "z", host: "z")) }
        try lib.moveHost(id: h.id, to: nil)
        #expect(lib.hosts[0].folderID == nil)
        try lib.moveHost(id: h.id, to: folder.id)
        #expect(lib.hosts[0].folderID == folder.id)
        try lib.removeHost(id: h.id)
        #expect(lib.hosts.isEmpty)
        #expect(throws: HostLibraryError.unknownHost(h.id)) { try lib.removeHost(id: h.id) }
    }

    @Test func folderRenameAndRemovePromotesContent() throws {
        var lib = HostLibrary()
        let a = try lib.addFolder(name: "A")
        let b = try lib.addFolder(name: "B", parentID: a.id)
        let c = try lib.addFolder(name: "C", parentID: b.id)
        let h1 = HostProfile(name: "h1", host: "h1", folderID: b.id)
        let h2 = HostProfile(name: "h2", host: "h2", folderID: c.id)
        try lib.addHost(h1); try lib.addHost(h2)
        try lib.renameFolder(id: b.id, to: "Bravo")
        #expect(lib.folders.first { $0.id == b.id }?.name == "Bravo")

        try lib.removeFolder(id: b.id)
        #expect(!lib.folders.contains { $0.id == b.id })
        #expect(lib.folders.first { $0.id == c.id }?.parentID == a.id)  // C remonte sous A
        #expect(lib.hosts.first { $0.id == h1.id }?.folderID == a.id)   // h1 remonte sous A
        #expect(lib.hosts.count == 2)                                   // aucun hôte supprimé

        try lib.removeFolder(id: a.id)  // dossier racine : le contenu passe à la racine
        #expect(lib.folders.first?.parentID == nil)
        #expect(lib.hosts.first { $0.id == h1.id }?.folderID == nil)
        #expect(lib.hosts.first { $0.id == h2.id }?.folderID == c.id)
        #expect(throws: HostLibraryError.unknownFolder(a.id)) { try lib.removeFolder(id: a.id) }
    }

    @Test func moveFolderRejectsCycles() throws {
        var lib = HostLibrary()
        let a = try lib.addFolder(name: "A")
        let b = try lib.addFolder(name: "B", parentID: a.id)
        let c = try lib.addFolder(name: "C", parentID: b.id)
        #expect(throws: HostLibraryError.cycle) { try lib.moveFolder(id: a.id, to: a.id) }
        #expect(throws: HostLibraryError.cycle) { try lib.moveFolder(id: a.id, to: c.id) }
        #expect(throws: HostLibraryError.cycle) { try lib.moveFolder(id: b.id, to: c.id) }
        #expect(lib.folders.first { $0.id == a.id }?.parentID == nil)  // inchangé
        try lib.moveFolder(id: c.id, to: a.id)
        #expect(lib.folders.first { $0.id == c.id }?.parentID == a.id)
        try lib.moveFolder(id: c.id, to: nil)
        #expect(lib.folders.first { $0.id == c.id }?.parentID == nil)
        #expect(throws: HostLibraryError.self) { try lib.moveFolder(id: c.id, to: UUID()) }
    }

    @Test func childrenSortedLocalizedCaseInsensitive() throws {
        var lib = HostLibrary()
        let root = try lib.addFolder(name: "root")
        for n in ["banane", "Zèbre", "apple", "Éclair", "cerise"] { try lib.addFolder(name: n, parentID: root.id) }
        for n in ["b", "A", "c"] { try lib.addHost(HostProfile(name: n, host: n, folderID: root.id)) }
        #expect(lib.childFolders(of: root.id).map(\.name) == ["apple", "banane", "cerise", "Éclair", "Zèbre"])
        #expect(lib.hosts(in: root.id).map(\.name) == ["A", "b", "c"])
        #expect(lib.childFolders(of: nil).map(\.name) == ["root"])
    }

    @Test func folderPath() throws {
        var lib = HostLibrary()
        let a = try lib.addFolder(name: "A")
        let b = try lib.addFolder(name: "B", parentID: a.id)
        let c = try lib.addFolder(name: "C", parentID: b.id)
        #expect(lib.folderPath(of: c.id).map(\.name) == ["A", "B", "C"])
        #expect(lib.folderPath(of: a.id).map(\.name) == ["A"])
        #expect(lib.folderPath(of: UUID()).isEmpty)
        // Fichier corrompu avec cycle : ne boucle pas.
        lib.folders[0].parentID = c.id
        #expect(lib.folderPath(of: c.id).count == 3)
    }
}
