import AppKit
import Darwin
import Foundation
import EscaleCore

/// Scénario `--selftest-serial <dossier>` : écrit `<dossier>/result.json` (ok, checks, failed, details).
///
/// Un pty fait office de port : son maître est l'appareil simulé, tenu par le scénario ; l'esclave est le chemin de
/// l'hôte série enregistré dans la bibliothèque temporaire (`--library`). L'onglet est ouvert par `model.connect`
/// et l'écran du terminal est lu par `TerminalEngine.text`. Aucune saisie globale, aucune boîte de dialogue.
@MainActor
final class SerialSelfTest {
    let directory: String
    let model: AppModel
    private var checks: [(String, Bool)] = []
    private var details: [String: String] = [:]

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok))
        if !detail.isEmpty { details[name] = detail }
        FileHandle.standardError.write(Data("[selftest-serial] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 8, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 40_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Appareil simulé : maître d'un pty.
    private final class Device {
        var master: Int32 = -1
        var slavePath = ""
        func open() -> Bool {
            var m: Int32 = -1, s: Int32 = -1
            var name = [CChar](repeating: 0, count: 128)
            guard openpty(&m, &s, &name, nil, nil) == 0 else { return false }
            close(s)
            _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK)
            master = m; slavePath = String(cString: name); return true
        }
        func send(_ s: String) { let b = Array(s.utf8); _ = write(master, b, b.count) }
        func drain() -> [UInt8] {
            var out = [UInt8](); var buf = [UInt8](repeating: 0, count: 512)
            while true { let n = read(master, &buf, buf.count); if n > 0 { out += buf[0..<n] } else { break } }
            return out
        }
        func shutdown() { if master >= 0 { close(master); master = -1 } }
    }

    func run() async -> Bool {
        let dev = Device()
        guard dev.open() else { check("pty_cree", false, "openpty a échoué"); return finish() }
        check("pty_cree", true, dev.slavePath)

        let host = HostProfile(name: "Série recette", host: dev.slavePath, connectionProtocol: .serial,
                               serial: SerialSettings(devicePath: dev.slavePath, baudRate: 9600, dataBits: 8, parity: .none,
                                                      stopBits: 1, flowControl: .none, localEcho: false, lineEnding: .crlf))
        model.library.upsert(host)
        check("hote_en_bibliotheque", model.library.library.hosts.contains { $0.id == host.id && $0.serial?.lineEnding == .crlf })

        // --- Ouverture par model.connect
        model.connect(host)
        guard let tab = model.workspace.tabs(forHost: host.id).first else { check("onglet_ouvert", false); return finish() }
        let pane = tab.activePane
        check("onglet_ouvert", await wait { pane.status == .running }, "\(pane.status)")
        check("session_en_cours", await wait { pane.session.state == .running })
        check("port_detecte_par_menu", model.serial.openPort(forHost: host.id) != nil)

        // --- Octets de l'appareil affichés dans le terminal
        dev.send("Bonjour depuis l'appareil\r\nLigne 2\r\n")
        let shown = await wait { pane.session.engine.text(includingScrollback: true).contains("Ligne 2") }
        let screen = pane.session.engine.text(includingScrollback: true)
        check("octets_appareil_affiches", shown && screen.contains("Bonjour depuis l'appareil"), screen.trimmingCharacters(in: .whitespacesAndNewlines))

        // --- Saisie transmise, Entrée (CR du moteur) converti en CRLF
        _ = dev.drain()
        pane.session.engine.sendInput(Data("version\r".utf8))
        var received = [UInt8]()
        _ = await wait { received += dev.drain(); return received.count >= 9 }
        check("saisie_transmise_crlf", received == Array("version\r\n".utf8), "\(received.map { String(format: "%02x", $0) }.joined())")

        // --- BREAK
        let port = model.serial.openPort(forHost: host.id)
        _ = dev.drain()
        let breakSent = port?.sendBreak() ?? false
        check("break_envoye", breakSent)
        await sleep(0.5)
        let afterBreak = dev.drain()
        // Un pty ne transporte pas le BREAK (aucun octet, aucun signal côté maître) : réception non vérifiable ici.
        details["break_recu_cote_appareil"] = "non verifiable sur un pty (octets cote maitre : \(afterBreak.count))"

        // --- DTR/RTS : un pty peut refuser les ioctl de lignes de modem
        let dtr = port?.toggleLine(.dtr)
        details["dtr_rts"] = "toggle DTR sur pty : \(dtr.map(String.init(describing:)) ?? "refuse (non verifiable sur pty)")"

        // --- Second onglet sur le même port : occupé
        let tab2 = model.newTab(host)
        let busy = await wait { if case .failed = tab2.activePane.status { true } else { false } }
        var msg = ""
        if case .failed(let m) = tab2.activePane.status { msg = m }
        check("second_onglet_occupe", busy && msg.contains("occupé"), msg)
        check("premier_onglet_intact", pane.status == .running)
        model.close(tab2)

        // --- Chemin absent : erreur lisible
        let ghost = HostProfile(name: "Série absente", host: "/dev/cu.escale-absent", connectionProtocol: .serial,
                                serial: SerialSettings(devicePath: "/dev/cu.escale-absent"))
        model.library.upsert(ghost)
        let tab3 = model.newTab(ghost)
        _ = await wait { if case .failed = tab3.activePane.status { true } else { false } }
        var msg3 = ""
        if case .failed(let m) = tab3.activePane.status { msg3 = m }
        check("port_absent_introuvable", msg3.contains("introuvable"), msg3)
        model.close(tab3)

        // --- Déconnexion de l'appareil
        dev.shutdown()
        let ended = await wait { if case .ended = pane.status { true } else { false } }
        check("deconnexion_statut_ended", ended, "\(pane.status)")
        check("deconnexion_code_perte", pane.status == .ended(.exited(SerialPort.deviceLostExitCode)), "\(pane.status)")
        let tail = pane.session.engine.text(includingScrollback: true)
        check("deconnexion_message_ecran", tail.contains("déconnecté"), tail.split(separator: "\n").last.map(String.init) ?? "")
        check("menu_desactive_apres_deconnexion", model.serial.openPort(forHost: host.id) == nil)

        model.close(tab)
        return finish()
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy(\.1)
        let payload: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "details": details,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
        }
        return ok
    }
}
