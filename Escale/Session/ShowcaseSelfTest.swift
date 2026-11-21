import AppKit
import QuartzCore
import Foundation
import EscaleCore

/// `--selftest-showcase <dossier>` : captures du site, contre le labo `scripts/showcase/lab.sh` (données fictives).
/// Piloté par l'API interne, comme les recettes : aucun événement clavier/souris global, aucune prise de focus,
/// fenêtre capturée même hors du Space actif. Réglages (thème, monitoring) en mémoire seulement : rien n'est écrit
/// dans les préférences de l'utilisateur. Écrit des PNG pleine fenêtre (recadrés ensuite pour le site) + result.json.
@MainActor
final class ShowcaseSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var window: NSWindow?

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-showcase] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }
    private func type(_ p: Pane, _ s: String) { p.session.engine.sendInput(Data(s.utf8)) }
    private func waitText(_ p: Pane, _ s: String, _ timeout: Double = 15) async -> Bool { await wait(timeout) { text(p).contains(s) } }
    private func host(_ name: String) -> HostProfile? { model.library.library.hosts.first { $0.name == name } }

    /// Shell propre puis commande : `clear` d'abord, la commande reste affichée en tête d'écran.
    private func run(_ p: Pane, _ cmd: String, until marker: String) async {
        type(p, "\u{15}clear\r")
        await sleep(0.4)
        type(p, cmd + "\r")
        _ = await waitText(p, marker, 15)
    }

    private func capture(_ name: String) async {
        guard let win = window else { return }
        win.orderFrontRegardless()
        await sleep(0.6)
        for _ in 0..<3 {
            for t in model.workspace.tabs { for p in t.panes { p.session.engine.refreshDisplay() } }
            win.contentView?.needsDisplay = true
            win.displayIfNeeded()
            CATransaction.flush()
            await sleep(0.4)
        }
        let path = "\(dir)/\(name).png"
        // screencapture échoue parfois (« could not create image from window ») : jusqu'à trois essais.
        for attempt in 0..<3 where !FileManager.default.fileExists(atPath: path) {
            if attempt > 0 { win.orderFrontRegardless(); await sleep(1.0) }
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            pr.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
            try? pr.run(); pr.waitUntilExit()
        }
        let ok = FileManager.default.fileExists(atPath: path)
        if ok { shots.append("\(name).png") }
        check("capture_\(name)", ok, ok ? "" : "cadre \(win.frame) feuille \(win.attachedSheet?.frame.debugDescription ?? "-") écran \(win.screen?.frame.debugDescription ?? "-")")
        // Garde-fou : aucun texte de terminal ne doit trahir la vraie machine (sinon la capture n'est pas publiable).
        let leaks = [NSUserName(), "/Users", "Darwin", "Traceback", ".hermes", "/private/var", ProcessInfo.processInfo.hostName]
        let found = model.workspace.tabs.flatMap(\.panes).flatMap { p in leaks.filter { text(p).contains($0) } }
        check("sans_fuite_\(name)", found.isEmpty, Set(found).sorted().joined(separator: ","))
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        window = win
        // Réglages en mémoire seulement (jamais les préférences réelles).
        model.colors.defaults = nil
        model.monitoring.defaults = nil
        model.colors.setTheme("tango")
        model.colors.setRules(.keywordsAndNetwork)
        _ = await wait(10) { model.library.isLoaded }
        // Cadre fixe : 1440×900 points (2880×1800 en Retina) pour les fonctions ; ESCALE_SHOWCASE_HERO=1 ne produit que le
        // héros du site, en 1280×800 (2560 px affichés à 1280 px CSS, soit 50 %) : passage séparé, car redimensionner la
        // fenêtre en cours de scénario rend ensuite la feuille des tunnels impossible à capturer.
        let heroOnly = ProcessInfo.processInfo.environment["ESCALE_SHOWCASE_HERO"] == "1"
        win.setContentSize(heroOnly ? NSSize(width: 1280, height: 800) : NSSize(width: 1440, height: 900))
        win.center()
        win.orderFrontRegardless()
        // Fenêtre active (feux tricolores en couleur) : seulement sur demande explicite, car l'app prend alors le focus.
        if ProcessInfo.processInfo.environment["ESCALE_SHOWCASE_ACTIVATE"] == "1" {
            NSApp.activate()
            win.makeKeyAndOrderFront(nil)
        }

        guard let web1 = host("web-01"), let db = host("db-primary"), let bastion = host("bastion") else {
            check("hotes_du_labo", false); return finish()
        }

        // 0. Accueil (connexion rapide, actions, aucune session) : tuile « Connexion rapide ».
        if !heroOnly { await capture("10-accueil") }

        // 1. Héros : trois onglets, web-01 scindé, monitoring, volet Fichiers qui suit le terminal.
        let tDB = model.newTab(db)
        let tBastion = model.newTab(bastion)
        let tWeb = model.newTab(web1)
        let left = tWeb.panes[0]
        check("web01_connecte", await wait(40) { left.status == .running }, "\(left.status)")
        guard left.status == .running else { return finish() }
        _ = await wait(30) { tDB.panes[0].status == .running && tBastion.panes[0].status == .running }
        guard let right = model.splitActivePane(.vertical) else { check("scission", false); return finish() }
        check("scission_connectee", await wait(30) { right.status == .running })
        model.monitoring.setEnabled(true, host: web1.id)
        model.sftp.injectTracking(in: left)   // suivi du dossier (OSC 7) : la fonction est tapée puis effacée par `clear`
        await sleep(0.8)
        for p in [left, right] { type(p, "cd /var/www/app\r") }
        await sleep(0.5)
        await run(right, "journalctl -u app -n 30 --no-pager", until: "app[")
        await run(left, "systemctl status nginx --no-pager", until: "Started nginx")
        tWeb.setActive(left.id)   // le volet Fichiers suit le panneau actif (OSC 7)
        model.workspace.select(tWeb.id)
        model.sidebarTab = .files
        model.sftp.isVisible = true
        if let s = model.sftp.currentSession() { await s.open() }
        await sleep(3.0)
        check("monitoring_recu", await wait(20) { model.monitoring.monitor(for: left.id)?.snapshot != nil })
        await sleep(2.5)   // deuxième relevé : débit et CPU renseignés
        await capture(heroOnly ? "00-hero" : "01-hero")
        if heroOnly {
            for t in model.workspace.tabs { model.close(t) }
            _ = await wait(15) { model.connections.shellsEnded == model.connections.shellsStarted }
            return finish()
        }

        // 2. Thème : même onglet en Dracula (tuile « Thèmes et coloration »).
        model.colors.setTheme("dracula")
        await sleep(0.8)
        await capture("11-theme-dracula")
        model.colors.setTheme("tango")

        // 3. Fichiers : un seul panneau, dossier riche.
        model.monitoring.setEnabled(false, host: web1.id)
        model.closePane(right)
        await run(left, "ls -la && docker ps", until: "CONTAINER ID")
        await sleep(2.0)
        await capture("02-fichiers")

        // 4. Multi-exécution : commande groupée sur l'étiquette #web (un hôte injoignable).
        model.sidebarTab = .sessions
        let webs = model.multiExec.hosts(withTag: "web")
        check("hotes_web", webs.count >= 3, "\(webs.map(\.name))")
        _ = model.multiExec.startGroupExec(command: "uptime && df -h / | tail -1", timeout: 8, hosts: webs)
        await model.multiExec.waitForRun()
        await sleep(1.0)
        await capture("03-multiexec")
        model.multiExec.closeResults()

        // 5. Diffusion de frappe : trois panneaux sous bordure rouge.
        let b2 = model.splitActivePane(.vertical), b3 = model.splitActivePane(.horizontal)
        let bps = tWeb.panes
        _ = await wait(30) { bps.allSatisfy { $0.status == .running } }
        for p in bps { type(p, "\u{15}cd /var/www/app && clear\r") }
        await sleep(0.5)
        check("diffusion", model.multiExec.startBroadcast(.tab(tWeb.id)))
        type(left, "sudo systemctl reload nginx && systemctl is-active nginx && uptime\r")
        _ = await wait(10) { bps.allSatisfy { text($0).contains("load average") } }
        check("diffusion_sans_trace", bps.allSatisfy { !text($0).contains("Traceback") })
        await sleep(0.8)
        await capture("04-diffusion")
        model.multiExec.stopBroadcast()
        for p in [b2, b3].compactMap({ $0 }) { model.closePane(p) }

        // 6. Tunnels : ceux du bastion démarrés, gestionnaire ouvert.
        // Tous les tunnels du bastion actifs. Sur web-01, « App interne » vise un port sans service : la sonde le
        // déclare en échec (la promesse du site : un tunnel refusé ne passe jamais pour ouvert) ; le webhook reste arrêté.
        var started = 0
        for spec in bastion.tunnels {
            if case .active = await model.tunnels.start(spec, on: bastion) { started += 1 }
        }
        check("tunnels_actifs", started == bastion.tunnels.count, "\(started)/\(bastion.tunnels.count)")
        if let app = web1.tunnels.first {
            let st = await model.tunnels.start(app, on: web1)
            var refused = true
            if case .active = st { refused = false }
            check("tunnel_refuse_signale", refused, "\(st)")
        }
        model.workspace.select(tBastion.id)
        model.tunnels.show()
        await sleep(1.5)
        await capture("05-tunnels")
        model.tunnels.isManagerPresented = false
        await sleep(0.6)
        await model.tunnels.stopAll(on: bastion)
        await model.tunnels.stopAll(on: web1)

        // 7. Outils (import) et macros : volets de la barre latérale.
        model.workspace.select(tWeb.id)
        model.sidebarTab = .tools
        await sleep(0.8)
        await capture("12-outils")
        model.macros.newDraft(scope: .global)
        model.macros.draft?.name = "Déployer l'app"
        model.macros.draft?.steps = [.text("cd /var/www/app && git pull --ff-only\r"), .wait(milliseconds: 1500), .text("sudo systemctl reload app\r")]
        model.macros.draft?.shortcut = 1
        _ = await model.macros.saveDraft()
        model.macros.newDraft(scope: .global)
        model.macros.draft?.name = "Espace disque"
        model.macros.draft?.steps = [.text("df -h && du -sh /var/log\r")]
        model.macros.draft?.shortcut = 2
        _ = await model.macros.saveDraft()
        model.macros.newDraft(scope: .host(web1.id))
        model.macros.draft?.name = "Logs nginx en direct"
        model.macros.draft?.steps = [.text("sudo tail -f /var/log/nginx/access.log\r")]
        _ = await model.macros.saveDraft()
        model.macros.draft = nil
        model.sidebarTab = .macros
        await sleep(0.8)
        await capture("13-macros")

        // 8. Monitoring seul (tuile).
        model.sidebarTab = .sessions
        model.monitoring.setEnabled(true, host: web1.id)
        await run(left, "w", until: "USER")
        _ = await wait(20) { (model.monitoring.monitor(for: left.id)?.samples ?? 0) >= 2 }
        await capture("14-monitoring")
        model.monitoring.setEnabled(false, host: web1.id)

        for t in model.workspace.tabs { model.close(t) }
        _ = await wait(15) { model.connections.shellsEnded == model.connections.shellsStarted }
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
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
