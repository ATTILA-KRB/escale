import AppKit
import Foundation
import EscaleCore

/// Scénario automatique `--selftest-ssh <dossier>` : fenêtre principale contre un sshd local.
/// Piloté uniquement par l'API interne du modèle (`newTab`, `close`, `sendInput`…) : aucun événement
/// clavier ou souris global, pas d'activation de l'app. Écrit result.json + PNG dans le dossier.
/// Variable d'environnement `ESCALE_SSHD_LOG` : journal du sshd (comptage des authentifications).
@MainActor
final class SSHSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var notes: [String: String] = [:]
    private var window: NSWindow?

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-ssh] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }

    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    private func text(_ t: TerminalTab) -> String { t.session.engine.text(includingScrollback: true) }
    private func type(_ t: TerminalTab, _ s: String) { t.session.engine.sendInput(Data(s.utf8)) }
    private func waitText(_ t: TerminalTab, _ s: String, _ timeout: Double = 15) async -> Bool {
        await wait(timeout) { text(t).contains(s) }
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private var sshdLog: String {
        guard let p = ProcessInfo.processInfo.environment["ESCALE_SSHD_LOG"] else { return "" }
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }
    private var acceptedCount: Int { sshdLog.components(separatedBy: "Accepted publickey").count - 1 }

    private func capture(windowNumber: Int, name: String) {
        let path = "\(dir)/\(name).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(windowNumber)", path]
        try? p.run(); p.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    private func screenshot(_ name: String) async {
        guard let win = window else { return }
        win.orderFrontRegardless()
        await sleep(0.5)
        model.workspace.activeTab?.session.engine.refreshDisplay()
        await sleep(0.25)
        capture(windowNumber: win.windowNumber, name: name)
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

    private func tableRowCount(in view: NSView) -> Int? {
        if let t = view as? NSTableView { return t.numberOfRows }
        for s in view.subviews { if let n = tableRowCount(in: s) { return n } }
        return nil
    }

    private func wipeAndStrip(_ s: String) -> String { String(s.suffix(1200)) }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        window = win
        win.orderFrontRegardless() // visible sans activer l'app ni voler le focus clavier
        check("fenetre_principale", true)
        model.connections.graceDelay = 0.5

        // 1. Bibliothèque chargée et affichée
        _ = await wait(10) { model.library.isLoaded }
        let lib = model.library.library
        check("bibliotheque_chargee", lib.hosts.count == 2 && lib.folders.count == 1, "\(lib.folders.count) dossier(s), \(lib.hosts.count) hôte(s)")
        let tree = model.library.tree
        check("arborescence_dossier_avec_2_hotes", tree.count == 1 && tree.first?.children.count == 2)
        await sleep(0.6)
        let rows = win.contentView.flatMap { tableRowCount(in: $0) }
        check("barre_laterale_affichee", (rows ?? 0) >= 4, "lignes de la liste : \(rows.map(String.init) ?? "liste introuvable")")
        check("etat_vide_sans_onglet", model.workspace.tabs.isEmpty)
        await screenshot("01-barre-laterale")

        guard let h1 = lib.hosts.sorted(by: { $0.name < $1.name }).first, let h2 = lib.hosts.sorted(by: { $0.name < $1.name }).last, h1.id != h2.id else {
            check("hotes_disponibles", false); return finish()
        }

        // 2. Connexion à l'hôte 1 : onglet avec shell distant
        let a = model.newTab(h1)
        let conn1 = model.connections.connection(for: h1)
        check("connexion_hote1_etat_connecte", await wait(25) { a.status == .running && conn1.state == .connected }, "\(conn1.state)")
        check("sidebar_etat_hote1_connecte", model.connections.state(of: h1.id) == .connected)
        type(a, "echo REMOTE-$((41+1))-${SSH_CONNECTION%% *}\r")
        check("shell_distant_onglet_a", await waitText(a, "REMOTE-42-127.0.0.1"), wipeAndStrip(text(a)))

        // 3. Second onglet sur le même hôte : même maître, une seule authentification
        let b = model.newTab(h1)
        check("second_onglet_running", await wait(20) { b.status == .running })
        type(b, "echo SECOND-$((50+8))-${SSH_CONNECTION%% *}\r")
        check("shell_distant_onglet_b", await waitText(b, "SECOND-58-127.0.0.1"), wipeAndStrip(text(b)))
        let link1 = conn1.links[0]
        check("un_seul_maitre_pour_2_onglets", conn1.links.count == 1 && a.link === b.link)
        check("sessionCount_2", await link1.transport.sessionCount == 2, "\(await link1.transport.sessionCount)")
        check("une_seule_authentification_sshd", acceptedCount == 1, "authentifications acceptées : \(acceptedCount)")
        check("un_seul_connect", link1.connectAttempts == 1, "\(link1.connectAttempts)")

        // 4. Onglet local
        let c = model.openLocalTab(command: ["/bin/zsh", "-f", "-i"])
        check("onglet_local_running", await wait(10) { c.status == .running })
        type(c, "echo LOCAL-$((6*7))-END\r")
        check("shell_local", await waitText(c, "LOCAL-42-END"))
        check("trois_onglets", model.workspace.tabs.count == 3 && model.workspace.activeID == c.id)

        // 5. Changement d'onglet : contenu conservé, vue visible, focus, titre de fenêtre
        let engineBefore = ObjectIdentifier(a.session.engine)
        model.workspace.select(a.id)
        await sleep(0.5)
        check("onglet_a_contenu_conserve", text(a).contains("REMOTE-42-127.0.0.1") && !text(a).contains("LOCAL-42-END"))
        check("onglet_a_visible_autres_masques", !a.session.engine.view.isHidden && b.session.engine.view.isHidden && c.session.engine.view.isHidden)
        check("focus_clavier_sur_onglet_actif", await wait(3) { a.session.engine.hasKeyboardFocus })
        check("titre_fenetre_egal_titre_onglet", await wait(3) { win.title == a.displayTitle }, "fenêtre « \(win.title) » / onglet « \(a.displayTitle) »")
        model.workspace.select(b.id)
        await sleep(0.4)
        check("onglet_b_contenu_conserve", text(b).contains("SECOND-58-127.0.0.1") && !text(b).contains("REMOTE-42-127.0.0.1"))
        check("focus_suit_le_changement", await wait(3) { b.session.engine.hasKeyboardFocus && !a.session.engine.hasKeyboardFocus })
        model.workspace.select(c.id)
        await sleep(0.3)
        check("onglet_local_contenu_conserve", text(c).contains("LOCAL-42-END"))
        model.workspace.selectNext() // c → a (circulaire)
        check("navigation_suivant_circulaire", model.workspace.activeID == a.id)
        model.workspace.selectPrevious()
        check("navigation_precedent", model.workspace.activeID == c.id)
        model.workspace.select(index: 1)
        check("navigation_par_index", model.workspace.activeID == b.id)
        check("moteur_non_recree", ObjectIdentifier(a.session.engine) == engineBefore)

        // 6. stty size cohérent avec le moteur
        model.workspace.select(a.id)
        await sleep(0.4)
        let eng = a.session.engine.size
        type(a, "echo ST $(stty size) E\r")
        _ = await waitText(a, "ST \(eng.rows) \(eng.columns) E", 8)
        var reported = "?"
        if let r = text(a).range(of: #"ST \d+ \d+ E"#, options: .regularExpression) { reported = String(text(a)[r]) }
        check("stty_size_coherent_ssh", reported == "ST \(eng.rows) \(eng.columns) E", "stty : \(reported) ; moteur : \(eng.rows) \(eng.columns)")
        await screenshot("02-trois-onglets")

        // 7. Réordonnancement (API de l'espace de travail)
        model.workspace.move(c.id, before: a.id)
        check("reordonner_onglets", model.workspace.tabs.map(\.id) == [c.id, a.id, b.id])
        model.workspace.move(c.id, before: nil)
        check("reordonner_a_la_fin", model.workspace.tabs.map(\.id) == [a.id, b.id, c.id])

        // 8. `exit` volontaire : aucune reconnexion
        let d = model.newTab(h1)
        check("onglet_d_running", await wait(20) { d.status == .running })
        type(d, "exit 3\r")
        check("exit_volontaire_session_terminee_code_3", await wait(10) { d.status == .ended(.exited(3)) }, "\(d.status)")
        let epochBefore = link1.epoch
        await sleep(2.5)
        check("exit_volontaire_pas_de_reconnexion", d.status == .ended(.exited(3)) && link1.state == .connected && link1.epoch == epochBefore,
              "état \(d.status), lien \(link1.state), époque \(link1.epoch)")
        check("exit_volontaire_bandeau", d.bannerMessage == "Session terminée (code 3)", d.bannerMessage ?? "nil")
        model.close(d)
        _ = await wait(5) { d.session.state != .running }
        await sleep(0.5)
        let sc2 = await link1.transport.sessionCount
        check("sessionCount_revient_a_2", sc2 == 2, "\(sc2)")

        // 9. Coupure simulée du maître
        for t in [a, b] { type(t, "echo BEFORE-CUT-$((7*6))\r") }
        let markA = await waitText(a, "BEFORE-CUT-42"), markB = await waitText(b, "BEFORE-CUT-42")
        check("marqueurs_avant_coupure", markA && markB)
        model.connections.reconnectDelays = [4]
        let acceptedBefore = acceptedCount
        let attemptsBefore = link1.connectAttempts
        let pid = await link1.transport.masterProcessIdentifier
        check("pid_maitre_expose", pid != nil, "\(pid.map(String.init) ?? "nil")")
        if let pid { kill(pid, SIGKILL) }
        check("coupure_detectee_deux_onglets", await wait(15) { a.status == .reconnecting && b.status == .reconnecting }, "a=\(a.status) b=\(b.status)")
        model.workspace.select(a.id)
        check("bandeau_decompte_visible", await wait(10) {
            if case .reconnecting(_, let s?) = link1.state, a.bannerMessage?.contains("nouvelle tentative dans") == true { return s > 0 }
            return false
        }, a.bannerMessage ?? "nil")
        notes["bandeau"] = a.bannerMessage ?? ""
        check("sidebar_etat_reconnexion", { if case .reconnecting = model.connections.state(of: h1.id) { true } else { false } }())
        check("ecran_conserve_pendant_coupure", text(a).contains("BEFORE-CUT-42") && text(a).contains("REMOTE-42-127.0.0.1"))
        await screenshot("03-bandeau-reconnexion")
        check("reconnexion_automatique", await wait(40) { link1.state == .connected && a.status == .running && b.status == .running }, "lien \(link1.state), a=\(a.status), b=\(b.status)")
        check("reconnexion_un_seul_connect", link1.connectAttempts - attemptsBefore == 1, "\(link1.connectAttempts - attemptsBefore) tentative(s)")
        check("reconnexion_une_authentification", acceptedCount - acceptedBefore == 1, "authentifications supplémentaires : \(acceptedCount - acceptedBefore)")
        for t in [a, b] { type(t, "echo AFTER-$((9*9))-${SSH_CONNECTION%% *}\r") }
        for (n, t) in [("a", a), ("b", b)] {
            check("onglet_\(n)_nouveau_shell_fonctionnel", await waitText(t, "AFTER-81-127.0.0.1"))
            let s = text(t)
            let i = s.range(of: "BEFORE-CUT-42")?.lowerBound, j = s.range(of: "Connexion rétablie le")?.lowerBound, k = s.range(of: "AFTER-81-127.0.0.1")?.lowerBound
            check("onglet_\(n)_ecran_avant_separateur_apres", i != nil && j != nil && k != nil && i! < j! && j! < k!, "\(wipeAndStrip(s).suffix(500))")
        }
        check("reconnexion_bandeau_disparu", a.bannerMessage == nil && b.bannerMessage == nil)
        await screenshot("04-apres-reconnexion")

        // 10. Bibliothèque : ajout puis suppression d'hôte, fichier mis à jour
        let tmp = HostProfile(name: "Temporaire", host: "127.0.0.1", port: 2200, user: "x", tags: ["tmp"])
        model.library.upsert(tmp)
        await model.library.flush()
        let onDisk1 = readLibraryFile()
        check("ajout_hote_ecrit_sur_disque", onDisk1?.hosts.contains { $0.id == tmp.id } == true, "\(onDisk1?.hosts.count ?? -1) hôtes dans le fichier")
        let found = model.library.search("TEMPOR")
        check("recherche_insensible_casse", found.map(\.id) == [tmp.id])
        model.deleteHost(tmp)
        await model.library.flush()
        let onDisk2 = readLibraryFile()
        check("suppression_hote_ecrite_sur_disque", onDisk2?.hosts.contains { $0.id == tmp.id } == false && onDisk2?.hosts.count == 2, "\(onDisk2?.hosts.count ?? -1) hôtes dans le fichier")

        // 11. Feuille d'édition (ouverte par le modèle, sans interaction)
        model.editor = .editHost(h1)
        await sleep(1.2)
        if let sheet = win.attachedSheet {
            capture(windowNumber: sheet.windowNumber, name: "05-feuille-edition-hote")
            check("feuille_edition_capturee", true, "capture de la feuille attachée")
        } else {
            await screenshot("05-feuille-edition-hote")
            check("feuille_edition_capturee", false, "aucune feuille attachée détectée")
        }
        model.editor = nil
        await sleep(0.5)

        // 12. Plafond de 9 shells par maître : le 10e ouvre un second maître
        let acceptedBeforeH2 = acceptedCount
        let conn2 = model.connections.connection(for: h2)
        var h2tabs: [TerminalTab] = []
        for _ in 0..<10 { h2tabs.append(model.newTab(h2)) }
        check("dix_onglets_hote2_running", await wait(60) { h2tabs.allSatisfy { $0.status == .running } }, h2tabs.map { "\($0.status)" }.joined(separator: ","))
        let counts = conn2.links.map(\.tabCount)
        check("second_maitre_au_dela_de_9", conn2.links.count == 2 && counts == [9, 1], "onglets par maître : \(counts)")
        var sessions: [Int] = []
        for l in conn2.links { sessions.append(await l.transport.sessionCount) }
        check("sessionCount_par_maitre", sessions == [9, 1], "\(sessions)")
        check("deux_authentifications_pour_hote2", acceptedCount - acceptedBeforeH2 == 2, "\(acceptedCount - acceptedBeforeH2)")
        type(h2tabs[9], "echo TENTH-$((5*5))-${SSH_CONNECTION%% *}\r")
        check("dixieme_onglet_shell_fonctionnel", await waitText(h2tabs[9], "TENTH-25-127.0.0.1"))

        // 13. Fermeture de tous les onglets : plus de maître, plus de ssh enfant
        for t in model.workspace.tabs { model.close(t) }
        check("tous_onglets_fermes", model.workspace.tabs.isEmpty)
        let allDown = await wait(20) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } }
        check("tous_les_maitres_deconnectes", allDown, model.connections.allLinks.map { "\($0.state)" }.joined(separator: ","))
        var pids: [Int32?] = []
        for _ in 0..<100 {
            pids = []
            for l in model.connections.allLinks { pids.append(await l.transport.masterProcessIdentifier) }
            if pids.allSatisfy({ $0 == nil }) { break }
            await sleep(0.1)
        }
        check("aucun_pid_maitre", pids.allSatisfy { $0 == nil }, "\(pids)")
        _ = await wait(10) { model.connections.shellsEnded == model.connections.shellsStarted }
        check("shellSessionDidEnd_exactement_une_fois_par_shell", model.connections.shellsEnded == model.connections.shellsStarted,
              "démarrés \(model.connections.shellsStarted), terminés \(model.connections.shellsEnded)")
        var sc: [Int] = []
        for l in model.connections.allLinks { sc.append(await l.transport.sessionCount) }
        check("sessionCount_zero_partout", sc.allSatisfy { $0 == 0 }, "\(sc)")
        var kids: [String] = []
        _ = await wait(10) { kids = children(); return kids.isEmpty }
        check("aucun_processus_enfant_residuel", kids.isEmpty, kids.joined(separator: ", "))
        await screenshot("06-etat-vide")
        return finish()
    }

    private func readLibraryFile() -> HostLibrary? {
        guard let p = model.options.libraryPath, let d = FileManager.default.contents(atPath: p) else { return nil }
        return try? JSONDecoder().decode(HostLibrary.self, from: d)
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
