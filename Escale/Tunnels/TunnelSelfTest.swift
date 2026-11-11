import AppKit
import Foundation
import EscaleCore

/// `--selftest-tunnels <dossier>` : scénario piloté en interne contre un sshd local (voir `scripts/selftest-tunnels.sh`).
/// L'hôte « Hôte A » de la bibliothèque porte quatre tunnels : L, D, R et un L `autoStart`. Un serveur HTTP local
/// (port dans `ESCALE_TUNNEL_HTTP_PORT`) répond `ESCALE_TUNNEL_HTTP_BODY` ; chaque tunnel est vérifié par curl.
/// Aucun événement clavier ou souris global, pas d'activation de l'app. Écrit result.json + PNG dans le dossier.
@MainActor
struct TunnelSelfTest {
    let directory: String
    let model: AppModel

    func run() async -> Bool {
        let r = Runner(dir: directory, model: model)
        return await r.run()
    }

    @MainActor
    private final class Runner {
        let dir: String
        let model: AppModel
        var checks: [(String, Bool, String)] = []
        var shots: [String] = []
        var notes: [String: String] = [:]

        init(dir: String, model: AppModel) { self.dir = dir; self.model = model }

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok, detail))
            FileHandle.standardError.write(Data("[selftest-tunnels] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
        }

        func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }

        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

        /// curl hors du thread principal.
        func curl(_ args: [String]) async -> (status: Int32, out: String) {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    p.arguments = ["-s", "--noproxy", "*", "--max-time", "5"] + args
                    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
                    do { try p.run() } catch { cont.resume(returning: (-1, "")); return }
                    let d = o.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
                }
            }
        }

        func capture(_ window: NSWindow, _ name: String) {
            let path = "\(dir)/\(name).png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
            try? p.run(); p.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
        }

        func finish() -> Bool {
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

        /// Vrai quand le port local n'accepte plus de connexion (curl code 7).
        func isClosed(_ port: Int) async -> Bool { await curl(["http://127.0.0.1:\(port)/"]).status == 7 }

        func run() async -> Bool {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let env = ProcessInfo.processInfo.environment
            guard let httpPort = env["ESCALE_TUNNEL_HTTP_PORT"].flatMap(Int.init), let body = env["ESCALE_TUNNEL_HTTP_BODY"] else {
                check("environnement_recette", false, "ESCALE_TUNNEL_HTTP_PORT / ESCALE_TUNNEL_HTTP_BODY absents"); return finish()
            }
            guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
                check("fenetre_principale", false); return finish()
            }
            win.orderFrontRegardless()
            check("fenetre_principale", true)
            model.connections.graceDelay = 0.5
            model.connections.reconnectDelays = [0.5, 1]
            model.tunnels.watchInterval = .milliseconds(500)
            _ = await wait(10) { model.library.isLoaded }

            guard let host = model.library.library.hosts.first(where: { $0.name == "Hôte A" }),
                  let l = host.tunnels.first(where: { $0.kind == .local && !$0.autoStart }),
                  let d = host.tunnels.first(where: { $0.kind == .dynamic }),
                  let r = host.tunnels.first(where: { $0.kind == .remote }),
                  let auto = host.tunnels.first(where: { $0.autoStart }) else {
                check("hote_avec_tunnels", false, "bibliothèque inattendue"); return finish()
            }
            check("hote_avec_tunnels", host.tunnels.count == 4, "\(host.tunnels.map(\.summary))")
            let feature = model.tunnels
            let url: (TunnelSpec) -> String = { "http://127.0.0.1:\($0.bindPort)/" }
            check("etat_initial_arrete", host.tunnels.allSatisfy { feature.state(of: $0.id) == .stopped })

            // 1. Connexion par un onglet : le tunnel autoStart s'ouvre tout seul.
            let tab = model.newTab(host)
            let conn = model.connections.connection(for: host)
            check("connexion_hote", await wait(25) { tab.panes[0].status == .running && conn.state == .connected }, "\(conn.state)")
            check("autostart_actif", await wait(15) { feature.state(of: auto.id) == .active }, "\(feature.state(of: auto.id))")
            var c = await curl([url(auto)])
            check("autostart_curl", c.status == 0 && c.out == body, "status \(c.status) corps \(c.out.prefix(60))")

            // 2. Les trois types, vérifiés par curl.
            check("local_ouvert", await feature.start(l, on: host) == .active)
            c = await curl([url(l)])
            check("local_curl", c.status == 0 && c.out == body, "status \(c.status) corps \(c.out.prefix(60))")
            check("dynamic_ouvert", await feature.start(d, on: host) == .active)
            c = await curl(["--socks5-hostname", "127.0.0.1:\(d.bindPort)", "http://127.0.0.1:\(httpPort)/"])
            check("dynamic_curl_socks5", c.status == 0 && c.out == body, "status \(c.status) corps \(c.out.prefix(60))")
            check("remote_ouvert", await feature.start(r, on: host) == .active)
            c = await curl([url(r)])
            check("remote_curl_cote_serveur", c.status == 0 && c.out == body, "status \(c.status) corps \(c.out.prefix(60))")

            // 3. Gestionnaire ouvert : feuille déclarée, capture.
            feature.show(host: host.id)
            check("gestionnaire_feuille_declaree", await wait(5) { model.activeFeatureSheet == TunnelFeature.sheetID }, "\(model.activeFeatureSheet ?? "nil")")
            await sleep(0.8)
            capture(win, "01-gestionnaire-tunnels")
            feature.isManagerPresented = false
            check("gestionnaire_ferme_libere_feuille", await wait(5) { model.activeFeatureSheet == nil })

            // 4. Refus : port local occupé (le serveur HTTP lui-même), clair et sans effet de bord.
            let busy = TunnelSpec(kind: .local, bindPort: httpPort, destinationHost: "127.0.0.1", destinationPort: 9, name: "occupé")
            let busyState = await feature.start(busy, on: host)
            if case .failed(let m) = busyState {
                check("port_occupe_echec_clair", m.contains("\(httpPort)") && m.contains("déjà utilisé"), m)
            } else { check("port_occupe_echec_clair", false, "\(busyState)") }
            c = await curl(["http://127.0.0.1:\(httpPort)/"])
            check("port_occupe_serveur_intact", c.out == body)

            // 5. Arrêt effectif d'un tunnel (SOCKS), puis réouverture.
            check("dynamic_arret", await feature.stop(d, on: host) == .stopped)
            let dClosed = await isClosed(d.bindPort)
            check("dynamic_port_ferme", dClosed)
            check("dynamic_reouvert", await feature.start(d, on: host) == .active)
            c = await curl(["--socks5-hostname", "127.0.0.1:\(d.bindPort)", "http://127.0.0.1:\(httpPort)/"])
            check("dynamic_curl_apres_reouverture", c.out == body)

            // 6. Coupure brutale du maître : tunnels marqués arrêtés, puis rétablis seuls à la reconnexion.
            let link = conn.links[0]
            let before = Set([l.id, d.id, r.id, auto.id])
            guard let pid = await link.transport.masterProcessIdentifier else { check("pid_maitre", false); return finish() }
            kill(pid, SIGKILL)
            check("coupure_tunnels_arretes", await wait(15) { before.allSatisfy { feature.state(of: $0) != .active } },
                  "\(before.map { "\(feature.state(of: $0))" })")
            check("reconnexion_lien", await wait(30) { link.state == .connected && link.epoch > 0 }, "\(link.state)")
            check("retablissement_auto", await wait(30) { before.allSatisfy { feature.state(of: $0) == .active } },
                  "\(before.map { "\(feature.state(of: $0))" })")
            c = await curl([url(l)]); check("retabli_local_curl", c.out == body, "status \(c.status)")
            c = await curl(["--socks5-hostname", "127.0.0.1:\(d.bindPort)", "http://127.0.0.1:\(httpPort)/"])
            check("retabli_dynamic_curl", c.out == body, "status \(c.status)")
            c = await curl([url(r)]); check("retabli_remote_curl", c.out == body, "status \(c.status)")
            c = await curl([url(auto)]); check("retabli_autostart_curl", c.out == body, "status \(c.status)")
            await sleep(0.3)
            capture(win, "02-apres-retablissement")

            // 7. Fermeture du dernier onglet : les tunnels retiennent la connexion.
            model.close(tab)
            await sleep(model.connections.graceDelay + 1.5)
            c = await curl([url(l)])
            check("tunnels_survivent_a_la_fermeture_de_l_onglet", c.out == body, "status \(c.status)")

            // 8. Tout arrêter : plus aucun port ouvert, connexion relâchée.
            await feature.stopAll(on: host)
            check("tout_arrete_etats", host.tunnels.allSatisfy { feature.state(of: $0.id) == .stopped })
            let c1 = await isClosed(l.bindPort), c2 = await isClosed(auto.bindPort), c3 = await isClosed(r.bindPort)
            check("tout_arrete_ports_fermes", c1 && c2 && c3, "\(c1) \(c2) \(c3)")
            check("lien_relache_puis_ferme", await wait(10) { conn.links.allSatisfy { $0.isDead } }, "\(conn.state)")
            return finish()
        }
    }
}
