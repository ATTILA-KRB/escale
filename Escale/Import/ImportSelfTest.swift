import AppKit
import CryptoKit
import Foundation
import EscaleCore

/// `--selftest-import <dossier>` : importe les fixtures (MobaXterm cp1252, PuTTY UTF-16LE, CSV, Termius, et sessions Telnet/série/VNC/RDP) dans une bibliothèque
/// temporaire (`--library`) sans interaction (pas de NSOpenPanel : `ImportFeature.open` + modèle de feuille), vérifie le
/// contenu de la bibliothèque (mémoire et disque), que les sources sont inchangées et qu'aucun mot de passe n'a fuité.
/// Fixtures : `ESCALE_IMPORTTEST_FIXTURES` (posé par scripts/selftest-import.sh), sinon `<dossier>/fixtures`.
/// Écrit `result.json` dans le dossier.
@MainActor
struct ImportSelfTest {
    let directory: String
    let model: AppModel

    private final class Log { var checks: [(String, Bool, String)] = [] }

    func run() async -> Bool {
        let log = Log()
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log.checks.append((name, ok, detail))
            FileHandle.standardError.write(Data("[selftest-import] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
        }
        let fixtures = ProcessInfo.processInfo.environment["ESCALE_IMPORTTEST_FIXTURES"] ?? "\(directory)/fixtures"
        func url(_ n: String) -> URL { URL(fileURLWithPath: "\(fixtures)/\(n)") }
        func sha(_ n: String) -> String? {
            (try? Data(contentsOf: url(n))).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
        let names = ["moba.mxtsessions", "putty.reg", "hosts.csv", "MobaXterm.ini", "moba-protocols.mxtsessions", "putty-protocols.reg", "termius.csv"]
        let before = names.map(sha)
        check("fixtures_presentes", !before.contains { $0 == nil }, fixtures)
        guard !before.contains(where: { $0 == nil }) else { return finish(log) }

        let lib = model.library
        let feature = model.imports
        // Bibliothèque préexistante : un hôte qui doublonne (web1/deploy) et un dossier « Production » à réutiliser.
        let production = lib.addFolder(name: "Production", parentID: nil)
        lib.upsert(HostProfile(name: "web1 existant", host: "web1.example.com", user: "deploy"))
        let target = lib.addFolder(name: "Importés", parentID: nil)

        // --- MobaXterm (Windows-1252)
        let moba = feature.open(url("moba.mxtsessions"), kind: .mobaXterm)
        check("moba_feuille_ouverte", moba != nil && feature.pending === moba && model.activeFeatureSheet == "import")
        check("moba_5_sessions_dont_telnet", moba?.sessions.count == 5, "\(moba?.sessions.map(\.name) ?? [])")
        check("moba_unicode_cp1252", moba?.sessions.contains { $0.name == "Web prod é €" } == true)
        check("moba_doublons_decoches", moba?.existing.count == 2 && moba?.selected.count == 3, "cochées \(moba?.selected.count ?? -1)")
        check("moba_mots_de_passe_ignores", moba?.passwordNotice == "2 mots de passe non importés", moba?.passwordNotice ?? "nil")
        check("moba_avertissement_ppk", moba?.warnings.contains { $0.contains(".ppk") } == true)
        check("moba_telnet_importe", moba?.sessions.first { $0.name == "Switch coeur" }?.connectionProtocol == .telnet)
        let r1 = moba?.commit()
        check("moba_commande_connexion", moba?.sessions.first { $0.name == "Maison NAS" }?.startupCommand == "uptime; df -h")
        check("moba_ajout_3", r1?.added.map(\.name).sorted() == ["DB réplica", "Maison NAS", "Switch coeur"], "\(r1?.added.map(\.name) ?? [])")
        let db = r1?.added.first { $0.name == "DB réplica" }
        check("moba_dossiers_imbriques", db.map { lib.library.folderPath(of: $0.folderID ?? UUID()).map(\.name) } == ["Production", "Base de données"])
        check("moba_dossier_existant_reutilise", lib.library.folders.filter { $0.name == "Production" }.count == 1
              && lib.library.folderPath(of: db?.folderID ?? UUID()).first?.id == production?.id)
        feature.close()
        check("moba_feuille_fermee", feature.pending == nil && model.activeFeatureSheet == nil)

        // Réimport : plus rien de nouveau.
        let again = feature.open(url("moba.mxtsessions"), kind: .mobaXterm)
        check("moba_reimport_tout_grise", again?.importableCount == 0 && again?.selected.isEmpty == true)
        feature.close()

        // --- PuTTY (UTF-16LE + BOM)
        let putty = feature.open(url("putty.reg"), kind: .putty)
        check("putty_4_sessions_dont_telnet", Set(putty?.sessions.map(\.name) ?? []) == ["Serveur Web été", "DB", "Derriere proxy", "Routeur Telnet"],
              "\(putty?.sessions.map(\.name) ?? [])")
        check("putty_mot_de_passe_proxy_ignore", putty?.passwordNotice == "1 mot de passe non importé")
        check("putty_ppk_signale", putty?.warnings.contains { $0.contains("web.ppk") } == true)
        let r2 = putty?.commit()
        let web = lib.library.hosts.first { $0.host == "web.example.com" }
        check("putty_tunnels_x11", web?.tunnels.map(\.kind) == [.local, .remote, .dynamic, .local] && web?.x11Forwarding == true,
              "\(web?.tunnels.map(\.specArgument) ?? [])")
        check("putty_user_dans_hote", lib.library.hosts.contains { $0.host == "10.0.0.5" && $0.user == "admin" && $0.port == 2222 })
        check("putty_ajout_4", r2?.added.count == 4)
        check("putty_remotecommand", web?.startupCommand == "tmux attach || tmux new -s main", web?.startupCommand ?? "nil")
        let proxied = lib.library.hosts.first { $0.host == "inner.example.com" }
        check("putty_proxy_ssh_vers_jumphost", proxied?.jumpHosts == ["jump@10.0.0.5:2222"], "\(proxied?.jumpHosts ?? [])")
        feature.close()

        // --- MobaXterm.ini : tunnels ([SSH_Tunnels]) + commande de connexion
        let ini = feature.open(url("MobaXterm.ini"), kind: .mobaXterm)
        check("ini_1_session", ini?.sessions.count == 1, "\(ini?.sessions.map(\.name) ?? [])")
        check("ini_3_tunnels_rattaches", ini?.sessions.first?.tunnels.map(\.kind) == [.local, .dynamic, .remote], "\(ini?.sessions.first?.tunnels.map(\.specArgument) ?? [])")
        check("ini_avertissements_tunnels", ini?.warnings.contains { $0.contains("Orphelin") } == true && ini?.warnings.contains { $0.contains("Cassé") } == true,
              "\(ini?.warnings ?? [])")
        let r4 = ini?.commit()
        let bastion = r4?.added.first
        check("ini_hote_importe_avec_tunnels_et_commande", bastion?.tunnels.count == 3 && bastion?.startupCommand == "sudo -iu postgres; psql -c 'select 1%'",
              bastion?.startupCommand ?? "nil")
        feature.close()

        // --- CSV vers le dossier « Importés »
        let csv = feature.open(url("hosts.csv"), kind: .csv, folder: target?.id)
        check("csv_5_lignes", csv?.sessions.count == 5)
        check("csv_doublons_web1_decoches", csv?.existing.count == 2 && csv?.selected.count == 3)
        check("csv_mot_de_passe_ignore", csv?.passwordNotice == "1 mot de passe non importé")
        check("csv_avertissement_port", csv?.warnings.contains { $0.contains("abc") } == true)
        let r3 = csv?.commit()
        let cafe = r3?.added.first { $0.name == "Café Müller" }
        check("csv_unicode_dossier_sous_cible", cafe.map { lib.library.folderPath(of: $0.folderID ?? UUID()).map(\.name) } == ["Importés", "Clients", "Café"]
              && cafe?.user == "zoé" && cafe?.tags == ["client", "vip"])
        feature.close()

        // --- MobaXterm : Telnet, RDP, VNC, série
        let mp = feature.open(url("moba-protocols.mxtsessions"), kind: .mobaXterm)
        check("mobap_7_sessions", mp?.sessions.count == 7, "\(mp?.sessions.map(\.name) ?? [])")
        check("mobap_ftp_mosh_ignores", mp?.warnings.filter { $0.contains("ignoré") }.count == 2, "\(mp?.warnings ?? [])")
        check("mobap_avertissement_port_com", mp?.warnings.contains { $0.contains("choisir le port") } == true)
        let mpr = mp?.commit()
        func added(_ n: String) -> HostProfile? { mpr?.added.first { $0.name == n } }
        check("mobap_telnet", added("Telnet port custom").map { $0.connectionProtocol == .telnet && $0.port == 2323 && $0.user == "ops" && $0.telnet != nil } == true)
        check("mobap_rdp", added("Bureau Windows").map { $0.connectionProtocol == .rdp && $0.port == 3390 && $0.user == "administrateur" && $0.rdp != nil } == true)
        check("mobap_vnc", added("Ecran VNC").map { $0.connectionProtocol == .vnc && $0.port == 5901 && $0.vnc != nil } == true)
        check("mobap_serie_com_sans_peripherique", added("Console COM").map { $0.connectionProtocol == .serial && $0.serial?.devicePath == "" && $0.serial?.baudRate == 115_200 } == true)
        check("mobap_serie_dev", added("Console 9600").map { $0.serial?.devicePath == "/dev/ttyUSB0" && $0.serial?.baudRate == 9_600 && $0.host == "/dev/ttyUSB0" } == true)
        check("mobap_ajout_7", mpr?.added.count == 7, "\(mpr?.added.count ?? -1)")
        feature.close()
        let mpAgain = feature.open(url("moba-protocols.mxtsessions"), kind: .mobaXterm)
        check("mobap_reimport_tout_grise", mpAgain?.importableCount == 0)
        feature.close()

        // --- PuTTY : Telnet et série
        let pp = feature.open(url("putty-protocols.reg"), kind: .putty)
        check("puttyp_4_sessions", Set(pp?.sessions.map(\.name) ?? []) == ["Routeur Telnet", "Telnet autre port", "Console Windows", "Console Mac"], "\(pp?.sessions.map(\.name) ?? [])")
        check("puttyp_raw_rlogin_ignores", pp?.warnings.filter { $0.contains("raw") || $0.contains("rlogin") }.count == 2, "\(pp?.warnings ?? [])")
        let ppr = pp?.commit()
        let mac = ppr?.added.first { $0.name == "Console Mac" }
        check("puttyp_serie_parametres", mac?.serial == SerialSettings(devicePath: "/dev/cu.usbserial-1410", baudRate: 9_600, dataBits: 8, parity: .none, stopBits: 1, flowControl: .hardware), "\(String(describing: mac?.serial))")
        let wincom = ppr?.added.first { $0.name == "Console Windows" }
        check("puttyp_serie_com_7e2", wincom.map { $0.serial?.devicePath == "" && $0.serial?.dataBits == 7 && $0.serial?.parity == .even && $0.serial?.stopBits == 2 } == true)
        check("puttyp_telnet", ppr?.added.first { $0.name == "Telnet autre port" }.map { $0.connectionProtocol == .telnet && $0.port == 2586 } == true)
        feature.close()

        // --- Termius (CSV du modèle d'import)
        let term = feature.open(url("termius.csv"), kind: .termius, folder: target?.id)
        check("termius_5_sessions", term?.sessions.count == 5, "\(term?.sessions.map(\.name) ?? [])")
        check("termius_mot_de_passe_ignore", term?.passwordNotice == "1 mot de passe non importé", term?.passwordNotice ?? "nil")
        check("termius_avertissements_mosh_ftp", term?.warnings.contains { $0.contains("Mosh") } == true && term?.warnings.contains { $0.contains("ftp") } == true)
        let tr = term?.commit()
        let web1 = tr?.added.first { $0.name == "web-01" }
        check("termius_groupes_tags_sous_cible", web1.map { lib.library.folderPath(of: $0.folderID ?? UUID()).map(\.name) == ["Importés", "Production", "Web"] && $0.tags == ["prod", "nginx"] } == true)
        check("termius_telnet", tr?.added.first { $0.name == "Routeur labo" }.map { $0.connectionProtocol == .telnet && $0.user == "admin" && $0.telnet != nil } == true)
        feature.close()

        // --- Bilan bibliothèque, disque, sources, secrets
        await lib.flush()
        check("bibliotheque_28_hotes", lib.library.hosts.count == 28, "\(lib.library.hosts.count)")
        check("aucun_secret_dans_les_profils", lib.library.hosts.allSatisfy { $0.auth == .openSSHDefaults || { if case .keyFile = $0.auth { true } else { false } }($0) })
        let libPath = model.options.libraryPath ?? ""
        let onDisk = try? await FileHostRepository(url: URL(fileURLWithPath: libPath)).load()
        check("ecrit_sur_disque", onDisk?.hosts.count == 28 && onDisk?.folders.count == lib.library.folders.count)
        let raw = (try? String(contentsOfFile: libPath, encoding: .utf8)) ?? ""
        check("serie_et_protocoles_sur_disque", onDisk?.hosts.filter { $0.connectionProtocol == .serial }.count == 4 && onDisk?.hosts.filter { $0.connectionProtocol == .telnet }.count == 7 && onDisk?.hosts.filter { $0.connectionProtocol == .rdp }.count == 2 && onDisk?.hosts.filter { $0.connectionProtocol == .vnc }.count == 1)
        check("aucun_mot_de_passe_sur_disque", !raw.isEmpty && !["s3cret", "hunter2", "p,ass", "encrypted", "t3rm1us"].contains { raw.contains($0) })
        check("sources_inchangees", names.map(sha) == before)
        return finish(log)
    }

    private func finish(_ log: Log) -> Bool {
        let ok = !log.checks.isEmpty && log.checks.allSatisfy(\.1)
        let payload: [String: Any] = [
            "ok": ok,
            "checks": log.checks.map { ["name": $0.0, "ok": $0.1, "detail": $0.2] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: "\(directory)/result.json"))
        }
        return ok
    }
}
