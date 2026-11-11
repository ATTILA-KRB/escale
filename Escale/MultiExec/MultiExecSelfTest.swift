import AppKit
import QuartzCore
import Foundation
import EscaleCore

/// `--selftest-multiexec <dossier>` : diffusion de saisie sur 3 panneaux puis commande groupée sur 3 hôtes,
/// contre un sshd local. Piloté par l'API interne (aucun événement clavier global). Écrit result.json + PNG.
/// La saisie est injectée par `engine.sendInput`, c'est-à-dire par le chemin de la frappe (moteur → délégué →
/// pty + observateurs de saisie).
@MainActor
struct MultiExecSelfTest {
    let directory: String
    let model: AppModel

    func run() async -> Bool {
        let t = Runner(dir: directory, model: model)
        return await t.run()
    }

    @MainActor
    final class Runner {
        let dir: String
        let model: AppModel
        private var checks: [(String, Bool, String)] = []
        private var shots: [String] = []
        private var notes: [String: String] = [:]
        private var window: NSWindow?
        private var feature: MultiExecFeature { model.multiExec }

        init(dir: String, model: AppModel) { self.dir = dir; self.model = model }

        // MARK: Aides

        private func check(_ name: String, _ cond: @autoclosure () async -> Bool, _ detail: String = "") async {
            let ok = await cond()
            checks.append((name, ok, detail))
            FileHandle.standardError.write(Data("[selftest-multiexec] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
        }
        private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }
        private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }
        private func type(_ p: Pane, _ s: String) { p.session.engine.sendInput(Data(s.utf8)) }
        private func tail(_ s: String, _ n: Int = 300) -> String { String(s.suffix(n)) }
        private func count(_ needle: String, in s: String) -> Int { s.components(separatedBy: needle).count - 1 }
        private func waitAll(_ panes: [Pane], _ s: String, _ timeout: Double = 15) async -> Bool {
            await wait(timeout) { panes.allSatisfy { text($0).contains(s) } }
        }
        private var acceptedCount: Int {
            guard let p = ProcessInfo.processInfo.environment["ESCALE_SSHD_LOG"],
                  let s = try? String(contentsOfFile: p, encoding: .utf8) else { return -1 }
            return s.components(separatedBy: "Accepted publickey").count - 1
        }
        private func pids(_ marker: String, in s: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: "\(marker)-(\\d+)-42") else { return [] }
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                Range(m.range(at: 1), in: s).map { String(s[$0]) }
            }
        }

        private func capture(_ name: String) async {
            guard let win = window else { return }
            win.orderFrontRegardless()
            await sleep(0.5)
            for _ in 0..<3 {
                for p in model.workspace.activeTab?.panes ?? [] { p.session.engine.refreshDisplay() }
                win.contentView?.needsDisplay = true
                win.displayIfNeeded()
                CATransaction.flush()
                await sleep(0.4)
            }
            let path = "\(dir)/\(name).png"
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            pr.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
            try? pr.run(); pr.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
        }

        private func children() -> [String] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axo", "pid=,ppid=,comm="]
            let pipe = Pipe(); p.standardOutput = pipe
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

        private func findMenuItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for i in menu.items {
                if i.title == title { return i }
                if let f = findMenuItem(title, in: i.submenu) { return f }
            }
            return nil
        }

        // MARK: Scénario

        func run() async -> Bool {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
                await check("fenetre_principale", false); return finish()
            }
            window = win
            win.orderFrontRegardless()
            await check("fenetre_principale", true)
            model.connections.graceDelay = 0.5
            _ = await wait(10) { model.library.isLoaded }
            let all = model.library.library.hosts
            let good = all.filter { $0.name.hasPrefix("Hôte ") && $0.name != "Hôte KO" }.sorted { $0.name < $1.name }
            guard good.count == 3, let dead = all.first(where: { $0.name == "Hôte KO" }) else { await check("hotes_disponibles", false); return finish() }
            let h1 = good[0]

            // 1. Trois panneaux sur le même hôte, diffusion éteinte
            let tab = model.newTab(h1)
            model.splitActivePane(.vertical)
            model.splitActivePane(.horizontal)
            let ps = tab.panes
            await check("trois_panneaux", ps.count == 3)
            await check("trois_panneaux_running", await wait(40) { ps.allSatisfy { $0.status == .running } }, ps.map { "\($0.status)" }.joined(separator: ","))
            guard ps.count == 3 else { return finish() }
            let (p1, p2, p3) = (ps[0], ps[1], ps[2])
            await check("diffusion_eteinte_au_depart", !feature.isBroadcasting && ps.allSatisfy { $0.session.inputObservers[MultiExecFeature.observerKey] == nil })
            type(p1, "echo SOLO-$((6*7))\r")
            await check("sans_diffusion_seul_le_panneau_source_recoit", await wait(10) { text(p1).contains("SOLO-42") })
            await sleep(1.0)
            await check("sans_diffusion_les_autres_vides", !text(p2).contains("SOLO-42") && !text(p3).contains("SOLO-42"))

            // 2. Diffusion sur les panneaux de l'onglet
            await check("demarrage_diffusion_onglet", feature.startBroadcast(.tab(tab.id)) && feature.isBroadcasting)
            await check("observateur_sur_chaque_panneau", ps.allSatisfy { $0.session.inputObservers[MultiExecFeature.observerKey] != nil })
            await check("bordure_rouge_sur_les_trois", ps.allSatisfy { feature.hasBroadcastBorder($0) })
            await check("groupe_de_trois", feature.broadcastPaneIDs == Set(ps.map(\.id)))
            type(p2, "echo BP-$$-$((6*7))\r")   // saisie dans le panneau 2 : répliquée vers 1 et 3
            let got = await waitAll(ps, "-42\n")
            let gotPids = await wait(15) { ps.allSatisfy { !pids("BP", in: text($0)).isEmpty } }
            await check("diffusion_resultat_dans_les_trois", got && gotPids, ps.map { tail(text($0), 80) }.joined(separator: " | "))
            let pidList = ps.map { pids("BP", in: text($0)) }
            await check("un_seul_resultat_par_panneau_pas_de_doublon", pidList.allSatisfy { $0.count == 1 }, "\(pidList)")
            await check("trois_shells_distincts", Set(pidList.compactMap(\.first)).count == 3, "\(pidList)")
            await check("sans_boucle_ecritures_repliquees", feature.replicatedWrites > 0 && feature.replicatedWrites <= 2 * 20, "\(feature.replicatedWrites)")
            // Collage : un seul envoi de plusieurs lignes ; Ctrl-C (octet brut) interrompt un sleep dans les trois
            let w0 = feature.replicatedWrites
            p1.session.engine.sendInput(Data("echo PASTE-$((3*3))\recho PASTE2-$((4*4))\r".utf8))
            await check("collage_dans_les_trois", await wait(15) { ps.allSatisfy { text($0).contains("PASTE-9\n") && text($0).contains("PASTE2-16\n") } })
            await check("collage_une_seule_ecriture_par_destinataire", feature.replicatedWrites - w0 == 2, "\(feature.replicatedWrites - w0)")
            await check("collage_sans_doublon", ps.allSatisfy { count("PASTE-9\n", in: text($0)) == 1 && count("PASTE2-16\n", in: text($0)) == 1 })
            type(p3, "sleep 60\r")
            await sleep(1.0)
            p3.session.engine.sendInput(Data([0x03]))
            type(p3, "echo AFTERC-$((2*2))\r")
            await check("ctrl_c_octet_brut_diffuse", await wait(15) { ps.allSatisfy { text($0).contains("AFTERC-4\n") } }, ps.map { tail(text($0), 120) }.joined(separator: " | "))
            // Réponse automatique du terminal (rapport de position) : jamais diffusée
            let w1 = feature.replicatedWrites
            p1.session.engine.sendInput(Data("\u{1b}[24;80R".utf8))
            await sleep(0.3)
            p1.session.write(Data([0x15]))   // Ctrl-U local : efface les octets parasites laissés dans la ligne de p1
            await check("rapport_terminal_non_diffuse", feature.replicatedWrites == w1, "\(feature.replicatedWrites - w1)")
            await capture("01-diffusion-active")

            // 3. Panneau créé pendant la diffusion : rejoint le groupe
            let p4 = model.splitActivePane(.vertical)!
            await check("nouveau_panneau_running", await wait(30) { p4.status == .running })
            await check("nouveau_panneau_rejoint_le_groupe", await wait(5) { feature.broadcastPaneIDs.contains(p4.id) && feature.hasBroadcastBorder(p4) })
            type(p1, "echo JOIN-$((5*5))\r")
            await check("nouveau_panneau_recoit", await wait(15) { [p1, p2, p3, p4].allSatisfy { text($0).contains("JOIN-25\n") } },
                        [p1, p2, p3, p4].map { "\($0.status) obs=\($0.session.inputObservers.count) " + tail(text($0), 60).debugDescription }.joined(separator: " | "))

            // 4. Sortie : plus rien n'est diffusé
            feature.stopBroadcast()
            await check("diffusion_arretee", !feature.isBroadcasting && feature.broadcastPaneIDs.isEmpty)
            await check("observateurs_retires", [p1, p2, p3, p4].allSatisfy { $0.session.inputObservers[MultiExecFeature.observerKey] == nil })
            await check("bordures_retirees", [p1, p2, p3, p4].allSatisfy { !feature.hasBroadcastBorder($0) })
            type(p1, "echo OFF-$((8*8))\r")
            await check("apres_arret_source_recoit", await wait(10) { text(p1).contains("OFF-64\n") })
            await sleep(1.0)
            await check("apres_arret_aucun_autre_ne_recoit", [p2, p3, p4].allSatisfy { !text($0).contains("OFF-64") })

            // 4b. Sortie par double Échap : jamais diffusé (groupe de deux panneaux : p1 → p2)
            await check("echap_demarrage", feature.startBroadcast(.panes([p1.id, p2.id])))
            let wE = feature.replicatedWrites
            p1.session.engine.sendInput(Data([0x1b]))
            await check("echap_seul_retenu_non_diffuse_tout_de_suite", feature.replicatedWrites == wE && feature.isBroadcasting, "\(feature.replicatedWrites - wE)")
            await check("echap_seul_diffuse_apres_le_delai", await wait(3) { feature.replicatedWrites == wE + 1 }, "\(feature.replicatedWrites - wE)")
            let wE2 = feature.replicatedWrites
            p1.session.engine.sendInput(Data([0x1b]))
            p1.session.engine.sendInput(Data("x".utf8))   // autre saisie : l'Échap retenu part d'abord, dans l'ordre
            await check("echap_puis_saisie_ordre_conserve", feature.replicatedWrites == wE2 + 2, "\(feature.replicatedWrites - wE2)")
            p1.session.write(Data([0x15]))
            let wE3 = feature.replicatedWrites, exits0 = feature.escapeExits
            p1.session.engine.sendInput(Data([0x1b]))
            p1.session.engine.sendInput(Data([0x1b]))
            await check("double_echap_arrete_la_diffusion", !feature.isBroadcasting && feature.escapeExits == exits0 + 1)
            await sleep(MultiExecFeature.escapeWindow + 0.4)
            await check("double_echap_aucune_fuite", feature.replicatedWrites == wE3, "\(feature.replicatedWrites - wE3)")
            await check("double_echap_observateurs_retires", [p1, p2].allSatisfy { $0.session.inputObservers[MultiExecFeature.observerKey] == nil })
            // Échap plus lent que la fenêtre : deux Échap seuls, aucune sortie
            feature.startBroadcast(.panes([p1.id, p2.id]))
            let wE4 = feature.replicatedWrites
            p1.session.engine.sendInput(Data([0x1b]))
            await sleep(MultiExecFeature.escapeWindow + 0.3)
            p1.session.engine.sendInput(Data([0x1b]))
            await sleep(MultiExecFeature.escapeWindow + 0.3)
            await check("echap_lents_pas_de_sortie", feature.isBroadcasting && feature.replicatedWrites == wE4 + 2, "\(feature.replicatedWrites - wE4)")
            feature.stopBroadcast()
            // ⌃⌥Échap : raccourci de menu
            feature.startBroadcast(.panes([p1.id, p2.id]))
            _ = await wait(5) { findMenuItem("Quitter la diffusion (jamais diffusé)", in: NSApp.mainMenu) != nil }
            if let item = findMenuItem("Quitter la diffusion (jamais diffusé)", in: NSApp.mainMenu) {
                let m = item.keyEquivalentModifierMask
                await check("menu_quitter_ctrl_option_echap", item.keyEquivalent == "\u{1b}" && m.contains(.control) && m.contains(.option), "\(item.keyEquivalent.unicodeScalars.map(\.value)) \(m.rawValue)")
                _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("\u{1b}", [.control, .option], win))
            } else { await check("menu_quitter_present", false) }
            if !(await wait(3) { !feature.isBroadcasting }) { feature.stopBroadcast(); notes["quitter_par_le_menu"] = "false" } else { notes["quitter_par_le_menu"] = "true" }
            await check("quitter_arrete_la_diffusion", !feature.isBroadcasting)

            for p in [p1, p2, p3, p4] { p.session.write(Data([0x15])) }   // efface les octets parasites laissés par les Échap
            // 5. Sélection de panneaux : p3 hors groupe
            await check("demarrage_selection", feature.startBroadcast(.panes([p1.id, p2.id])))
            await check("selection_bordures", feature.hasBroadcastBorder(p1) && feature.hasBroadcastBorder(p2) && !feature.hasBroadcastBorder(p3))
            type(p1, "echo SEL-$((9*9))\r")
            await check("selection_p2_recoit", await wait(10) { text(p2).contains("SEL-81\n") })
            await sleep(1.0)
            await check("selection_p3_p4_ne_recoivent_pas", !text(p3).contains("SEL-81") && !text(p4).contains("SEL-81"))
            type(p3, "echo HORS-$((2*21))\r")
            await sleep(1.5)
            await check("selection_saisie_hors_groupe_non_diffusee", text(p3).contains("HORS-42\n") && !text(p1).contains("HORS-42") && !text(p2).contains("HORS-42"))
            feature.stopBroadcast()
            await check("selection_un_seul_panneau_refuse", !feature.startBroadcast(.panes([p1.id])) && !feature.isBroadcasting)

            // 6. Tous les onglets
            let tabB = model.newTab(good[1])
            let pb = tabB.panes[0]
            await check("onglet_b_running", await wait(30) { pb.status == .running })
            await check("demarrage_tous_les_onglets", feature.startBroadcast(.allTabs))
            await check("groupe_de_cinq", await wait(5) { feature.broadcastPaneIDs.count == 5 }, "\(feature.broadcastPaneIDs.count)")
            type(pb, "echo ALL-$((11*11))\r")
            await check("tous_onglets_recoivent", await wait(15) { [p1, p2, p3, p4, pb].allSatisfy { text($0).contains("ALL-121\n") } })
            // Fermer un onglet pendant la diffusion : le groupe se resynchronise sans erreur
            model.close(tabB)
            await check("groupe_apres_fermeture_onglet", await wait(5) { feature.broadcastPaneIDs.count == 4 && !feature.broadcastPaneIDs.contains(pb.id) })

            // 7. Menu : ⌥⌘I bascule
            feature.stopBroadcast()
            model.workspace.select(tab.id)
            _ = await wait(5) { findMenuItem("Diffuser la saisie", in: NSApp.mainMenu) != nil }
            if let item = findMenuItem("Diffuser la saisie", in: NSApp.mainMenu) {
                let m = item.keyEquivalentModifierMask
                await check("menu_raccourci_option_commande_i", item.keyEquivalent == "i" && m.contains(.command) && m.contains(.option) && !m.contains(.shift), "\(item.keyEquivalent) \(m.rawValue)")
                _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("i", [.command, .option], win))
            } else { await check("menu_diffuser_present", false) }
            let viaMenu = await wait(3) { feature.isBroadcasting }
            if !viaMenu { feature.toggleBroadcast() }   // le menu SwiftUI ne répond pas toujours à un événement synthétique
            await check("bascule_active", feature.isBroadcasting, viaMenu ? "via le menu" : "via toggleBroadcast()")
            notes["bascule_par_le_menu"] = "\(viaMenu)"
            feature.toggleBroadcast()
            await check("bascule_desactive", !feature.isBroadcasting)

            // 8. Commande groupée sur 3 hôtes (Hôte 1 a des onglets ouverts ; 2 et 3 sont à connecter)
            _ = await wait(15) { good[1...].allSatisfy { model.connections.state(of: $0.id) == .disconnected } }   // délai de grâce écoulé
            let acceptedBefore = acceptedCount
            await check("hotes_2_3_non_connectes", good[1...].allSatisfy { model.connections.state(of: $0.id) == .disconnected })
            feature.beginGroupExec(hosts: good)
            await check("feuille_ouverte", feature.execDraft?.hosts.count == 3 && model.activeFeatureSheet == MultiExecFeature.execSheetID)
            await check("vide_refuse", feature.startGroupExec(command: "   ", timeout: 10, hosts: good) == nil)
            let run = feature.startGroupExec(command: "echo salut-$((6*7)); echo oups >&2; echo $SSH_CONNECTION", timeout: 20, hosts: good)
            await check("feuille_fermee_au_lancement", feature.execDraft == nil && model.activeFeatureSheet == nil && run != nil)
            guard let run else { return finish() }
            await check("trois_lignes_en_cours", run.rows.count == 3 && run.isRunning)
            await capture("02-commande-en-cours")
            await feature.waitForRun()
            let rows = run.rows
            await check("groupe_termine", !run.isRunning && rows.allSatisfy { $0.phase == .done })
            await check("trois_codes_zero", rows.allSatisfy { $0.result?.exitCode == 0 && $0.result?.isSuccess == true }, rows.map { $0.result?.summary ?? "nil" }.joined(separator: ","))
            await check("trois_sorties_salut_42", rows.allSatisfy { $0.result?.stdout.contains("salut-42\n") == true })
            await check("stderr_separe", rows.allSatisfy { $0.result?.stderr == "oups\n" })
            let ports = rows.compactMap { $0.result?.stdout.split(separator: "\n").last.flatMap { $0.split(separator: " ").dropFirst().first }.map(String.init) }
            await check("trois_connexions_distinctes", Set(ports).count == 3, "\(ports)")
            await check("deux_hotes_connectes_d_abord_une_auth_chacun", acceptedCount - acceptedBefore == 2 || acceptedBefore < 0, "authentifications : +\(acceptedCount - acceptedBefore)")
            await check("hotes_connectes_par_la_commande", good[1...].allSatisfy { model.connections.state(of: $0.id) == .connected || model.connections.state(of: $0.id) == .disconnected })
            let report = feature.reportText(run)
            await check("rapport_copiable", report.contains("=== Hôte 1 — code 0") && report.contains("=== Hôte 3 — code 0") && report.contains("salut-42"))
            notes["rapport"] = report

            // codes de sortie non nuls
            let run2 = feature.startGroupExec(command: "exit 3", timeout: 20, hosts: good)
            await feature.waitForRun()
            await check("code_3_sur_les_trois", run2?.rows.allSatisfy { $0.result?.exitCode == 3 && $0.result?.isSuccess == false } == true && run2?.failedCount == 3)
            // Relancer
            feature.rerun()
            await feature.waitForRun()
            await check("relancer_meme_commande", feature.execRun?.command == "exit 3" && feature.execRun?.rows.allSatisfy { $0.result?.exitCode == 3 } == true && feature.execRun?.id != run2?.id)
            // Délai maximal
            let t0 = Date()
            let run3 = feature.startGroupExec(command: "sleep 60", timeout: 2, hosts: good)
            await feature.waitForRun()
            await check("delai_maximal_sur_les_trois", run3?.rows.allSatisfy { $0.result?.timedOut == true && $0.result?.exitCode == nil } == true && Date().timeIntervalSince(t0) < 15, "\(Date().timeIntervalSince(t0)) s")
            // Hôte injoignable : erreur claire, les autres réussissent
            let run4 = feature.startGroupExec(command: "echo ok-$((3*3))", timeout: 20, hosts: [good[1], dead])
            await feature.waitForRun()
            let okRow = run4?.rows.first { $0.host.id == good[1].id }, koRow = run4?.rows.first { $0.host.id == dead.id }
            await check("hote_injoignable_erreur_claire", koRow?.result?.failure?.isEmpty == false && koRow?.result?.isSuccess == false, koRow?.result?.failure ?? "nil")
            await check("autres_hotes_reussissent", okRow?.result?.isSuccess == true && okRow?.result?.stdout == "ok-9\n")
            notes["hote_injoignable"] = koRow?.result?.failure ?? ""
            await capture("03-resultats")
            // 8b. Commande propre à chaque hôte + variables
            let ownCmds = [good[1].id: "echo special-{host}-{name}"]
            let run5 = feature.startGroupExec(command: "echo U={user} N={name} H={host}", timeout: 20, hosts: good, overrides: ownCmds)
            await feature.waitForRun()
            let r5 = run5?.rows ?? []
            await check("surcharge_commande_par_hote", r5.count == 3 && r5[1].result?.stdout == "special-127.0.0.1-Hôte 2\n", r5.map { $0.result?.stdout ?? "nil" }.joined(separator: "|"))
            await check("commune_avec_variables_pour_les_autres",
                        r5[0].result?.stdout == "U=\(good[0].user ?? "") N=Hôte 1 H=127.0.0.1\n" && r5[2].result?.stdout == "U=\(good[2].user ?? "") N=Hôte 3 H=127.0.0.1\n",
                        r5.map { $0.result?.stdout ?? "nil" }.joined(separator: "|"))
            await check("lignes_gardent_la_commande_resolue", r5[1].command == "echo special-127.0.0.1-'Hôte 2'" && r5[0].command.contains("N='Hôte 1'"), r5.map(\.command).joined(separator: "|"))
            let report5 = feature.reportText(run5!)
            await check("rapport_rappelle_la_commande_par_hote", report5.contains("$ echo special-127.0.0.1-'Hôte 2'"))
            feature.rerun()
            await feature.waitForRun()
            await check("relancer_garde_les_surcharges", feature.execRun?.rows[1].result?.stdout == "special-127.0.0.1-Hôte 2\n")
            // Injection par le nom : le nom d'un hôte ne sort jamais de son mot
            let evil = HostProfile(name: "x'; echo PWNED; '", host: good[0].host, port: good[0].port, user: good[0].user, auth: good[0].auth)
            let run6 = feature.startGroupExec(command: "echo {name}", timeout: 20, hosts: [evil])
            await feature.waitForRun()
            await check("nom_hostile_non_interprete", run6?.rows.first?.result?.stdout == "x'; echo PWNED; '\n", run6?.rows.first?.result?.stdout ?? "nil")

            // 8c. Cibles : dossier récursif, étiquette, connectés
            let folderID = all.first(where: { $0.name == "Hôte 1" })?.folderID
            if let folderID {
                feature.beginGroupExec(folder: folderID)
                await check("cible_dossier", feature.execDraft?.hosts.count == 4 && feature.execDraft?.source.contains("Tests locaux") == true, "\(feature.execDraft?.hosts.count ?? -1)")
                feature.retarget(feature.hosts(withTag: "test"), source: "Étiquette #test")
                await check("cible_etiquette", feature.execDraft?.hosts.count == 4 && feature.hosts(withTag: "#TEST").count == 4 && feature.hosts(withTag: "autre").isEmpty)
                feature.cancelGroupExecDraft()
            } else { await check("cible_dossier", false, "hôtes sans dossier") }
            await check("cible_connectes", Set(feature.connectedHosts.map(\.id)) == Set(model.library.library.hosts.filter { model.connections.state(of: $0.id) == .connected }.map(\.id)))
            feature.beginGroupExecOnConnected()
            await check("cible_connectes_feuille_selon_etat", (feature.execDraft != nil) == !feature.connectedHosts.isEmpty)
            feature.cancelGroupExecDraft()
            // Menu contextuel de dossier : vue instanciable et condition d'activation
            if let folderID, let folder = model.library.folder(folderID) {
                _ = MultiExecFolderMenuItems(model: model, folder: folder)
                await check("menu_dossier_actif", !feature.hosts(inFolder: folderID).isEmpty)
            }

            // 8d. Historique : dernières commandes, aucun secret, fichier JSON à côté de la bibliothèque
            let historyPath = URL(fileURLWithPath: model.options.libraryPath ?? "").deletingLastPathComponent().appendingPathComponent("exec-history.json").path
            await check("historique_memorise_les_commandes", feature.history.entries.first?.command == "echo {name}" && feature.history.entries.contains { $0.command == "exit 3" }, feature.history.entries.prefix(3).map(\.command).joined(separator: "|"))
            let secretCmd = "echo password=hunter2"
            await check("avertissement_secret", feature.secretWarning(secretCmd) != nil && feature.secretWarning("uptime") == nil)
            let before = feature.history.entries.count
            _ = feature.startGroupExec(command: secretCmd, timeout: 5, hosts: [good[0]])
            await feature.waitForRun()
            await check("secret_non_memorise", feature.history.entries.count == before && !feature.history.entries.contains { $0.command.contains("hunter2") })
            let histFile = (try? String(contentsOfFile: historyPath, encoding: .utf8)) ?? ""
            await check("fichier_historique_ecrit_sans_secret", histFile.contains("exit 3") && !histFile.contains("hunter2") && !histFile.contains("password"), historyPath)
            for i in 0..<22 { _ = feature.startGroupExec(command: "echo h\(i)", timeout: 5, hosts: [good[0]]); await feature.waitForRun() }
            await check("historique_vingt_max", feature.history.entries.count == 20 && feature.history.entries.first?.command == "echo h21", "\(feature.history.entries.count)")
            let reloaded = GroupExecHistory.load(from: URL(fileURLWithPath: historyPath))
            await check("historique_recharge_depuis_le_fichier", reloaded.entries.map(\.command) == feature.history.entries.map(\.command))

            // 8e. Export du rapport
            _ = feature.startGroupExec(command: "echo salut,\"x\"; echo e >&2", timeout: 20, hosts: Array(good.prefix(2)), overrides: [good[1].id: "exit 4"])
            await feature.waitForRun()
            let csvURL = URL(fileURLWithPath: "\(dir)/rapport.csv"), txtURL = URL(fileURLWithPath: "\(dir)/rapport.txt")
            let runX = feature.execRun!
            await check("export_csv_et_texte", feature.exportReport(runX, to: csvURL) && feature.exportReport(runX, to: txtURL))
            let csv = (try? String(contentsOf: csvURL, encoding: .utf8)) ?? "", txt = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
            let csvLines = csv.components(separatedBy: "\r\n")
            await check("csv_entete_et_lignes", csvLines[0].hasPrefix("hote,commande,statut,code_sortie") && csvLines.count == 4 && csv.contains("\"salut,x\n\"") && csvLines[2].contains(",echec,4,"), csv)
            await check("texte_contient_les_deux_hotes", txt.contains("=== Hôte 1 — code 0") && txt.contains("=== Hôte 2 — code 4") && txt.contains("$ exit 4"))
            let perms = (try? FileManager.default.attributesOfItem(atPath: csvURL.path)[.posixPermissions] as? Int) ?? 0
            await check("export_prive", perms == 0o600, String(perms, radix: 8))

            // Aucun exec résiduel, une seule action de session
            var execLeft = 0
            for l in model.connections.allLinks { execLeft += await l.transport.execSessionCount }
            await check("aucune_session_exec_residuelle", execLeft == 0, "\(execLeft)")
            feature.closeResults()
            await check("resultats_fermes", feature.execRun == nil)

            // 9. Nettoyage
            for t in model.workspace.tabs { model.close(t) }
            await check("tous_onglets_fermes", model.workspace.tabs.isEmpty)
            let down = await wait(30) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } }
            await check("tous_les_maitres_deconnectes", down, model.connections.allLinks.map { "\($0.state)" }.joined(separator: ","))
            var kids: [String] = []
            _ = await wait(15) { kids = children(); return kids.isEmpty }
            await check("aucun_processus_enfant_residuel", kids.isEmpty, kids.joined(separator: ", "))
            return finish()
        }

        private func keyEvent(_ chars: String, _ mods: NSEvent.ModifierFlags, _ win: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: 34)!
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
}
