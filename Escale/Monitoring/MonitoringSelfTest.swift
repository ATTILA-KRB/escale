import AppKit
import QuartzCore
import Foundation
import EscaleCore

/// `--selftest-monitoring <dossier>` : barre de monitoring distant contre un sshd local (macOS : repli sysctl/vm_stat).
/// Piloté par l'API interne (aucun événement clavier/souris global). Écrit result.json + PNG.
/// Vérifie : rien d'ouvert tant que non activé (invariant 12), activation → +1 session exec unique, valeurs
/// reçues et affichées, désactivation → session rendue, fermeture de panneau → session rendue, maître plein →
/// rien d'ouvert (invariant 5), déconnexion → tout rendu.
@MainActor
struct MonitoringSelfTest {
    let directory: String
    let model: AppModel

    func run() async -> Bool { await Runner(dir: directory, model: model).run() }

    @MainActor
    final class Runner {
        let dir: String
        let model: AppModel
        private var checks: [(String, Bool, String)] = []
        private var shots: [String] = []
        private var notes: [String: String] = [:]
        private var window: NSWindow?
        private var feature: MonitoringFeature { model.monitoring }

        init(dir: String, model: AppModel) { self.dir = dir; self.model = model }

        // MARK: Aides

        private func check(_ name: String, _ cond: @autoclosure () async -> Bool, _ detail: String = "") async {
            let ok = await cond()
            checks.append((name, ok, detail))
            FileHandle.standardError.write(Data("[selftest-monitoring] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
        }
        private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }
        private func waitAsync(_ timeout: Double = 10, _ cond: () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
            return await cond()
        }
        private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }

        private func sessions(_ p: Pane) async -> Int { await p.link?.transport.sessionCount ?? -1 }
        private func execs(_ p: Pane) async -> Int { await p.link?.transport.execSessionCount ?? -1 }
        private var acceptedCount: Int {
            guard let p = ProcessInfo.processInfo.environment["ESCALE_SSHD_LOG"],
                  let s = try? String(contentsOfFile: p, encoding: .utf8) else { return -1 }
            return s.components(separatedBy: "Accepted publickey").count - 1
        }

        private func findHost(_ v: NSView) -> PaneHostView? {
            if let h = v as? PaneHostView { return h }
            for s in v.subviews { if let h = findHost(s) { return h } }
            return nil
        }
        private var paneHost: PaneHostView? { window?.contentView.flatMap(findHost) }

        /// Processus ssh de cette app dont la ligne de commande porte le script de monitoring.
        private func scriptProcessCount() -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axww", "-o", "ppid=,args="]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let me = getpid()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
                let t = line.drop(while: { $0 == " " })
                guard let sp = t.firstIndex(of: " "), Int32(t[t.startIndex..<sp]) == me else { return false }
                return t.contains("@@ESC begin")
            }.count
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
            feature.defaults = nil   // réglage en mémoire : ne touche jamais aux préférences de l'utilisateur
            _ = await wait(10) { model.library.isLoaded }
            guard let h1 = model.library.library.hosts.first(where: { $0.name == "Hôte 1" }) else {
                await check("hote_disponible", false); return finish()
            }

            // 1. Désactivé par défaut : un panneau SSH ouvert, aucune session de monitoring (invariant 12)
            let tab = model.newTab(h1)
            let p1 = tab.panes[0]
            await check("panneau_running", await wait(40) { p1.status == .running }, "\(p1.status)")
            guard p1.status == .running else { return finish() }
            await check("desactive_par_defaut", feature.monitors.isEmpty && !feature.isEnabled(host: h1.id))
            await check("aucune_barre_affichee", paneHost?.monitorBarView(p1.id) == nil)
            await sleep(3.5)   // plus long qu'un intervalle de relevé
            let sc0 = await sessions(p1), ex0 = await execs(p1)
            await check("sessionCount_inchange_sans_activation", sc0 == 1 && ex0 == 0, "sessions=\(sc0) exec=\(ex0)")
            await check("aucun_script_en_cours_sans_activation", scriptProcessCount() == 0)
            let accepted0 = acceptedCount

