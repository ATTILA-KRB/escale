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
        await macroVariablesScenario(f, hostA: hostA)
        if let hostS = hosts.first(where: { $0.name == "Hôte S" }) { await startupCommandScenario(hostS) } else { check("hote_s_declare", false) }
        // Serveur intégré d'abord : les scénarios suivants remplacent la détection par des serveurs simulés.
        if let hostE = hosts.first(where: { $0.name == "Hôte E" }) { await embeddedX11Scenario(f, host: hostE) }
        else { check("hote_e_declare", false) }
        await x11Scenario(f, hostX: hostX, hostY: hostY)
        if let hostR = hosts.first(where: { $0.name == "Hôte R" }) { await x11RefusedScenario(f, host: hostR) }
        else { check("hote_r_declare", false) }
        if let hostZ = hosts.first(where: { $0.name == "Hôte Z" }) { await x11UntrustedScenario(f, host: hostZ) }
        else { check("hote_z_declare", false) }
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

    // MARK: Variables {host}/{user}/{name}

    /// Lecture d'une macro avec variables : hôte du panneau SSH, terminal local, macro sans variable inchangée.
    private func macroVariablesScenario(_ f: MacroFeature, hostA: HostProfile) async {
        let tab = model.newTab(hostA)
        let p = tab.panes[0]
        check("vars_panneau_ssh_pret", await wait(25) { p.status == .running }, "\(p.status)")
        check("vars_valeurs_du_panneau_ssh", f.variables(for: p) == ["host": hostA.host, "user": hostA.user ?? "", "name": hostA.name], "\(f.variables(for: p))")
        let macro = Macro(name: "Variables", steps: [.text("echo VAR-{name}-{host}-{user}-$((6*7))\n"), .wait(milliseconds: 100), .text("echo LIT-{x}-${HOME:+ok}-{y}\n")])
        _ = await f.play(macro)?.value
        let expected = "VAR-\(hostA.name)-\(hostA.host)-\(hostA.user ?? "")-42"
        check("vars_substituees_cote_distant", await wait(10) { text(p).contains(expected) }, tail(text(p)))
        // La ligne saisie contient les valeurs échappées pour le shell (nom avec accent : entre apostrophes).
        check("vars_ligne_saisie_echappee", text(p).contains("echo VAR-'\(hostA.name)'-\(hostA.host)"), tail(text(p)))
        check("vars_accolades_inconnues_intactes", await wait(10) { text(p).contains("LIT-{x}-ok-{y}") }, tail(text(p)))
        model.close(tab)
        _ = await wait(10) { model.workspace.tabs.isEmpty }

        // Terminal local : localhost, utilisateur courant, « Terminal local ».
        let local = model.openLocalTab()
        let lp = local.panes[0]
        check("vars_terminal_local_pret", await wait(15) { lp.status == .running }, "\(lp.status)")
        check("vars_valeurs_terminal_local", f.variables(for: lp) == ["host": "localhost", "user": NSUserName(), "name": "Terminal local"], "\(f.variables(for: lp))")
        let m2 = Macro(name: "Local", steps: [.text("echo LOC-{name}-{host}-{user}-$((7*6))\n")])
        _ = await f.play(m2)?.value
        let expLocal = "LOC-Terminal local-localhost-\(NSUserName())-42"
        check("vars_local_substituees", await wait(10) { text(lp).contains(expLocal) }, tail(text(lp)))
        model.close(local)
        _ = await wait(10) { model.workspace.tabs.isEmpty }
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

    /// Serveur X11 intégré (Contents/Helpers/EscaleX11.app) : détection prioritaire, démarrage à la demande, vrai
    /// affichage (fenêtre xeyes du serveur, capturée), accès sans cookie refusé côté distant, arrêt par pid.
    private func embeddedX11Scenario(_ f: MacroFeature, host: HostProfile) async {
        let cm = model.connections
        guard let server = cm.x11Server else { check("x11_integre_embarque", false, "Contents/Helpers/EscaleX11.app absent"); return }
        check("x11_integre_embarque", true, server.bundle.appPath)
        guard let fakeDir = ProcessInfo.processInfo.environment["ESCALE_FAKEX_DIR"] else { check("x11_environnement_fourni", false); return }
        let d = cm.x11Detect()
        check("x11_integre_prioritaire", d.embedded && d.isReady && d.display == server.display, d.explanation)
        check("x11_integre_pas_demarre_sans_action", server.serverPID == nil)
        let opts = cm.sshOptions(for: host)
        check("x11_integre_options", opts.x11 == server.settings(trusted: false), "\(String(describing: opts.x11))")

        // 1. Commande courte : sans cookie, refus ; avec le cookie de substitution que sshd a reçu, X.Org répond.
        //    Sonde écrite côté « distant » (même machine) : le faux xauth de sshd garde ce cookie dans xauth.stdin,
        //    la sonde l'ajoute à un fichier d'autorité à elle (commandes > 500 caractères sinon).
        let mac = server.bundle.macOSDir
        let probePath = "\(fakeDir)/x11-probe.sh"
        let pidFile = "\(fakeDir)/xeyes.pid"
        let script = """
        #!/bin/sh
        M='\(mac)'
        echo "DISPLAY=$DISPLAY"
        if [ "$1" = court ]; then
          XAUTHORITY=/dev/null "$M/xdpyinfo" >/dev/null 2>&1 && echo SANS-COOKIE-ACCEPTE || echo SANS-COOKIE-REFUSE
        fi
        c=$(awk '/^add/{print $NF}' '\(fakeDir)/xauth.stdin' | tail -1)
        export XAUTHORITY='\(fakeDir)/remote.xauth'
        "$M/xauth" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$c"
        if [ "$1" = court ]; then "$M/xdpyinfo" | head -3; echo fin; exit 0; fi
        "$M/xeyes" -geometry 240x180+140+140 & echo $! > '\(pidFile)'; wait
        """
        try? script.write(toFile: probePath, atomically: true, encoding: .utf8)
        chmod(probePath, 0o755)
        let o1 = await f.launchX11(host: host, command: "'\(probePath)' court", settle: 15)
        check("x11_integre_serveur_demarre_a_la_demande", server.serverPID != nil)
        if case .exited(let code, let out) = o1 {
            check("x11_integre_display_distant", out.contains("DISPLAY=localhost:1"), tail(out))
            check("x11_integre_sans_cookie_refuse", out.contains("SANS-COOKIE-REFUSE") && !out.contains("SANS-COOKIE-ACCEPTE"), tail(out))
            check("x11_integre_xorg_repond", code == 0 && out.contains("The X.Org Foundation") && out.contains("fin"), tail(out))
        } else { check("x11_integre_xorg_repond", false, "\(o1)") }
        if let dir = try? FileManager.default.attributesOfItem(atPath: server.runtimeDirectory) {
            check("x11_integre_dossier_prive_0700", (dir[.posixPermissions] as? Int) == 0o700)
        } else { check("x11_integre_dossier_prive_0700", false) }

        // 2. Vraie fenêtre : xeyes s'affiche (fenêtre du processus serveur), capturée.
        let eyes = "'\(probePath)' xeyes"
        let o2 = await f.launchX11(host: host, command: eyes, settle: 2)
        check("x11_integre_xeyes_tourne", { if case .running = o2 { true } else { false } }(), "\(o2)")
        let spid = server.serverPID ?? -1
        var winID: Int?
        let shown = await wait(15) {
            // Largeur 240 ; hauteur 180 + barre de titre du gestionnaire de fenêtres (quartz-wm).
            winID = Self.windows(of: spid).first { abs($0.1 - 240) <= 4 && $0.2 >= 176 && $0.2 <= 215 }?.0
            return winID != nil
        }
        check("x11_integre_fenetre_xeyes_affichee", shown, "\(Self.windows(of: spid).map { "\($0.1)x\($0.2)" })")
        let wmPID = server.windowManagerPID
        check("x11_integre_gestionnaire_fenetres_lance", wmPID != nil && wmPID != spid, "\(String(describing: wmPID))")
        if let winID {
            // Décoration quartz-wm : titre « xeyes » et hauteur > 180 (barre de titre). Le titre est posé
            // après l'apparition de la fenêtre : l'attendre plutôt que le lire une fois (course). 15 s : sous charge
            // (tests du coeur en parallele), quartz-wm depasse 5 s ; l'attente s'arrete des que le titre est pose.
            _ = await wait(15) {
                Self.windowTitle(winID) == "xeyes" && (Self.windows(of: spid).first { $0.0 == winID }?.2 ?? 0) >= 196
            }
            let h = Self.windows(of: spid).first { $0.0 == winID }?.2 ?? 0
            check("x11_integre_fenetre_decoree_titre", Self.windowTitle(winID) == "xeyes", "\(Self.windowTitle(winID))")
            check("x11_integre_fenetre_decoree_barre_titre", h >= 196, "hauteur \(h) pour 180 demandes")
            try? await Task.sleep(nanoseconds: 800_000_000)
            let path = "\(directory)/x11-integre-xeyes.png"
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            pr.arguments = ["-x", "-o", "-l", "\(winID)", path]
            try? pr.run(); pr.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { results.shots.append("x11-integre-xeyes.png") }
        }
        // Fin : xeyes (pid exact écrit par la sonde), puis le maître, puis le serveur (pid, dossier supprimé).
        if let s = try? String(contentsOfFile: pidFile, encoding: .utf8), let xp = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(xp, SIGTERM)
        }
        _ = await wait(10) { cm.shellsEnded == cm.shellsStarted }
        await cm.existing(host.id)?.shutdown()
        server.stop()
        check("x11_integre_arret_par_pid", Darwin.kill(spid, 0) != 0 && server.serverPID == nil)
        check("x11_integre_gestionnaire_arrete_par_pid", wmPID.map { Darwin.kill($0, 0) != 0 } ?? false && server.windowManagerPID == nil)
        check("x11_integre_dossier_supprime", !FileManager.default.fileExists(atPath: server.runtimeDirectory))
        check("x11_integre_compteurs_shells", await wait(5) { cm.shellsEnded == cm.shellsStarted }, "\(cm.shellsStarted)/\(cm.shellsEnded)")
    }

    /// Fenêtres (numéro, largeur, hauteur) appartenant au processus `pid`.
    private static func windows(of pid: Int32) -> [(Int, Int, Int)] {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let wd = (b["Width"] as? NSNumber)?.intValue, let h = (b["Height"] as? NSNumber)?.intValue else { return nil }
            return (n, wd, h)
        }
    }

    /// Titre d'une fenêtre (kCGWindowName), vide si inconnu.
    private static func windowTitle(_ number: Int) -> String {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.first { ($0[kCGWindowNumber as String] as? Int) == number }?[kCGWindowName as String] as? String ?? ""
    }

    /// Commande de connexion (import MobaXterm/PuTTY) : tapée dans le shell à l'ouverture, le shell reste ouvert.
    private func startupCommandScenario(_ host: HostProfile) async {
        let tab = model.newTab(host)
        let p = tab.panes[0]
        check("startup_shell_ouvert", await wait(25) { p.status == .running }, "\(p.status)")
        check("startup_commande_executee", await wait(15) { text(p).contains("STARTUP-42") && text(p).contains("SECOND-72") }, tail(text(p)))
        type(p, "echo STILL-$((5*5))\r")
        check("startup_shell_reste_interactif", await wait(10) { text(p).contains("STILL-25") }, tail(text(p)))
        model.close(tab)
        _ = await wait(10) { model.workspace.tabs.isEmpty }
        check("startup_compteurs_shells", await wait(10) { model.connections.shellsEnded == model.connections.shellsStarted })
    }

    /// Serveur qui refuse la redirection X11 (second sshd, `X11Forwarding no`) : titre précis du diagnostic, refus
    /// signalé même si le programme tourne encore, avertissement dans le terminal (sortie de ssh conservée).
    private func x11RefusedScenario(_ f: MacroFeature, host: HostProfile) async {
        guard let fakeDir = ProcessInfo.processInfo.environment["ESCALE_FAKEX_DIR"] else { check("x11_environnement_fourni", false); return }
        let cm = model.connections
        cm.x11Detect = { X11Detection(xquartzPath: "/Applications/Utilities/XQuartz.app", xauthPath: "\(fakeDir)/fake-xauth", display: "\(fakeDir)/X0") }
        cm.x11Trusted = { true }
        let title = "Redirection X11 refusée par le serveur"

        // 1. Programme terminé pendant le délai : alerte au titre précis.
        f.notice = nil
        f.launchFromSheet(host: host, command: "echo fin; exit 3")
        check("x11_refus_programme_termine_titre", await wait(20) { f.notice != nil } && f.notice?.title == title,
              "\(f.notice?.title ?? "aucune alerte") : \(tail(f.notice?.message ?? ""))")
        check("x11_refus_sortie_brute_conservee", f.notice?.message.contains("X11 forwarding request failed") == true)

        // 2. Programme qui tourne encore après le délai : refus signalé quand même.
        f.notice = nil
        f.launchFromSheet(host: host, command: "sleep 4")
        check("x11_refus_programme_en_cours_signale", await wait(15) { f.notice != nil } && f.notice?.title == title,
              "\(f.notice?.title ?? "aucune alerte")")
        f.notice = nil

        // 3. Terminal interactif : avertissement en français après la ligne de ssh.
        let tab = model.newTab(host)
        let p = tab.panes[0]
        check("x11_refus_terminal_connecte", await wait(25) { p.status == .running }, "\(p.status)")
        check("x11_refus_terminal_avertit", await wait(10) { text(p).contains("redirection X11 refusée par le serveur") }, tail(text(p)))
        check("x11_refus_terminal_sortie_ssh_conservee", text(p).contains("X11 forwarding request failed"), tail(text(p)))
        check("x11_refus_terminal_avertit_une_fois", count("redirection X11 refusée", in: p) == 1, tail(text(p)))
        model.close(tab)
        _ = await wait(10) { model.workspace.tabs.isEmpty }
        check("x11_refus_compteurs_shells_coherents", await wait(10) { cm.shellsEnded == cm.shellsStarted }, "\(cm.shellsStarted)/\(cm.shellsEnded)")
    }

    /// X11 NON fiable (ForwardX11Trusted=no) avec un VRAI xauth (Homebrew) et un faux serveur X qui implémente
    /// l'extension SECURITY : ssh demande un vrai cookie « untrusted » (xauth generate), le distant ne reçoit qu'un
    /// cookie de substitution, et la connexion X rapatriée arrive au serveur local avec le vrai cookie généré.
    private func x11UntrustedScenario(_ f: MacroFeature, host: HostProfile) async {
        let env = ProcessInfo.processInfo.environment
        guard let xsec = env["ESCALE_XSEC_DIR"], let fakeDir = env["ESCALE_FAKEX_DIR"], let xauth = env["ESCALE_REAL_XAUTH"],
              FileManager.default.isExecutableFile(atPath: xauth), FileManager.default.fileExists(atPath: "\(xsec)/org.fake:0") else {
            check("x11_non_fiable_xauth_reel_disponible", false, "brew install xauth (sans sudo) requis"); return
        }
        let cm = model.connections
        let display = "\(xsec)/org.fake:0"
        cm.x11Detect = { X11Detection(xquartzPath: "/Applications/Utilities/XQuartz.app", xauthPath: xauth, display: display) }
        cm.x11Trusted = { false }
        let opts = cm.sshOptions(for: host)
        check("x11_non_fiable_options", opts.x11 == X11Settings(trusted: false, xauthPath: xauth, display: display))
        if let b = try? OpenSSHCommandBuilder(profile: host, controlPath: "/tmp/e/m", options: opts) {
            let m = b.masterArguments()
            check("x11_non_fiable_maitre_ForwardX11Trusted_no", m.contains("ForwardX11Trusted=no") && !m.contains("ForwardX11Trusted=yes") && !m.contains("-Y"), "\(m)")
        }
        // La sonde (scripts/fixtures/x11/xprobe.py) présente à localhost:60xx le cookie « add » reçu par sshd.
        let probe = "echo \"DISPLAY=$DISPLAY\"; python3 '\(xsec)/xprobe.py' '\(fakeDir)/xauth.stdin' '\(xsec)/proxy-cookie'; echo fin"
        let outcome = await f.launchX11(host: host, command: probe, settle: 10)
        switch outcome {
        case .exited(let code, let output):
            check("x11_non_fiable_commande_executee", code == 0 && output.contains("fin"), "code \(code) : \(tail(output))")
        default: check("x11_non_fiable_commande_executee", false, "\(outcome)")
        }
        let log = { (try? String(contentsOfFile: "\(xsec)/x.log", encoding: .utf8)) ?? "" }
        _ = await wait(8) { log().contains("CONNECT") }
        let generated = log().split(separator: "\n").filter { $0.hasPrefix("GenerateAuthorization") }
        check("x11_non_fiable_cookie_untrusted_genere_par_le_vrai_xauth", generated.count == 1 && generated[0].contains("MIT-MAGIC-COOKIE-1"), "\(generated)")
        let real = generated.first?.split(separator: " ").last.map(String.init) ?? ""
        let proxy = ((try? String(contentsOfFile: "\(xsec)/proxy-cookie", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        check("x11_non_fiable_le_distant_ne_voit_pas_le_vrai_cookie", real.count == 32 && proxy.count == 32 && proxy != real, "proxy \(proxy.prefix(4))… vrai \(real.prefix(4))…")
        let connects = log().split(separator: "\n").filter { $0.hasPrefix("CONNECT") }
        check("x11_non_fiable_connexion_rapatriee_avec_le_cookie_genere", connects.contains { $0.contains("cookie=\(real)") && $0.hasSuffix(" ok") }, "\(connects)")
        check("x11_non_fiable_compteurs_shells_coherents", await wait(5) { cm.shellsEnded == cm.shellsStarted }, "\(cm.shellsStarted)/\(cm.shellsEnded)")
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
                "x11": "Serveur X11 intégré : affichage réel de xeyes (capture x11-integre-xeyes.png). Chaîne XQuartz : faux serveur X local.",
            ],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(directory)/result.json"))
        }
        return ok
    }
}
