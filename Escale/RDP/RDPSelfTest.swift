import Foundation
import Darwin
import EscaleCore

/// Scénario `--selftest-rdp <dossier>` : écrit `<dossier>/result.json` (ok, checks, failed, details).
///
/// Sans client RDP réel ni serveur Windows : le localisateur et le lanceur du module sont remplacés (le « lanceur » enregistre
/// l'URL du `.rdp` au lieu de lancer une app) et `scripts/selftest-rdp.sh` fournit un serveur TCP factice qui joue le port RDP
/// (ESCALE_RDPTEST_PORT) ainsi qu'un hôte SSH « Relais SSH » (sshd local) dans la bibliothèque. Piloté par l'API interne uniquement.
@MainActor
final class RDPSelfTest {
    let directory: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []

    /// Identifiants de bundle demandés au localisateur (appelé hors acteur : verrou).
    private final class AskedBox: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return v }
    }

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-rdp] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }

    /// Envoie `send` au port local puis lit la réponse (nil : connexion impossible ou délai dépassé).
    private nonisolated static func exchange(port: Int, send: String?, expect: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_port = UInt16(port).bigEndian
        let c = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard c == 0 else { return nil }
        if let send { _ = send.withCString { Darwin.send(fd, $0, strlen($0), 0) } }
        var got = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        while !String(decoding: got, as: UTF8.self).contains(expect) {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        return String(decoding: got, as: UTF8.self)
    }
    private func exchange(port: Int, send: String? = nil, expect: String) async -> String? {
        await Task.detached { Self.exchange(port: port, send: send, expect: expect) }.value
    }

    private func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? -1 }

    func run() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        let feature = model.rdp
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        feature.workParent = URL(fileURLWithPath: directory).appendingPathComponent("rdp-cache", isDirectory: true)

        let fakeApp = URL(fileURLWithPath: "/Applications/Faux Client RDP.app")
        var launched: [(file: URL, app: URL, content: String)] = []
        var failNext = false
        feature.launcher = { file, app in
            if failNext { throw RDPFeatureError.invalid("échec simulé du lancement") }
            launched.append((file, app, (try? String(contentsOf: file, encoding: .utf8)) ?? ""))
        }

        let fakePort = Int(env["ESCALE_RDPTEST_PORT"] ?? "") ?? 0
        let relay = model.library.library.hosts.first { $0.name == "Relais SSH" }
        check("env_serveur_factice", fakePort > 0, "port \(fakePort)")
        check("env_relais_ssh_present", relay != nil)
        guard fakePort > 0, let relay else { return finish() }

        // 1. Client absent : alerte (feuille de module déclarée), aucun fichier, aucun tunnel.
        feature.locator = RDPClientLocator { _ in [] }
        let direct = HostProfile(name: "Bureau direct", host: "rdp.example.test", port: 3390, user: "CORP\\alice",
                                 connectionProtocol: .rdp, rdp: RDPSettings(multiMonitor: true, sharedFolders: ["/Users/test/Partage"]))
        model.openExternal(direct) // chemin réel : externalOpeners[.rdp] -> alerte
        for _ in 0..<100 where feature.notice == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("absent_alerte_client", feature.notice?.kind == .clientMissing, feature.notice?.title ?? "nil")
        check("absent_feuille_declaree", model.activeFeatureSheet == RDPFeature.sheetID, model.activeFeatureSheet ?? "nil")
        check("absent_aucun_lancement_ni_dossier", launched.isEmpty && feature.workDirectory == nil)
        check("absent_url_app_store", RDPClientLocator.appStoreURL.absoluteString == "https://apps.apple.com/app/windows-app/id1295203466")
        feature.notice = nil
        check("absent_feuille_liberee", model.activeFeatureSheet == nil)

        // 2. Client présent, connexion directe.
        let askedBox = AskedBox()
        feature.locator = RDPClientLocator { id in askedBox.add(id); return [fakeApp] }
        model.openExternal(direct)
        for _ in 0..<100 where launched.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        let asked = askedBox.values
        check("direct_lance_avec_client_detecte", launched.count == 1 && launched[0].app == fakeApp && asked == ["com.microsoft.rdc.macos"], "\(asked)")
        let c1 = launched.first?.content ?? ""
        let l1 = c1.components(separatedBy: "\r\n")
        check("direct_adresse", l1.contains("full address:s:rdp.example.test:3390"), c1)
        check("direct_utilisateur", l1.contains("username:s:CORP\\alice"))
        check("direct_options", l1.contains("screen mode id:i:2") && l1.contains("use multimon:i:1") && l1.contains("redirectclipboard:i:1")
              && l1.contains("audiomode:i:0") && l1.contains("drivestoredirect:s:/Users/test/Partage") && l1.contains("prompt for credentials:i:1"))
        check("direct_aucun_mot_de_passe", !c1.lowercased().contains("password"))
        let dir = feature.workDirectory
        check("direct_dossier_prive_0700", dir.map { mode($0) == 0o700 } == true && dir?.path.hasPrefix(feature.workParent.path) == true, "\(dir?.path ?? "nil")")
        check("direct_fichier_0600_et_extension", launched.first.map { mode($0.file) == 0o600 && $0.file.pathExtension == "rdp" && $0.file.deletingLastPathComponent() == dir } == true)
        check("direct_aucun_tunnel", feature.tunnelPorts.isEmpty)

        // 3. Injection de clé refusée : aucun lancement.
        let before = launched.count
        let evil = HostProfile(name: "Pirate", host: "rdp.example.test", user: "bob\r\ndrivestoredirect:s:*", connectionProtocol: .rdp, rdp: RDPSettings())
        var evilError = ""
        do { _ = try await feature.open(evil) } catch { evilError = "\(error)" }
        check("injection_refusee", !evilError.isEmpty && launched.count == before, evilError)

        // 4. Via SSH : tunnel -L ouvert sur le maître, .rdp vers 127.0.0.1:<port local>, serveur factice atteint à travers ssh.
        let via = HostProfile(name: "Bureau via SSH", host: "127.0.0.1", port: fakePort, user: "bob", connectionProtocol: .rdp,
                              rdp: RDPSettings(displayMode: .fixedSize, width: 1280, height: 720, viaSSHHostID: relay.id))
        var opened: RDPFeature.Opened?
        do { opened = try await feature.open(via) } catch { check("via_ouverture", false, "\(error)") }
        let port = opened?.tunnelPort ?? 0
        check("via_port_local_distinct", port > 0 && port != fakePort, "port \(port)")
        check("via_port_dans_etat", feature.tunnelPorts[via.id] == port)
        let l2 = (opened?.content ?? "").components(separatedBy: "\r\n")
        check("via_adresse_127_0_0_1", l2.contains("full address:s:127.0.0.1:\(port)"), opened?.content ?? "nil")
        check("via_taille_fixe", l2.contains("desktopwidth:i:1280") && l2.contains("desktopheight:i:720") && l2.contains("screen mode id:i:1"))
        check("via_fichier_relu_identique", opened.flatMap { try? String(contentsOf: $0.file, encoding: .utf8) } == opened?.content)
        let conn = model.connections.connection(for: relay)
        check("via_maitre_ssh_connecte", conn.state == .connected, "\(conn.state)")
        if port > 0 {
            let banner = await exchange(port: port, expect: "ESCALE-RDP-FAKE")
            check("via_serveur_factice_atteint_par_ssh", banner?.contains("ESCALE-RDP-FAKE") == true, banner ?? "nil")
            let echo = await exchange(port: port, send: "ping-rdp\n", expect: "ping-rdp")
            check("via_aller_retour", echo?.contains("ping-rdp") == true, echo ?? "nil")
        }
        // Rouvrir : tunnel réutilisé (même port), un lancement de plus.
        let again = try? await feature.open(via)
        check("via_reouverture_reutilise_le_tunnel", again?.tunnelPort == port && launched.count == before + 2, "\(again?.tunnelPort ?? -1)")

        // 5. Fermeture du tunnel : port libre, lien rendu.
        await feature.closeTunnel(hostID: via.id)
        check("fermeture_etat_vide", feature.tunnelPorts[via.id] == nil)
        check("fermeture_port_libere", port > 0 && TunnelPortCheck.isFree(address: "127.0.0.1", port: port))
        let refused = port > 0 ? await exchange(port: port, expect: "x") : "x"
        check("fermeture_connexion_refusee", refused == nil, refused ?? "nil")
        check("fermeture_lien_rendu", conn.tabCount == 0, "tabCount \(conn.tabCount)")

        // 6. Échec du lancement après ouverture d'un tunnel : tunnel refermé.
        failNext = true
        var failMsg = ""
        do { _ = try await feature.open(via) } catch { failMsg = "\(error)" }
        failNext = false
        check("echec_lancement_signale", failMsg.contains("échec simulé"), failMsg)
        check("echec_lancement_tunnel_ferme", feature.tunnelPorts.isEmpty && conn.tabCount == 0, "\(feature.tunnelPorts) tabCount \(conn.tabCount)")

        // 7. Hôte SSH intermédiaire absent : erreur explicite, aucun tunnel, alerte via le chemin UI.
        let ghost = HostProfile(name: "Bureau fantôme", host: "127.0.0.1", port: fakePort, connectionProtocol: .rdp, rdp: RDPSettings(viaSSHHostID: UUID()))
        var ghostMsg = ""
        do { _ = try await feature.open(ghost) } catch { ghostMsg = "\(error)" }
        check("fantome_erreur_explicite", ghostMsg.contains("intermédiaire"), ghostMsg)
        await feature.openFromUI(ghost)
        check("fantome_alerte", feature.notice?.kind == .error && feature.notice?.message.contains("intermédiaire") == true)
        feature.notice = nil
        check("fantome_aucun_tunnel", feature.tunnelPorts.isEmpty && conn.tabCount == 0)

        // 8. Export et import (aucun mot de passe repris du fichier importé).
        let exported = URL(fileURLWithPath: directory).appendingPathComponent("export.rdp")
        let exportedContent = try? feature.export(direct, to: exported)
        check("export_fichier", exportedContent != nil && (try? String(contentsOf: exported, encoding: .utf8)) == exportedContent
              && exportedContent?.contains("full address:s:rdp.example.test:3390") == true)
        let foreign = URL(fileURLWithPath: directory).appendingPathComponent("Serveur compta.rdp")
        let foreignText = "full address:s:compta.example.test:3391\r\nusername:s:marie\r\npassword 51:b:SECRETBLOB0123\r\nscreen mode id:i:2\r\nuse multimon:i:1\r\naudiomode:i:2\r\n"
        try? foreignText.write(to: foreign, atomically: true, encoding: .utf8)
        let imported = try? feature.importFile(foreign)
        let inLib = model.library.library.hosts.first { $0.name == "Serveur compta" }
        check("import_hote_ajoute", inLib?.host == "compta.example.test" && inLib?.port == 3391 && inLib?.user == "marie" && inLib?.connectionProtocol == .rdp,
              "\(String(describing: inLib?.host))")
        check("import_reglages", inLib?.rdp?.multiMonitor == true && inLib?.rdp?.audio == RDPSettings.AudioMode.none && inLib?.rdp?.displayMode == .fullScreen)
        check("import_mot_de_passe_ignore", imported?.warnings.contains { $0.contains("Mot de passe") } == true
              && !(inLib.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? "SECRETBLOB").contains("SECRETBLOB"))

        // 9. Aucun mot de passe dans aucun fichier produit ; nettoyage à la sortie.
        var secrets = false
        if let dir, let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for n in names { if let t = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8), t.lowercased().contains("password") { secrets = true } }
        }
        check("aucun_mot_de_passe_dans_les_rdp", !secrets)
        await feature.shutdown()
        check("sortie_dossier_prive_supprime", dir.map { !fm.fileExists(atPath: $0.path) } == true && feature.workDirectory == nil)
        check("sortie_aucun_tunnel", feature.tunnelPorts.isEmpty)
        return finish()
    }

    private func finish() -> Bool {
        let failed = checks.filter { !$0.1 }.map { $0.0 }
        let ok = failed.isEmpty && !checks.isEmpty
        let r: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }),
            "failed": failed,
            "details": Dictionary(uniqueKeysWithValues: checks.filter { !$0.2.isEmpty }.map { ($0.0, $0.2) }),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
        }
        return ok
    }
}