            // 2. Commande de menu : « Afficher le monitoring distant » (active le panneau SSH courant)
            let item = findMenuItem("Afficher le monitoring distant", in: NSApp.mainMenu)
            await check("commande_de_menu_presente", item != nil || NSApp.mainMenu == nil, item == nil ? "menu principal sans l'entrée (menus SwiftUI non peuplés avant affichage ?)" : "")
            await check("hote_suivi_par_le_panneau_actif", feature.activeHostID == h1.id)
            feature.toggle(host: h1.id)
            await check("moniteur_cree_pour_le_panneau", feature.monitor(for: p1.id) != nil)
            await check("session_exec_ouverte_plus_un", await waitAsync(10) { await sessions(p1) == 2 }, "sessions=\(await sessions(p1))")
            await check("une_seule_session_exec", await execs(p1) == 1, "\(await execs(p1))")
            await check("barre_affichee_sous_le_terminal", await wait(5) { paneHost?.monitorBarView(p1.id) != nil })
            guard let m = feature.monitor(for: p1.id) else { return finish() }

            // 3. Valeurs reçues (deux relevés pour CPU/débit : le CPU de macOS est direct, le débit demande un delta)
            await check("premier_releve_recu", await wait(15) { m.snapshot != nil })
            await check("deuxieme_releve_recu", await wait(15) { m.samples >= 2 }, "relevés=\(m.samples)")
            let snap = m.snapshot
            await check("charge_recue", snap?.load1 != nil, "\(String(describing: snap?.load1))")
            await check("cpu_recu", snap?.cpuPercent != nil, "\(String(describing: snap?.cpuPercent))")
            await check("memoire_recue", (snap?.memTotal ?? 0) > 0 && snap?.memUsed != nil, "\(String(describing: snap?.memUsed))/\(String(describing: snap?.memTotal))")
            await check("disque_recu", snap?.diskPercent != nil, "\(String(describing: snap?.diskPercent))")
            await check("debit_reseau_recu", snap?.netInRate != nil && snap?.netOutRate != nil, "\(String(describing: snap?.netInRate)) / \(String(describing: snap?.netOutRate))")
            await check("utilisateurs_recus", (snap?.users ?? 0) >= 1, "\(String(describing: snap?.users))")
            await check("uptime_recu", (snap?.uptime ?? 0) > 60, "\(String(describing: snap?.uptime))")
            await check("systeme_reconnu", snap?.os == "Darwin", snap?.os ?? "")
            if let snap {
                let summary = MonitoringBar.summary(snap)
                notes["barre"] = summary
                await check("barre_affiche_les_sept_valeurs", MonitoringBar.items(snap).allSatisfy { !$0.value.contains("—") }, summary)
            }
            await check("phase_running", m.phase == .running, "\(m.phase)")
            // Un seul flux long : la session reste unique et aucune nouvelle authentification n'a eu lieu
            await sleep(5)
            await check("toujours_une_session_apres_plusieurs_releves", await sessions(p1) == 2 && m.samples >= 4, "sessions=\(await sessions(p1)) relevés=\(m.samples)")
            await check("aucune_nouvelle_authentification", acceptedCount == accepted0, "\(acceptedCount) vs \(accepted0)")
            await check("un_script_en_cours_cote_client", scriptProcessCount() >= 1, "\(scriptProcessCount())")
            // Le terminal reste utilisable pendant le monitoring
            p1.session.engine.sendInput(Data("echo MON-$((6*7))\r".utf8))
            await check("terminal_utilisable_pendant_le_monitoring", await wait(10) { text(p1).contains("MON-42") })
            await capture("01-barre-active")

            // 4. Désactivation : session rendue, barre retirée
            feature.setEnabled(false, host: h1.id)
            await check("moniteur_retire", feature.monitors.isEmpty)
            await check("session_rendue_a_la_desactivation", await waitAsync(10) { await sessions(p1) == 1 }, "sessions=\(await sessions(p1))")
            await check("barre_retiree", await wait(5) { paneHost?.monitorBarView(p1.id) == nil })
            await check("script_arrete", await wait(10) { scriptProcessCount() == 0 }, "\(scriptProcessCount())")
            await capture("02-barre-desactivee")

