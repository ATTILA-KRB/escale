import AppKit
import Foundation
import EscaleCore

/// `--selftest-macros <dossier>` : macros et X11 contre un sshd local, piloté par l'API interne (aucun événement
/// clavier global). Écrit result.json (+ une capture) dans le dossier.
///
/// Variables d'environnement fournies par `scripts/selftest-macros.sh` :
/// - `ESCALE_FAKEX_DIR` : dossier contenant `fake-xauth`, `xauth.stdin` (cookie reçu par sshd) et le socket `X0` du faux serveur X ;
/// - `ESCALE_FAKEX_GOT` : fichier où le faux serveur X écrit les octets reçus.
/// Sans XQuartz sur la machine, c'est le faux serveur X qui joue l'écran : la preuve porte sur la chaîne ssh
/// (DISPLAY créé par sshd, connexion X rapatriée jusqu'au serveur local), pas sur l'affichage de xeyes.
@MainActor
struct MacroSelfTest {
    let directory: String
    let model: AppModel

    private final class Results { var checks: [(String, Bool, String)] = []; var shots: [String] = [] }
    private let results = Results()

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-macros] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }
    private func type(_ p: Pane, _ s: String) { p.session.engine.sendInput(Data(s.utf8)) }
    private func count(_ needle: String, in p: Pane) -> Int { text(p).components(separatedBy: needle).count - 1 }
    private func tail(_ s: String, _ n: Int = 300) -> String { String(s.suffix(n)) }

    private func capture(_ name: String, _ win: NSWindow) async {
        win.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        for p in model.workspace.activeTab?.panes ?? [] { p.session.engine.refreshDisplay() }
        win.displayIfNeeded()
        let path = "\(directory)/\(name).png"
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        pr.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? pr.run(); pr.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { results.shots.append("\(name).png") }
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else { check("fenetre_principale", false); return finish() }
        win.orderFrontRegardless()
        check("fenetre_principale", true)
        let f = model.macros
        model.connections.graceDelay = 0.5
        _ = await wait(10) { model.library.isLoaded && f.isLoaded }
        let hosts = model.library.library.hosts
        guard let hostA = hosts.first(where: { $0.name == "Hôte A" }), let hostX = hosts.first(where: { $0.name == "Hôte X" }),
              let hostY = hosts.first(where: { $0.name == "Hôte Y" }) else { check("hotes_disponibles", false); return finish() }
        check("hotes_x11_declares", !hostA.x11Forwarding && hostX.x11Forwarding && hostY.x11Forwarding)

        await macrosScenario(f, hostA: hostA, win: win)
        await x11Scenario(f, hostX: hostX, hostY: hostY)
        return finish()
    }

    // MARK: Macros

    private func macrosScenario(_ f: MacroFeature, hostA: HostProfile, win: NSWindow) async {
        // 1. Création, validation, persistance à côté de la bibliothèque
        let libraryPath = model.options.libraryPath ?? ""
        let macrosURL = URL(fileURLWithPath: libraryPath).deletingLastPathComponent().appendingPathComponent("macros.json")
        f.newDraft()
        f.draft?.name = "  Deux marqueurs  "
        f.draft?.steps = [.text("echo MKA-$((6*7))\n"), .wait(milliseconds: 300), .text("echo MKB-$((7*8))\n")]
        f.draft?.shortcut = 4
        let errs = await f.saveDraft()
        check("macro_creee_sans_erreur", errs.isEmpty && f.library.macros.count == 1 && f.library.macros[0].name == "Deux marqueurs", "\(errs)")
        check("fichier_macros_a_cote_de_la_bibliotheque", FileManager.default.fileExists(atPath: macrosURL.path), macrosURL.path)
        let reloaded = try? await FileMacroRepository(url: macrosURL).load()
        check("relecture_fichier_identique", reloaded == f.library, "\(reloaded?.macros.count ?? -1)")
        let attrs = try? FileManager.default.attributesOfItem(atPath: macrosURL.path)
        check("permissions_0600", (attrs?[.posixPermissions] as? Int) == 0o600)
        let macroAB = f.library.macros[0]

        // 2. Panneau SSH sur le sshd local, rejeu de la macro
        let tab = model.newTab(hostA)
        let p1 = tab.panes[0]
        let conn = model.connections.connection(for: hostA)
        check("onglet_ssh_connecte", await wait(25) { p1.status == .running && conn.state == .connected }, "\(conn.state)")
        type(p1, "echo READY-$((100+1))\r")
        check("shell_pret", await wait(15) { text(p1).contains("READY-101") }, tail(text(p1)))
        // Observateur espion : la lecture ne doit PAS passer par les observateurs de saisie (pas d'écho de diffusion).
        var spied = 0
        p1.session.inputObservers["spy"] = { _ in spied += 1 }
        let played = await f.play(macroAB)?.value
        check("lecture_actions_executees", played == 3, "\(String(describing: played))")
        check("lecture_marqueur_1_execute", await wait(10) { text(p1).contains("MKA-42") }, tail(text(p1)))
        check("lecture_marqueur_2_execute", await wait(10) { text(p1).contains("MKB-56") }, tail(text(p1)))
        check("lecture_ordre_conserve", { let t = text(p1); guard let a = t.range(of: "MKA-42"), let b = t.range(of: "MKB-56") else { return false }; return a.lowerBound < b.lowerBound }())
        check("lecture_sans_observateurs_de_saisie", spied == 0, "\(spied)")
        p1.session.inputObservers["spy"] = nil

        // 3. Enregistrement par saisie simulée (moteur → TerminalSession → inputObservers["macros"])
        check("enregistrement_demarre", f.startRecording() && f.isRecording)
        check("observateur_macros_installe", p1.session.inputObservers["macros"] != nil)
        type(p1, "echo REC-$((3*5))\r")
        check("saisie_executee_pendant_enregistrement", await wait(10) { text(p1).contains("REC-15") })
        check("etapes_capturees", f.recordedStepCount == 1, "\(f.recordedStepCount)")
        f.stopRecording()
        check("observateur_macros_retire", p1.session.inputObservers["macros"] == nil && !f.isRecording)
        check("editeur_ouvert_avec_la_saisie", f.managerOpen && f.draft?.steps == [.text("echo REC-$((3*5))\n")] && f.draftIsNew, "\(String(describing: f.draft?.steps))")
        check("feuille_declaree_au_modele", model.activeFeatureSheet == MacroFeature.sheetID)
        f.draft?.name = "Enregistrée"
        f.draft?.shortcut = 5
        let errs2 = await f.saveDraft()
        check("macro_enregistree_sauvee", errs2.isEmpty && f.library.macros.count == 2, "\(errs2)")
        f.managerOpen = false
        check("feuille_liberee", model.activeFeatureSheet == nil)
        let before = count("REC-15", in: p1)
        _ = await f.play(f.library.macros[1])?.value
        check("rejeu_de_la_saisie_enregistree", await wait(10) { count("REC-15", in: p1) == before + 1 }, "avant \(before), après \(count("REC-15", in: p1))")
        // Plus aucune capture une fois arrêté.
        type(p1, "echo AFTER-STOP\r")
        check("rien_capture_apres_arret", f.recordedStepCount == 1 && f.draft?.steps == [.text("echo REC-$((3*5))\n")])

        // 4. Raccourci ⌃⌥n et portée
        let b4 = count("MKA-42", in: p1)
        _ = await f.playShortcut(4)?.value
        check("raccourci_4_rejoue_la_macro", await wait(10) { count("MKA-42", in: p1) == b4 + 1 })
        check("raccourci_libre_ne_fait_rien", f.playShortcut(7) == nil)
        let other = UUID()
        var hostOnly = Macro(name: "Autre hôte", steps: [.text("echo NOPE\n")], shortcut: 6, scope: .host(other))
        f.draft = hostOnly; f.draftIsNew = true
        _ = await f.saveDraft()
        check("portee_hote_filtre_le_menu", !f.availableMacros.contains { $0.name == "Autre hôte" } && f.availableMacros.count == 2, "\(f.availableMacros.map(\.name))")
        check("portee_hote_pas_de_raccourci_ailleurs", f.playShortcut(6) == nil)
        hostOnly.scope = .host(hostA.id)
        f.edit(hostOnly)
        f.draft?.shortcut = 4
        let conflict = await f.saveDraft()
        check("conflit_raccourci_signale", conflict.contains { $0.severity == .error && $0.message.contains("⌃⌥4") }, "\(conflict)")

        // 5. Avertissement « ressemble à un mot de passe » (n'empêche pas l'enregistrement)
        f.newDraft()
        f.draft?.name = "Suspecte"
        f.draft?.steps = [.text("mysql -u root -pHunter2xx\n")]
        let warn = f.library.validate(f.draft!).filter { $0.severity == .warning }
        check("avertissement_mot_de_passe", !warn.isEmpty, "\(warn.map(\.message))")
        let errs3 = await f.saveDraft()
        check("avertissement_non_bloquant", errs3.isEmpty)
        if let id = f.library.macros.first(where: { $0.name == "Suspecte" })?.id { await f.delete(id) }
        let afterDelete = try? await FileMacroRepository(url: macrosURL).load()
        check("suppression_persistee", afterDelete?.macros.contains { $0.name == "Suspecte" } == false)

        // 6. Diffusion aux panneaux de l'onglet (sans dépendre du module multi-exécution)
        check("action_scinder", model.splitActivePane(.horizontal) != nil)
        check("deux_panneaux", await wait(5) { tab.panes.count == 2 })
        let p2 = tab.panes[1]
        check("panneau2_running", await wait(25) { p2.status == .running }, "\(p2.status)")
        type(p2, "echo READY2-$((200+2))\r")
        _ = await wait(10) { text(p2).contains("READY2-202") }
        _ = await f.play(macroAB, allPanes: true)?.value
        check("diffusion_panneau1", await wait(10) { count("MKB-56", in: p1) >= 3 }, "\(count("MKB-56", in: p1))")
        check("diffusion_panneau2", await wait(10) { text(p2).contains("MKA-42") && text(p2).contains("MKB-56") }, tail(text(p2)))
        await capture("macros", win)

        // 7. Fermeture : plus d'observateur, nombre de shells cohérent
        model.close(tab)
        check("onglet_ferme", await wait(10) { model.workspace.tabs.isEmpty })
        check("ptys_termines_a_la_fermeture", await wait(10) { p1.session.state != .running && p2.session.state != .running }, "\(p1.session.state) \(p2.session.state) \(model.connections.shellsStarted)/\(model.connections.shellsEnded)")
        check("shells_comptes_apres_fermeture_onglet", await wait(10) { model.connections.shellsEnded == model.connections.shellsStarted }, "\(model.connections.shellsStarted)/\(model.connections.shellsEnded)")
    }

    // MARK: X11

    private func x11Scenario(_ f: MacroFeature, hostX: HostProfile, hostY: HostProfile) async {
        let env = ProcessInfo.processInfo.environment
        guard let fakeDir = env["ESCALE_FAKEX_DIR"], let gotPath = env["ESCALE_FAKEX_GOT"] else { check("x11_environnement_fourni", false); return }
        let xauth = "\(fakeDir)/fake-xauth"
        let display = "\(fakeDir)/X0"
        let cm = model.connections

        // a. XQuartz absent : aucune option X11, message clair, jamais de -X
        cm.x11Detect = { X11Detection() }
        cm.x11Trusted = { false }
        check("xquartz_absent_etat", f.x11Detection.status == .notInstalled && f.x11Detection.explanation.contains("xquartz.org"))
        check("xquartz_absent_pas_d_options_x11", cm.sshOptions(for: hostY).x11 == nil)
        let bAbsent = try? OpenSSHCommandBuilder(profile: hostY, controlPath: "/tmp/e/m", options: cm.sshOptions(for: hostY))
        check("xquartz_absent_aucun_X_dans_les_arguments", bAbsent?.masterArguments().contains { $0.contains("X11") || $0 == "-X" } == false)
        let absent = await f.launchX11(host: hostY, command: "xeyes")
        if case .failed(let m) = absent { check("xquartz_absent_lancement_refuse_avec_message", m.contains("xquartz.org"), m) }
        else { check("xquartz_absent_lancement_refuse_avec_message", false, "\(absent)") }
        // Un onglet sur un hôte X11 sans XQuartz : le terminal le dit, la connexion fonctionne.
        let tabY = model.newTab(hostY)
        let py = tabY.panes[0]
        check("hote_x11_sans_xquartz_se_connecte", await wait(25) { py.status == .running }, "\(py.status)")
        check("hote_x11_sans_xquartz_avertit_dans_le_terminal", await wait(10) { text(py).contains("X11 non activé") }, tail(text(py)))
        type(py, "echo \"DISP[$DISPLAY]\"\r")
        check("hote_x11_sans_xquartz_pas_de_display_distant", await wait(10) { text(py).contains("DISP[]") }, tail(text(py)))
        model.close(tabY)
        _ = await wait(10) { model.workspace.tabs.isEmpty }
        check("compteurs_shells_apres_fermeture_des_onglets", await wait(10) { cm.shellsEnded == cm.shellsStarted }, "\(cm.shellsStarted)/\(cm.shellsEnded)")

        // b. XQuartz « présent » (injecté) : arguments du maître
        cm.x11Detect = { X11Detection(xquartzPath: "/Applications/Utilities/XQuartz.app", xauthPath: xauth, display: display) }
        cm.x11Trusted = { true } // le faux xauth ne fabrique pas de cookie « untrusted » exploitable
        let opts = cm.sshOptions(for: hostX)
        check("xquartz_present_options_x11", opts.x11 == X11Settings(trusted: true, xauthPath: xauth, display: display))
        var noX11 = hostX; noX11.x11Forwarding = false
        check("hote_sans_x11_jamais_d_options", cm.sshOptions(for: noX11).x11 == nil)
        if let b = try? OpenSSHCommandBuilder(profile: hostX, controlPath: "/tmp/e/m", options: opts) {
            let m = b.masterArguments()
            check("maitre_ForwardX11", m.contains("ForwardX11=yes") && m.contains("XAuthLocation=\(xauth)") && m.contains("ForwardX11Trusted=yes"), "\(m)")
            let e = b.execArguments(remoteCommand: "xeyes")
            check("exec_invariant2_et_X11", e.contains("ControlMaster=no") && e.contains("ProxyCommand=/usr/bin/false") && e.contains("ForwardX11=yes") && e.last == "xeyes", "\(e)")
        } else { check("maitre_ForwardX11", false, "builder") }

        // c. De bout en bout : « Lancer une application X11 » → sshd crée DISPLAY=localhost:10 → la connexion X ressort sur le faux serveur
        let probe = "echo \"DISPLAY=$DISPLAY\"; python3 -c \"import os,socket,time;c=[l.split()[-1] for l in open('\(fakeDir)/xauth.stdin') if l.startswith('add')][-1];p=6000+int(os.environ['DISPLAY'].split(':')[1].split('.')[0]);s=socket.create_connection(('localhost',p));s.sendall(b'l\\\\0\\\\x0b\\\\0\\\\0\\\\0\\\\x12\\\\0\\\\x10\\\\0\\\\0\\\\0MIT-MAGIC-COOKIE-1\\\\0\\\\0'+bytes.fromhex(c)+b'XPROBE');time.sleep(0.3)\"; echo fin"
        f.openX11Launcher(hostX)
        check("feuille_x11_declaree", model.activeFeatureSheet == MacroFeature.sheetID && f.x11Host?.id == hostX.id)
        f.x11Host = nil
        check("feuille_x11_liberee", model.activeFeatureSheet == nil)
        let outcome = await f.launchX11(host: hostX, command: probe, settle: 10)
        switch outcome {
        case .exited(let code, let output):
            check("x11_commande_executee_sur_le_maitre", code == 0 && output.contains("fin"), "code \(code) : \(tail(output))")
            check("x11_display_distant_localhost_10", output.contains("DISPLAY=localhost:10"), tail(output))
        default: check("x11_commande_executee_sur_le_maitre", false, "\(outcome)")
        }
        let got = await wait(8) { ((try? Data(contentsOf: URL(fileURLWithPath: gotPath))) ?? Data()).range(of: Data("XPROBE".utf8)) != nil }
        check("x11_connexion_arrivee_sur_le_faux_serveur_local", got)
        let link = cm.existing(hostX.id)?.links.first
        check("x11_un_seul_maitre_une_authentification", cm.existing(hostX.id)?.links.count == 1 && link?.connectAttempts == 1, "\(String(describing: link?.connectAttempts))")
        check("x11_transport_avec_forward", link?.transport.configuration.ssh.x11 != nil)
        check("x11_compteurs_shells_coherents", await wait(5) { cm.shellsEnded == cm.shellsStarted }, "\(cm.shellsStarted)/\(cm.shellsEnded)")
        let badCmd = await f.launchX11(host: hostX, command: "  ")
        check("x11_commande_vide_refusee", { if case .failed = badCmd { true } else { false } }())
        check("x11_etat_xquartz_present", f.x11Detection.isReady)
    }

    // MARK: Fin

    private func finish() -> Bool {
        let r = results
        let ok = !r.checks.isEmpty && r.checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(uniqueKeysWithValues: r.checks.map { ($0.0, $0.1) }),
            "details": Dictionary(uniqueKeysWithValues: r.checks.map { ($0.0, $0.2) }),
            "failed": r.checks.filter { !$0.1 }.map(\.0),
            "screenshots": r.shots,
            "notes": [
                "x11": "Sans XQuartz : faux serveur X local ; l'affichage réel (xeyes) reste à valider après installation de XQuartz.",
            ],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(directory)/result.json"))
        }
        return ok
    }
}
