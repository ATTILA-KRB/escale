import AppKit
import Foundation
import EscaleCore

/// `--selftest-sftp <dossier>` : navigateur SFTP, transferts, suivi OSC 7 et édition distante contre un sshd local.
/// Piloté par l'API interne (`SFTPFeature`, `SFTPHostSession`) ; sshd tourne sous le même utilisateur, donc
/// un chemin distant est aussi un chemin local : les résultats se vérifient directement sur le disque.
/// Écrit result.json + captures dans le dossier.
@MainActor
struct SFTPSelfTest {
    let directory: String
    let model: AppModel
    func run() async -> Bool { await SFTPSelfTestRunner(directory: directory, model: model).run() }
}

@MainActor
private final class SFTPSelfTestRunner {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var notes: [String: String] = [:]
    private var window: NSWindow?
    private let fm = FileManager.default
    /// Recette en mode shell : le sshd n'a pas de `Subsystem sftp` (ESCALE_SFTP_SHELL=1).
    private let shellMode = ProcessInfo.processInfo.environment["ESCALE_SFTP_SHELL"] == "1"

    init(directory: String, model: AppModel) {
        // Chemin canonique (/private/var…) : c'est celui que renvoie realpath côté serveur.
        if let r = realpath(directory, nil) { dir = String(cString: r); free(r) } else { dir = directory }
        self.model = model
    }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-sftp] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }

    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return cond()
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func read(_ path: String) -> String? { fm.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) } }
    private func type(_ t: TerminalTab, _ s: String) { t.session.engine.sendInput(Data(s.utf8)) }
    private func text(_ t: TerminalTab) -> String { t.session.engine.text(includingScrollback: true) }

    private var sshdLog: String {
        guard let p = ProcessInfo.processInfo.environment["ESCALE_SSHD_LOG"] else { return "" }
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }
    private var acceptedCount: Int { sshdLog.components(separatedBy: "Accepted publickey").count - 1 }

    private func capture(_ name: String) async {
        guard let win = window else { return }
        win.orderFrontRegardless()
        await sleep(0.6)
        model.workspace.activeTab?.session.engine.refreshDisplay()
        await sleep(0.3)
        let path = "\(dir)/\(name).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? p.run(); p.waitUntilExit()
        if fm.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    private func children() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, Int32(f[1]) == me else { return nil }
            let name = (String(f[2]) as NSString).lastPathComponent
            return name == "ps" ? nil : "\(f[0]) \(name)"
        }
    }

    private func randomFile(_ path: String, megabytes: Int) {
        var data = Data(count: megabytes * 1024 * 1024)
        data.withUnsafeMutableBytes { buf in
            var g = SystemRandomNumberGenerator()
            for i in stride(from: 0, to: buf.count, by: 8) { buf.storeBytes(of: g.next(), toByteOffset: i, as: UInt64.self) }
        }
        fm.createFile(atPath: path, contents: data)
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        window = win
        win.orderFrontRegardless()
        check("fenetre_principale", true)
        model.connections.graceDelay = 0.5
        model.connections.reconnectDelays = [1]
        let feature = model.sftp
        _ = await wait(10) { model.library.isLoaded }
        let hosts = model.library.library.hosts.sorted { $0.name < $1.name }
        guard let h1 = hosts.first, let h2 = hosts.last, h1.id != h2.id else { check("hotes_disponibles", false); return finish() }

        let work = "\(dir)/remote-work"
        let src = "\(dir)/local-src"
        let dl = "\(dir)/local-dl"
        for d in [work, src, dl] { try? fm.removeItem(atPath: d); try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        feature.cachesRoot = URL(fileURLWithPath: "\(dir)/caches")

        // 1. Connexion : onglet SSH + canal SFTP sur le même maître
        let tab = model.newTab(h1)
        let conn = model.connections.connection(for: h1)
        check("connexion_onglet_ssh", await wait(25) { tab.status == .running && conn.state == .connected }, "\(conn.state)")
        check("suivi_manquant_avant_injection", feature.trackingMissing)
        feature.isVisible = true
        feature.widenWindowIfNeeded()
        let s = feature.session(for: h1)
        await s.open()
        check("canal_sftp_ouvert", s.state == .ready, "\(s.state)")
        check(shellMode ? "mode_shell_actif" : "mode_sftp_actif", s.isShellMode == shellMode, "\(s.fsKind) \(s.shellReason ?? "")")
        if shellMode { check("mode_shell_raison_affichee", !(s.shellReason ?? "").isEmpty, s.shellReason ?? "nil") }
        let link = conn.links[0]
        check("un_seul_maitre", conn.links.count == 1 && s.link === link)
        // SFTP : une session de plus (le canal). Shell : les commandes exec sont éphémères, rien ne reste ouvert.
        let expectedSessions = shellMode ? 1 : 2
        check("sessionCount_shell_plus_sftp", await link.transport.sessionCount == expectedSessions, "\(await link.transport.sessionCount)")
        check("une_seule_authentification", acceptedCount == 1, "\(acceptedCount)")

        // 2. Liste du home
        s.showHidden = true
        let home = NSHomeDirectory()
        check("dossier_initial_est_le_home", s.pathString == home, "\(s.pathString) / \(home)")
        let remoteNames = Set(s.items.map(\.name))
        let localNames = Set((try? fm.contentsOfDirectory(atPath: home)) ?? [])
        let diff = remoteNames.symmetricDifference(localNames)
        check("liste_home_conforme", diff.count <= 2 && !remoteNames.isEmpty, "\(remoteNames.count) éléments, écart \(diff.sorted().prefix(5))")
        check("dossiers_avant_fichiers", {
            var seenFile = false
            for i in s.items { if !i.isDirectory { seenFile = true } else if seenFile { return false } }
            return true
        }())
        s.showHidden = false
        check("fichiers_caches_masques", s.visibleItems.allSatisfy { !$0.name.hasPrefix(".") })

        // 3. Navigation, nouveau dossier
        await s.navigate(to: work)
        check("navigation_chemin_absolu", s.pathString == work, s.pathString)
        await s.makeDirectory("Dossier test")
        var isDir: ObjCBool = false
        check("mkdir_present_sur_disque", fm.fileExists(atPath: "\(work)/Dossier test", isDirectory: &isDir) && isDir.boolValue)
        check("mkdir_dans_la_liste", s.items.contains { $0.name == "Dossier test" && $0.isDirectory })
        await s.makeDirectory("a/b")
        check("nom_invalide_refuse", s.errorMessage == "Nom invalide.")
        s.errorMessage = nil
        if let d = s.items.first(where: { $0.name == "Dossier test" }) { await s.open(d) }
        check("ouvrir_dossier", s.pathString == "\(work)/Dossier test", s.pathString)
        await s.goUp()
        check("dossier_parent", s.pathString == work)
        await s.goBack()
        check("precedent", s.pathString == "\(work)/Dossier test")
        await s.goForward()
        check("suivant", s.pathString == work)
        await s.navigate(to: "Dossier test")
        check("navigation_relative", s.pathString == "\(work)/Dossier test")
        await s.navigate(to: "/chemin/inexistant")
        check("navigation_invalide_erreur", s.errorMessage != nil && s.pathString == "\(work)/Dossier test", s.errorMessage ?? "nil")
        s.errorMessage = nil
        await capture("01-navigateur")

        // 4. Envoi : fichier 3 Mo, petit fichier, dossier
        randomFile("\(src)/gros.bin", megabytes: 3)
        try? "bonjour".write(toFile: "\(src)/petit.txt", atomically: true, encoding: .utf8)
        try? fm.createDirectory(atPath: "\(src)/arbre/sous", withIntermediateDirectories: true)
        try? "un".write(toFile: "\(src)/arbre/un.txt", atomically: true, encoding: .utf8)
        try? "deux".write(toFile: "\(src)/arbre/sous/deux.txt", atomically: true, encoding: .utf8)
        let ups = await s.upload([URL(fileURLWithPath: "\(src)/gros.bin"), URL(fileURLWithPath: "\(src)/petit.txt"),
                                  URL(fileURLWithPath: "\(src)/arbre")], policy: .replace)
        check("envoi_4_transferts_crees", ups.count == 4, "\(ups.count)")
        check("envoi_termine", await feature.transfers.waitIdle(timeout: 30))
        check("envoi_tous_reussis", ups.allSatisfy { $0.state == .done }, ups.map { "\($0.state)" }.joined(separator: ","))
        let dest = "\(work)/Dossier test"
        check("envoi_gros_identique", fm.contentsEqual(atPath: "\(src)/gros.bin", andPath: "\(dest)/gros.bin"))
        check("envoi_petit_identique", read("\(dest)/petit.txt") == "bonjour")
        check("envoi_arbre_identique", read("\(dest)/arbre/un.txt") == "un" && read("\(dest)/arbre/sous/deux.txt") == "deux")
        check("envoi_progression_complete", ups.first?.bytes == 3 * 1024 * 1024 && ups.first?.fraction == 1, "\(ups.first?.bytes ?? 0)")
        check("liste_rafraichie_apres_envoi", await wait(5) { s.items.contains { $0.name == "gros.bin" } && s.items.contains { $0.name == "arbre" } })
        // Remplacement : confirmation demandée en mode .ask
        var asked: [String] = []
        feature.confirmReplace = { names in asked = names; return false }
        let none = await s.upload([URL(fileURLWithPath: "\(src)/petit.txt")], policy: .ask)
        check("remplacement_demande_et_refuse", asked == ["petit.txt"] && none.isEmpty, "\(asked)")

        // 5. Téléchargement (fichier + dossier) et glisser vers le Finder (export)
        let gros = s.items.first { $0.name == "gros.bin" }, arbre = s.items.first { $0.name == "arbre" }
        let downs = await s.download([gros, arbre].compactMap { $0 }, to: URL(fileURLWithPath: dl))
        check("reception_3_transferts", downs.count == 3, "\(downs.count)")
        check("reception_terminee", await feature.transfers.waitIdle(timeout: 30) && downs.allSatisfy { $0.state == .done })
        check("reception_gros_identique", fm.contentsEqual(atPath: "\(src)/gros.bin", andPath: "\(dl)/gros.bin"))
        check("reception_arbre_identique", read("\(dl)/arbre/un.txt") == "un" && read("\(dl)/arbre/sous/deux.txt") == "deux")
        let again = await s.download([gros].compactMap { $0 }, to: URL(fileURLWithPath: dl))
        _ = await feature.transfers.waitIdle(timeout: 30)
        check("reception_collision_suffixe", again.first?.local.lastPathComponent == "gros 2.bin" && fm.fileExists(atPath: "\(dl)/gros 2.bin"))
        if let petit = s.items.first(where: { $0.name == "petit.txt" }) {
            let exported = try? await s.exportForDrag(petit)
            check("glisser_vers_finder_export", exported.map { read($0.path) == "bonjour" && $0.path.hasPrefix(dir) } == true, exported?.path ?? "échec")
        } else { check("glisser_vers_finder_export", false, "petit.txt absent") }

        // 6. File : borne de concurrence, annulation, nouvelle tentative
        let q = feature.transfers
        q.clearFinished()
        q.maxConcurrent = 2
        for i in 0..<6 { randomFile("\(src)/c\(i).bin", megabytes: 8) }
        let batch = await s.upload((0..<6).map { URL(fileURLWithPath: "\(src)/c\($0).bin") }, policy: .replace)
        var maxRunning = 0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 60, !batch.allSatisfy({ $0.isFinished }) {
            maxRunning = max(maxRunning, batch.filter { $0.state == .running }.count)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check("concurrence_bornee_a_2", maxRunning >= 1 && maxRunning <= 2 && batch.allSatisfy { $0.state == .done }, "max simultané \(maxRunning)")
        q.maxConcurrent = 1
        let big = await s.upload([URL(fileURLWithPath: "\(src)/c0.bin"), URL(fileURLWithPath: "\(src)/c1.bin")], policy: .replace)
        if big.count == 2 { q.cancel(big[1]) } // le second attend encore son tour
        check("annulation_transfert_en_attente", big.count == 2 && big[1].state == .cancelled, "\(big.last?.state as Any)")
        _ = await wait(30) { big[0].isFinished }
        q.retry(big[1])
        check("reessayer_apres_annulation", await wait(30) { big[1].state == .done }, "\(big[1].state)")
        // Échec puis réessai : le fichier distant n'existe pas encore
        let ghost = SFTPTransfer(direction: .download, name: "fantome.txt", local: URL(fileURLWithPath: "\(dl)/fantome.txt"),
                                 remote: Data("\(dest)/fantome.txt".utf8), session: s)
        q.enqueue(ghost)
        var ghostFailed = false
        _ = await wait(10) { if case .failed = ghost.state { ghostFailed = true }; return ghostFailed }
        check("echec_signale", ghostFailed, "\(ghost.state)")
        try? "boo".write(toFile: "\(dest)/fantome.txt", atomically: true, encoding: .utf8)
        q.retry(ghost)
        check("reessayer_apres_echec", await wait(10) { ghost.state == .done } && read("\(dl)/fantome.txt") == "boo", "\(ghost.state)")
        q.maxConcurrent = 3
        await capture("02-transferts")
        q.clearFinished()
        check("file_videe", q.items.isEmpty)

        // 7. Renommer, supprimer (fichier puis dossier non vide)
        if let it = s.items.first(where: { $0.name == "petit.txt" }) { await s.rename(it, to: "renomme.txt") }
        check("renommer_sur_disque", fm.fileExists(atPath: "\(dest)/renomme.txt") && !fm.fileExists(atPath: "\(dest)/petit.txt"))
        check("renommer_dans_la_liste", s.items.contains { $0.name == "renomme.txt" } && !s.items.contains { $0.name == "petit.txt" })
        if let it = s.items.first(where: { $0.name == "gros.bin" }) { await s.rename(it, to: "renomme.txt"); }
        check("renommer_vers_existant_refuse", s.errorMessage?.contains("existe déjà") == true && fm.fileExists(atPath: "\(dest)/gros.bin"))
        s.errorMessage = nil
        if let it = s.items.first(where: { $0.name == "renomme.txt" }) { await s.delete([it]) }
        check("supprimer_fichier", !fm.fileExists(atPath: "\(dest)/renomme.txt") && !s.items.contains { $0.name == "renomme.txt" })
        if let it = s.items.first(where: { $0.name == "arbre" }) { await s.delete([it]) }
        check("supprimer_dossier_non_vide", !fm.fileExists(atPath: "\(dest)/arbre") && !s.items.contains { $0.name == "arbre" })

        // 7b. Tri par colonne (persistant, dossiers d'abord)
        let defaults = UserDefaults.standard
        let savedKey = defaults.object(forKey: "escale.sftp.sortKey"), savedOrder = defaults.object(forKey: "escale.sftp.sortAscending")
        defer {
            defaults.set(savedKey, forKey: "escale.sftp.sortKey"); defaults.set(savedOrder, forKey: "escale.sftp.sortAscending")
        }
        let sortDir = "\(work)/tri"
        try? fm.createDirectory(atPath: "\(sortDir)/dir-b", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(sortDir)/dir-a", withIntermediateDirectories: true)
        for (n, size, age) in [("m.txt", 10, 300.0), ("z.txt", 5000, 100.0), ("a.txt", 300, 200.0)] {
            fm.createFile(atPath: "\(sortDir)/\(n)", contents: Data(count: size))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age * 1000)], ofItemAtPath: "\(sortDir)/\(n)")
        }
        await s.navigate(to: sortDir)
        func order() -> String { s.items.map(\.name).joined(separator: ",") }
        s.sort = SFTPSort(key: .name, ascending: true)
        check("tri_nom_croissant_dossiers_d_abord", order() == "dir-a,dir-b,a.txt,m.txt,z.txt", order())
        s.sort = SFTPSort(key: .name, ascending: false)
        check("tri_nom_decroissant_dossiers_d_abord", order() == "dir-b,dir-a,z.txt,m.txt,a.txt", order())
        s.sort = SFTPSort(key: .size, ascending: false)
        check("tri_taille_decroissante", order() == "dir-a,dir-b,z.txt,a.txt,m.txt", order())
        s.sort = SFTPSort(key: .size, ascending: true)
        check("tri_taille_croissante", order() == "dir-a,dir-b,m.txt,a.txt,z.txt", order())
        s.sort = SFTPSort(key: .date, ascending: false)
        check("tri_date_recent_d_abord", order() == "dir-a,dir-b,z.txt,a.txt,m.txt", order())
        s.sort = SFTPSort(key: .date, ascending: true)
        check("tri_date_ancien_d_abord", order() == "dir-a,dir-b,m.txt,a.txt,z.txt", order())
        check("tri_persistant", SFTPSort.stored == SFTPSort(key: .date, ascending: true))
        s.sort = SFTPSort(key: .size, ascending: false)
        await s.refresh()
        check("tri_conserve_apres_rafraichissement", order() == "dir-a,dir-b,z.txt,a.txt,m.txt", order())
        var toggled = SFTPSort(key: .name, ascending: true); toggled.toggle(.name)
        check("tri_clic_inverse_l_ordre", toggled == SFTPSort(key: .name, ascending: false))
        s.sort = SFTPSort(key: .name, ascending: true)

        // 7c. Glisser distant → distant : déplacer (rename) / copier, noms hostiles compris
        let mv = "\(work)/deplacer"
        let hostile = ["avec espace.txt", "it's.txt", "$(touch PWNED).txt", "`touch PWNED2`.txt", "a;b&c.txt"]
        try? fm.createDirectory(atPath: "\(mv)/cible", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(mv)/dossier/profond", withIntermediateDirectories: true)
        try? "profond".write(toFile: "\(mv)/dossier/profond/f.txt", atomically: true, encoding: .utf8)
        for n in hostile { try? "contenu-\(n)".write(toFile: "\(mv)/\(n)", atomically: true, encoding: .utf8) }
        await s.navigate(to: mv)
        let payload = SFTPDragPayload.encode(session: s.id, paths: s.items.map(\.path))
        check("glisser_charge_aller_retour", SFTPDragPayload.decode(payload)?.session == s.id && SFTPDragPayload.decode(payload)?.paths == s.items.map(\.path))
        check("glisser_charge_etrangere_ignoree", SFTPDragPayload.decode("texte quelconque") == nil)
        s.errorMessage = nil
        let toMove = s.items.filter { hostile.contains($0.name) }
        check("deplacer_liste_hostile_complete", toMove.count == hostile.count, "\(toMove.count)")
        let moved = await s.move(toMove, into: Data("\(mv)/cible".utf8), copy: false)
        check("deplacer_nombre", moved == hostile.count && s.errorMessage == nil, "\(moved) \(s.errorMessage ?? "")")
        check("deplacer_present_a_destination", hostile.allSatisfy { read("\(mv)/cible/\($0)") == "contenu-\($0)" })
        check("deplacer_absent_de_la_source", hostile.allSatisfy { !fm.fileExists(atPath: "\(mv)/\($0)") })
        check("deplacer_aucune_injection", ![NSHomeDirectory(), "/", work, mv].contains { fm.fileExists(atPath: "\($0)/PWNED") || fm.fileExists(atPath: "\($0)/PWNED2") })
        check("deplacer_liste_rafraichie", !s.items.contains { hostile.contains($0.name) })
        // Copier (⌥) : la source reste, un dossier est copié en entier
        if let d = s.items.first(where: { $0.name == "dossier" }) {
            let copied = await s.move([d], into: Data("\(mv)/cible".utf8), copy: true)
            check("copier_dossier", copied == 1 && read("\(mv)/cible/dossier/profond/f.txt") == "profond" && read("\(mv)/dossier/profond/f.txt") == "profond", s.errorMessage ?? "")
            let again = await s.move([d], into: Data("\(mv)/cible".utf8), copy: true)
            check("copier_refuse_ecrasement", again == 0 && s.errorMessage?.contains("existe déjà") == true, s.errorMessage ?? "nil")
            s.errorMessage = nil
            let inside = await s.move([d], into: Data("\(mv)/dossier/profond".utf8), copy: false)
            check("deplacer_dans_soi_meme_refuse", inside == 0 && s.errorMessage != nil && fm.fileExists(atPath: "\(mv)/dossier"), s.errorMessage ?? "nil")
            s.errorMessage = nil
        } else { check("copier_dossier", false, "dossier absent") }
        if let d = s.items.first(where: { $0.name == "dossier" }) {
            _ = await s.move([d], into: Data("\(mv)/cible/dossier".utf8), copy: false)
            check("deplacer_dossier_dans_dossier", fm.fileExists(atPath: "\(mv)/cible/dossier/dossier/profond/f.txt") && !fm.fileExists(atPath: "\(mv)/dossier"), s.errorMessage ?? "")
            s.errorMessage = nil
        }

        // 7d. Reprise dans l'UI : « Réessayer » reprend (vérifié) au lieu de repartir de zéro
        let resumeRemote = "\(work)/reprise-dl.bin", resumeLocal = "\(dl)/reprise-dl.bin"
        let rt = SFTPTransfer(direction: .download, name: "reprise-dl.bin", local: URL(fileURLWithPath: resumeLocal),
                              remote: Data(resumeRemote.utf8), session: s)
        q.enqueue(rt)
        var rtFailed = false
        _ = await wait(10) { if case .failed = rt.state { rtFailed = true }; return rtFailed }
        check("reprise_dl_premier_essai_echoue", rtFailed, "\(rt.state)")
        randomFile(resumeRemote, megabytes: 6)
        if let full = fm.contents(atPath: resumeRemote) { fm.createFile(atPath: resumeLocal, contents: full.prefix(2_500_000)) }
        q.retry(rt)
        check("reprise_dl_terminee", await wait(30) { rt.state == .done }, "\(rt.state)")
        check("reprise_dl_contenu_identique", fm.contentsEqual(atPath: resumeRemote, andPath: resumeLocal))
        check("reprise_dl_repris_a_un_pourcentage", rt.resumedFrom > 0 && rt.resumedFrom <= 2_500_000 && rt.resumeText?.hasPrefix("repris à ") == true && rt.resumeText?.hasSuffix(" %") == true,
              "\(rt.resumedFrom) \(rt.resumeText ?? "nil")")
        // Début local différent : pas de reprise, on repart de zéro et le fichier est correct
        try? fm.removeItem(atPath: resumeLocal)
        if var full = fm.contents(atPath: resumeRemote) {
            full[1000] ^= 0xFF
            fm.createFile(atPath: resumeLocal, contents: full.prefix(2_000_000))
        }
        let rt2 = SFTPTransfer(direction: .download, name: "reprise-dl.bin", local: URL(fileURLWithPath: resumeLocal),
                               remote: Data(resumeRemote.utf8), session: s)
        q.enqueue(rt2)
        _ = await wait(30) { rt2.isFinished }
        q.retry(rt2)
        check("reprise_dl_debut_different_repart_de_zero", await wait(30) { rt2.state == .done && rt2.resumedFrom == 0 && fm.contentsEqual(atPath: resumeRemote, andPath: resumeLocal) },
              "\(rt2.state) \(rt2.resumedFrom)")
        // Envoi : un fichier distant partiel (SFTP) ou `.part` (shell) est prolongé
        randomFile("\(src)/reprise-up.bin", megabytes: 6)
        let upDir = "\(work)/reprise-up", upRemote = "\(work)/reprise-up/reprise-up.bin"
        let ut = SFTPTransfer(direction: .upload, name: "reprise-up.bin", local: URL(fileURLWithPath: "\(src)/reprise-up.bin"),
                              remote: Data(upRemote.utf8), session: s)
        q.enqueue(ut) // le dossier distant n'existe pas encore : premier essai en échec
        var utFailed = false
        _ = await wait(15) { if case .failed = ut.state { utFailed = true }; return utFailed }
        check("reprise_up_premier_essai_echoue", utFailed, "\(ut.state)")
        try? fm.createDirectory(atPath: upDir, withIntermediateDirectories: true)
        if let full = fm.contents(atPath: "\(src)/reprise-up.bin") {
            fm.createFile(atPath: shellMode ? upRemote + ".part" : upRemote, contents: full.prefix(2_000_000))
        }
        q.retry(ut)
        check("reprise_up_terminee", await wait(30) { ut.state == .done }, "\(ut.state)")
        check("reprise_up_contenu_identique", fm.contentsEqual(atPath: "\(src)/reprise-up.bin", andPath: upRemote))
        check("reprise_up_repris_a_un_pourcentage", ut.resumedFrom > 0 && ut.resumeText?.hasPrefix("repris à ") == true, "\(ut.resumedFrom) \(ut.resumeText ?? "nil")")
        q.clearFinished()
        await s.navigate(to: work)

        // 8. Suivi du dossier du terminal (OSC 7)
        model.workspace.select(tab.id)
        try? fm.createDirectory(atPath: "\(work)/avec espace", withIntermediateDirectories: true)
        check("suivi_actif_par_defaut", feature.followTerminal)
        feature.injectTracking(in: tab.activePane)
        check("osc7_recu_apres_injection", await wait(15) { tab.session.workingDirectory != nil }, tab.session.workingDirectory?.absoluteString ?? "nil")
        check("suivi_manquant_apres_injection", !feature.trackingMissing)
        type(tab, "cd /tmp\r")
        let isTmp: (String?) -> Bool = { $0 == "/tmp" || $0 == "/private/tmp" }
        check("suivi_cd_tmp_terminal", await wait(15) { isTmp(tab.session.workingDirectory?.path) }, tab.session.workingDirectory?.absoluteString ?? "nil")
        check("suivi_navigateur_sur_tmp", await wait(15) { isTmp(s.pathString) }, s.pathString)
        type(tab, "cd '\(work)/avec espace'\r")
        check("suivi_chemin_avec_espace", await wait(15) { s.pathString == "\(work)/avec espace" }, s.pathString)
        feature.followTerminal = false
        await sleep(0.3)
        type(tab, "cd /tmp\r")
        _ = await wait(15) { isTmp(tab.session.workingDirectory?.path) }
        await sleep(1.0)
        check("suivi_desactive_navigateur_inchange", s.pathString == "\(work)/avec espace", s.pathString)
        feature.followTerminal = true
        type(tab, "cd '\(work)'\r")
        check("suivi_reactive", await wait(15) { s.pathString == work }, s.pathString)
        await capture("03-suivi-terminal")

        // 9. Édition distante aller-retour
        let editPath = "\(work)/edit.txt"
        try? "v1".write(toFile: editPath, atomically: true, encoding: .utf8)
        await s.refresh()
        var opened: [URL] = []
        feature.edits.opener = { opened.append($0) }
        feature.edits.debounceDelay = 0.2
        feature.edits.pollInterval = 0.3
        var conflicts = 0
        var answer: SFTPConflictChoice = .keepRemote
        feature.edits.resolveConflict = { _ in conflicts += 1; return answer }
        guard let item = s.items.first(where: { $0.name == "edit.txt" }) else { check("edit_fichier_listé", false); return finish() }
        let edit = try? await feature.edits.edit(item, in: s)
        check("edit_telecharge_dans_cache_app", edit.map { $0.localURL.path.hasPrefix("\(dir)/caches/edit/") && read($0.localURL.path) == "v1" } == true,
              edit?.localURL.path ?? "échec")
        check("edit_jamais_dans_ssh", edit.map { !$0.localURL.path.contains("/.ssh") } == true)
        check("edit_ouvert_dans_editeur", opened.count == 1 && opened.first == edit?.localURL)
        guard let e = edit else { return finish() }
        await sleep(0.8)
        check("edit_sans_modification_pas_d_envoi", e.uploads == 0 && read(editPath) == "v1")
        try? "v2 écrit en place".write(to: e.localURL, atomically: false, encoding: .utf8)
        check("edit_sauvegarde_en_place_renvoyee", await wait(10) { read(editPath) == "v2 écrit en place" && e.uploads == 1 }, "\(read(editPath) ?? "nil") / \(e.uploads) / \(e.state)")
        try? "v3 remplacement atomique".write(to: e.localURL, atomically: true, encoding: .utf8)
        check("edit_sauvegarde_atomique_renvoyee", await wait(10) { read(editPath) == "v3 remplacement atomique" && e.uploads == 2 }, "\(read(editPath) ?? "nil") / \(e.uploads) / \(e.state)")
        check("edit_aucun_conflit_a_ce_stade", conflicts == 0)
        // Conflit : le distant change entre-temps (autre utilisateur), l'utilisateur garde le distant
        try? "modifié ailleurs".write(toFile: editPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: editPath)
        try? "v4 local".write(to: e.localURL, atomically: false, encoding: .utf8)
        check("edit_conflit_detecte", await wait(10) { conflicts == 1 && e.state == .conflict }, "conflits \(conflicts), état \(e.state)")
        check("edit_conflit_distant_conserve", read(editPath) == "modifié ailleurs")
        feature.edits.resend(e)
        check("edit_renvoi_force_apres_conflit", await wait(10) { read(editPath) == "v4 local" && e.state == .watching }, "\(read(editPath) ?? "nil") / \(e.state)")
        // Conflit résolu par écrasement
        answer = .overwrite
        try? "modifié encore".write(toFile: editPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: editPath)
        try? "v5 local".write(to: e.localURL, atomically: false, encoding: .utf8)
        check("edit_conflit_ecrasement", await wait(10) { conflicts == 2 && read(editPath) == "v5 local" && e.state == .watching }, "conflits \(conflicts), \(read(editPath) ?? "nil"), \(e.state)")
        await capture("04-edition")
        let editDir = e.localURL.deletingLastPathComponent().path
        feature.edits.stop(e)
        check("edit_termine_nettoie_le_temporaire", !fm.fileExists(atPath: editDir) && feature.edits.edits.isEmpty)

        // 10. Menu « Parcourir » : hôte sans onglet → onglet + canal
        await feature.browse(h2)
        let s2 = feature.session(for: h2)
        check("parcourir_ouvre_onglet_et_canal", model.workspace.tabs(forHost: h2.id).count == 1 && s2.state == .ready, "\(s2.state)")
        check("parcourir_hote_courant", feature.currentSession() === s2)
        model.workspace.select(tab.id)
        check("hote_courant_suit_onglet_actif", feature.currentSession() === s)

        // 11. Perte du maître : le navigateur se rouvre seul, et le transfert coupé reprend tout seul
        let opened1 = s.channelsOpened
        let bigPath = "\(src)/coupure.bin"
        fm.createFile(atPath: bigPath, contents: nil)
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: bigPath)) {
            var chunk = Data(count: 1 << 20)
            chunk.withUnsafeMutableBytes { b in var g = SystemRandomNumberGenerator(); for i in stride(from: 0, to: b.count, by: 8) { b.storeBytes(of: g.next(), toByteOffset: i, as: UInt64.self) } }
            for _ in 0..<(shellMode ? 120 : 400) { try? h.write(contentsOf: chunk) }
            try? h.close()
        }
        q.maxConcurrent = 3
        let cut = SFTPTransfer(direction: .upload, name: "coupure.bin", local: URL(fileURLWithPath: bigPath),
                               remote: Data("\(work)/coupure.bin".utf8), session: s)
        q.enqueue(cut)
        check("coupure_transfert_demarre", await wait(20) { cut.state == .running && cut.bytes > 4_000_000 }, "\(cut.state) \(cut.bytes)")
        let pid = await link.transport.masterProcessIdentifier
        if let pid { kill(pid, SIGKILL) }
        check("coupure_transfert_interrompu", await wait(30) { if case .failed = cut.state { return true }; return cut.state == .running && cut.resumedFrom > 0 }, "\(cut.state)")
        check("perte_detectee_par_navigateur", await wait(20) { s.state == .lost || s.state != .ready }, "\(s.state)")
        check("navigateur_rouvert_apres_reconnexion", await wait(60) { s.state == .ready && s.channelsOpened == opened1 + 1 }, "\(s.state), canaux \(s.channelsOpened - opened1)")
        check("coupure_reprise_automatique", await wait(120) { cut.state == .done }, "\(cut.state) \(cut.bytes)")
        check("coupure_contenu_identique", fm.contentsEqual(atPath: bigPath, andPath: "\(work)/coupure.bin"))
        check("coupure_repris_a_un_pourcentage", cut.resumedFrom > 0 && cut.resumeText?.hasPrefix("repris à ") == true && cut.autoResumeCount >= 1,
              "\(cut.resumedFrom) \(cut.resumeText ?? "nil") auto=\(cut.autoResumeCount)")
        check("liste_apres_reconnexion", s.pathString == work && s.items.contains { $0.name == "edit.txt" }, s.pathString)
        check("reconnexion_une_authentification_de_plus", acceptedCount == 3, "\(acceptedCount)") // h1, h2, h1 reconnecté
        await capture("05-apres-reconnexion")

        // 12. Fermeture : plus de canal, plus de ssh
        for t in model.workspace.tabs { model.close(t) }
        await feature.shutdown()
        check("tous_onglets_fermes", model.workspace.tabs.isEmpty)
        check("tous_les_maitres_deconnectes", await wait(20) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } },
              model.connections.allLinks.map { "\($0.state)" }.joined(separator: ","))
        var sc: [Int] = []
        for l in model.connections.allLinks { sc.append(await l.transport.sessionCount) }
        check("sessionCount_zero_partout", sc.allSatisfy { $0 == 0 }, "\(sc)")
        var kids: [String] = []
        _ = await wait(10) { kids = children(); return kids.isEmpty }
        check("aucun_processus_enfant_residuel", kids.isEmpty, kids.joined(separator: ", "))
        return finish()
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }),
            "details": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.2) }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "screenshots": shots,
            "notes": notes,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