            // 5. Réactivation sur deux panneaux, puis fermeture d'un panneau : sa session est rendue
            feature.setEnabled(true, host: h1.id)
            let p2 = model.splitActivePane(.vertical)!
            await check("second_panneau_running", await wait(30) { p2.status == .running })
            await check("un_moniteur_par_panneau", await wait(10) { feature.monitors.count == 2 }, "\(feature.monitors.count)")
            await check("deux_shells_plus_deux_moniteurs", await waitAsync(10) { await sessions(p1) == 4 }, "sessions=\(await sessions(p1))")
            await check("barres_sous_chaque_panneau", await wait(10) { paneHost?.monitorBarView(p1.id) != nil && paneHost?.monitorBarView(p2.id) != nil })
            await check("valeurs_dans_les_deux_barres", await wait(15) { feature.monitor(for: p1.id)?.snapshot != nil && feature.monitor(for: p2.id)?.snapshot != nil })
            await capture("03-deux-panneaux")
            model.closePane(p2)
            await check("moniteur_du_panneau_ferme_arrete", await wait(10) { feature.monitor(for: p2.id) == nil }, "\(feature.monitors.count)")
            await check("session_rendue_a_la_fermeture_du_panneau", await waitAsync(10) { await sessions(p1) == 2 }, "sessions=\(await sessions(p1))")

            // 6. Maître plein : rien n'est ouvert, indication discrète (invariant 5)
            feature.setEnabled(false, host: h1.id)
            _ = await waitAsync(10) { await sessions(p1) == 1 }
            var fillers: [RemoteExecStream] = []
            if let transport = p1.link?.transport {
                for _ in 0..<9 { if let s = try? await transport.openShellStream("sleep 120") { fillers.append(s) } }
            }
            await check("maitre_rempli", await sessions(p1) == 10, "sessions=\(await sessions(p1))")
            feature.setEnabled(true, host: h1.id)
            let busy = feature.monitor(for: p1.id)
            await check("maitre_plein_phase_occupe", await wait(40) { busy?.phase == .busy }, "\(String(describing: busy?.phase))")
            await check("maitre_plein_aucune_session_ajoutee", await sessions(p1) == 10, "sessions=\(await sessions(p1))")
            await check("maitre_plein_barre_discrete", await wait(5) { paneHost?.monitorBarView(p1.id) != nil })
            await capture("04-maitre-plein")
            feature.setEnabled(false, host: h1.id)
            for s in fillers { s.cancel() }
            for s in fillers { _ = await s.finish(timeout: 3) }
            await check("sessions_remplissage_rendues", await waitAsync(10) { await sessions(p1) == 1 }, "sessions=\(await sessions(p1))")

            // 7. Message « indisponible » (système inconnu : le texte vient du même rendu que le vrai cas)
            feature.setEnabled(true, host: h1.id)
            _ = await wait(10) { feature.monitor(for: p1.id)?.snapshot != nil }
            feature.monitor(for: p1.id)?.phase = .unsupported
            await capture("05-indisponible")
            feature.setEnabled(false, host: h1.id)
            _ = await waitAsync(10) { await sessions(p1) == 1 }

            // 8. Déconnexion : tout est rendu (aucune session fantôme sur aucun maître)
            feature.setEnabled(true, host: h1.id)
            _ = await waitAsync(10) { await sessions(p1) == 2 }
            model.closePane(p1, in: tab)
            _ = await wait(10) { model.workspace.tabs.isEmpty }
            await check("moniteurs_vides_apres_fermeture", await wait(10) { feature.monitors.isEmpty })
            let linksDead = await wait(15) { model.connections.allLinks.allSatisfy { $0.isDead } }
            await check("liens_deconnectes", linksDead)
            var sc: [Int] = []
            for l in model.connections.allLinks { sc.append(await l.transport.sessionCount) }
            await check("sessionCount_zero_partout", sc.allSatisfy { $0 == 0 }, "\(sc)")
            await check("aucun_script_restant", await wait(10) { scriptProcessCount() == 0 }, "\(scriptProcessCount())")

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
}
