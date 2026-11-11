import AppKit
import Foundation
import EscaleCore

/// Scénario `--selftest-vnc <dossier>` : client RFB réel contre `scripts/fixtures/vnc/rfbserver.py` (lancé par
/// `scripts/selftest-vnc.sh`). Variables : `ESCALE_VNCTEST_PORT`, `ESCALE_VNCTEST_LOG` (journal du serveur),
/// `ESCALE_VNCTEST_PASSWORD` (mot de passe de test). Écrit `result.json` {ok, checks, failed, details} et une capture PNG.
@MainActor
final class VNCSelfTest {
    let directory: String
    let model: AppModel

    private var checks: [String: Bool] = [:]
    private var order: [String] = []
    private var details: [String: String] = [:]

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if checks[name] == nil { order.append(name) }
        checks[name] = ok
        if !detail.isEmpty { details[name] = detail }
        FileHandle.standardError.write(Data("[selftest-vnc] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }

    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    private func serverLog() -> [String] {
        guard let p = ProcessInfo.processInfo.environment["ESCALE_VNCTEST_LOG"],
              let s = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    private func hasLog(_ prefix: String) -> Bool { serverLog().contains { $0.hasPrefix(prefix) } }

    func run() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["ESCALE_VNCTEST_PORT"].flatMap(Int.init), let password = env["ESCALE_VNCTEST_PASSWORD"] else {
            check("environnement", false, "ESCALE_VNCTEST_PORT / ESCALE_VNCTEST_PASSWORD absents")
            return finish()
        }
        let feature = model.vnc
        let host = HostProfile(name: "vnc-test", host: "127.0.0.1", port: port, connectionProtocol: .vnc,
                               vnc: VNCSettings(viewOnly: false, shared: true, encoding: .auto, scaling: .fit))
        model.library.upsert(host)
        guard let session = feature.open(host, activate: false) else { check("ouverture", false); return finish() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.attila-krb.Escale.selftest.vnc.\(getpid())"))
        session.pasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        check("fenetre_ouverte", feature.window(for: host.id) != nil)

        // --- Mauvais mot de passe : la feuille réapparaît avec le message du serveur, rien n'est mémorisé.
        check("demande_mot_de_passe", await wait { session.phase == .needsCredentials })
        session.rememberPassword = false
        session.submitCredentials(password: "mauvais-mot-de-passe")
        let again = await wait { session.promptError != nil && session.phase == .needsCredentials }
        check("mauvais_mot_de_passe_message", again, session.promptError ?? "pas de message")
        check("message_sans_secret", !(session.promptError ?? "").contains("mauvais-mot-de-passe"))
        check("serveur_voit_refus", hasLog("auth fail"))
        let account = VNCSettings.passwordAccount(for: host.id)
        let leaked = try? await model.connections.secretStore.secret(for: account)
        check("rien_memorise_apres_refus", leaked == nil)

        // --- Bon mot de passe : connexion, mémorisation Keychain seulement après succès (invariant 11).
        session.rememberPassword = true
        session.submitCredentials(password: password)
        check("connecte", await wait { session.isConnected }, "\(session.phase)")
        check("serveur_voit_auth_ok", hasLog("auth ok"))
        check("infos_serveur", session.serverInfo?.name == "escale-test" && session.serverInfo?.width == 160 && session.serverInfo?.height == 96,
              "\(String(describing: session.serverInfo))")
        let stored = try? await model.connections.secretStore.secret(for: account)
        check("mot_de_passe_memorise_apres_succes", stored?.string == password)
        check("encodages_annonces", serverLog().contains { $0.hasPrefix("setenc") && $0.contains(" 16") && $0.contains(" 5") && $0.contains(" 1 ") && $0.contains("-239") && $0.contains("-223") }, serverLog().first { $0.hasPrefix("setenc") } ?? "")

        // --- Pixels du motif (Raw, Hextile, ZRLE, CopyRect).
        check("motif_recu", await wait { session.framebuffer?.pixel(x: 10, y: 60) != nil && session.framebuffer?.pixel(x: 10, y: 60)?.g == 200 })
        let fb = session.framebuffer
        func px(_ x: Int, _ y: Int) -> String { fb?.pixel(x: x, y: y).map { "\($0.r),\($0.g),\($0.b)" } ?? "nil" }
        check("raw", px(5, 7) == "15,35,12" && px(79, 47) == "237,235,126", "\(px(5, 7)) \(px(79, 47))")
        check("hextile_fond", px(95, 0) == "10,10,200" && px(150, 20) == "10,10,200", "\(px(95, 0)) \(px(150, 20))")
        check("hextile_sous_rectangle", px(82, 3) == "250,250,0" && px(85, 7) == "250,250,0" && px(87, 3) == "10,10,200", "\(px(82, 3)) \(px(85, 7))")
        check("hextile_tuile_brute", px(150, 5) == "7,77,177" && px(100, 40) == "10,10,200", "\(px(150, 5)) \(px(100, 40))")
        check("zrle_uni", px(10, 60) == "0,200,0" && px(100, 60) == "200,0,200", "\(px(10, 60)) \(px(100, 60))")
        check("zrle_rle", px(140, 90) == "90,90,90" && px(128, 48) == "90,90,90", "\(px(140, 90)) \(px(128, 48))")
        check("copyrect", px(125, 31) == "15,35,12" && px(120, 24) == "0,0,0", "\(px(125, 31)) \(px(120, 24))")

        // --- Affichage : image réellement produite, échelle « ajuster » puis 100 %.
        guard let display = session.display else { check("vue_affichage", false); return finish(session, host) }
        check("image_affichee", await wait { display.currentImage?.width == 160 && display.currentImage?.height == 96 })
        let fit = display.imageRect()
        check("echelle_ajuster", fit.width > 160 && abs(fit.width / fit.height - 160.0 / 96.0) < 0.01, "\(fit)")
        let mapped = display.remotePoint(from: display.viewPoint(forRemoteX: 50, y: 20))
        check("conversion_point", mapped.x == 50 && mapped.y == 20, "\(mapped)")
        session.scaling = .actual
        display.scaling = .actual
        display.layoutSubtreeIfNeeded()
        let actual = display.imageRect()
        check("echelle_100", actual.width == 160 && actual.height == 96, "\(actual)")
        session.scaling = .fit
        display.scaling = .fit
        display.layoutSubtreeIfNeeded()

        // --- Entrées : clavier (AZERTY : « é » vient du caractère produit), souris, presse-papiers.
        let win = feature.window(for: host.id)
        let wn = win?.windowNumber ?? 0
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wn, context: nil,
                                    characters: "é", charactersIgnoringModifiers: "é", isARepeat: false, keyCode: 19) {
            display.keyDown(with: e)
        }
        if let e = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wn, context: nil,
                                    characters: "é", charactersIgnoringModifiers: "é", isARepeat: false, keyCode: 19) {
            display.keyUp(with: e)
        }
        check("clavier_keysym_e_accent", await wait { hasLog("key down 0xe9") && hasLog("key up 0xe9") }, serverLog().suffix(4).joined(separator: " | "))
        let loc = display.convert(display.viewPoint(forRemoteX: 50, y: 20), to: nil)
        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: loc, modifierFlags: [], timestamp: 0, windowNumber: wn, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1) { display.mouseDown(with: e) }
        if let e = NSEvent.mouseEvent(with: .leftMouseUp, location: loc, modifierFlags: [], timestamp: 0, windowNumber: wn, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 0) { display.mouseUp(with: e) }
        check("souris_bouton_gauche", await wait { hasLog("ptr 50 20 1") && hasLog("ptr 50 20 0") }, serverLog().suffix(3).joined(separator: " | "))
        session.sendCtrlAltDelete()
        check("ctrl_alt_suppr", await wait { hasLog("key down 0xffff") }, serverLog().suffix(6).joined(separator: " | "))

        pasteboard.clearContents()
        pasteboard.setString("envoyé-é", forType: .string)
        let sent = session.sendClipboard()
        let received = await wait { hasLog("cut envoy") }
        check("presse_papiers_vers_serveur", sent && received, serverLog().last ?? "")
        session.sendKey(UInt32(Character("c").asciiValue!), down: true)
        session.sendKey(UInt32(Character("c").asciiValue!), down: false)
        check("presse_papiers_depuis_serveur", await wait { pasteboard.string(forType: .string) == "texte-serveur é" }, pasteboard.string(forType: .string) ?? "nil")

        // --- Lecture seule : plus aucune entrée envoyée.
        session.inputEnabled = false
        let before = serverLog().count
        session.sendKey(0x78, down: true)
        session.sendPointer(x: 1, y: 1, buttons: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("lecture_seule", !serverLog().dropFirst(before).contains { $0.hasPrefix("key") || $0.hasPrefix("ptr") })
        session.inputEnabled = true

        // --- Capture de la fenêtre (motif complet, avant le changement de taille).
        win?.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        display.redraw()
        shot(windowNumber: wn)

        // --- Redimensionnement du bureau (DesktopSize puis image pleine).
        session.sendKey(UInt32(Character("z").asciiValue!), down: true)
        session.sendKey(UInt32(Character("z").asciiValue!), down: false)
        check("desktop_size", await wait { session.remoteSize == CGSize(width: 200, height: 120) && session.framebuffer?.width == 200 }, "\(session.remoteSize)")
        check("desktop_size_pixels", await wait { session.framebuffer?.pixel(x: 199, y: 119).map { $0.r == 1 && $0.g == 2 && $0.b == 3 } == true })
        check("image_redimensionnee", await wait { display.currentImage?.width == 200 && display.currentImage?.height == 120 })

        return await finishWithClose(session, host, feature)
    }

    private func shot(windowNumber: Int) {
        let path = "\(directory)/vnc-fenetre.png"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for _ in 0..<4 {
            try? FileManager.default.removeItem(atPath: path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(windowNumber)", path]
            try? p.run(); p.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        var ok = FileManager.default.fileExists(atPath: path)
        if !ok, let display = model.vnc.sessions.values.first?.display, let rep = display.bitmapImageRepForCachingDisplay(in: display.bounds) {
            // Repli : rendu interne de la vue (fenêtre hors du Space actif).
            display.cacheDisplay(in: display.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                ok = true
                details["capture"] = "rendu interne (cacheDisplay)"
            }
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
        check("capture_png", ok && size > 1000, "\(size) octets")
    }

    private func finishWithClose(_ session: VNCSession, _ host: HostProfile, _ feature: VNCFeature) async -> Bool {
        let countBefore = serverLog().filter { $0 == "disconnect" }.count
        await feature.closeWindow(for: host.id)
        check("fermeture_fenetre", feature.window(for: host.id) == nil && feature.sessions[host.id] == nil)
        check("serveur_voit_deconnexion", await wait { serverLog().filter { $0 == "disconnect" }.count > countBefore })
        check("pas_de_secret_dans_les_logs", !serverLog().joined().contains(ProcessInfo.processInfo.environment["ESCALE_VNCTEST_PASSWORD"] ?? "\u{0}"))
        return finish()
    }

    private func finish(_ session: VNCSession, _ host: HostProfile) -> Bool {
        Task { await model.vnc.closeWindow(for: host.id) }
        return finish()
    }

    private func finish() -> Bool {
        let failed = order.filter { checks[$0] != true }
        let ok = !checks.isEmpty && failed.isEmpty
        let payload: [String: Any] = ["ok": ok, "checks": checks, "failed": failed, "details": details]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
        }
        return ok
    }
}
