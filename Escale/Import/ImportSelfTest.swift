import AppKit
import CryptoKit
import Foundation
import EscaleCore

/// `--selftest-import <dossier>` : importe les 3 fixtures (MobaXterm cp1252, PuTTY UTF-16LE, CSV) dans une bibliothèque
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
        let names = ["moba.mxtsessions", "putty.reg", "hosts.csv"]
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
        check("moba_4_sessions_ssh", moba?.sessions.count == 4, "\(moba?.sessions.map(\.name) ?? [])")
        check("moba_unicode_cp1252", moba?.sessions.contains { $0.name == "Web prod é €" } == true)
        check("moba_doublons_decoches", moba?.existing.count == 2 && moba?.selected.count == 2, "cochées \(moba?.selected.count ?? -1)")
        check("moba_mots_de_passe_ignores", moba?.passwordNotice == "2 mots de passe non importés", moba?.passwordNotice ?? "nil")
        check("moba_avertissements_ppk_telnet", moba?.warnings.contains { $0.contains(".ppk") } == true
              && moba?.warnings.contains { $0.contains("Switch coeur") } == true)
        let r1 = moba?.commit()
        check("moba_ajout_2", r1?.added.map(\.name).sorted() == ["DB réplica", "Maison NAS"], "\(r1?.added.map(\.name) ?? [])")
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
        check("putty_3_sessions_ssh", Set(putty?.sessions.map(\.name) ?? []) == ["Serveur Web été", "DB", "Derriere proxy"],
              "\(putty?.sessions.map(\.name) ?? [])")
        check("putty_mot_de_passe_proxy_ignore", putty?.passwordNotice == "1 mot de passe non importé")
        check("putty_ppk_et_telnet_signales", putty?.warnings.contains { $0.contains("web.ppk") } == true
              && putty?.warnings.contains { $0.contains("telnet") } == true)
        let r2 = putty?.commit()
        let web = lib.library.hosts.first { $0.host == "web.example.com" }
        check("putty_tunnels_x11", web?.tunnels.map(\.kind) == [.local, .remote, .dynamic, .local] && web?.x11Forwarding == true,
              "\(web?.tunnels.map(\.specArgument) ?? [])")
        check("putty_user_dans_hote", lib.library.hosts.contains { $0.host == "10.0.0.5" && $0.user == "admin" && $0.port == 2222 })
        check("putty_ajout_3", r2?.added.count == 3)
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

        // --- Bilan bibliothèque, disque, sources, secrets
        await lib.flush()
        check("bibliotheque_9_hotes", lib.library.hosts.count == 9, "\(lib.library.hosts.count)")
        check("aucun_secret_dans_les_profils", lib.library.hosts.allSatisfy { $0.auth == .openSSHDefaults || { if case .keyFile = $0.auth { true } else { false } }($0) })
        let libPath = model.options.libraryPath ?? ""
        let onDisk = try? await FileHostRepository(url: URL(fileURLWithPath: libPath)).load()
        check("ecrit_sur_disque", onDisk?.hosts.count == 9 && onDisk?.folders.count == lib.library.folders.count)
        let raw = (try? String(contentsOfFile: libPath, encoding: .utf8)) ?? ""
        check("aucun_mot_de_passe_sur_disque", !raw.isEmpty && !["s3cret", "hunter2", "p,ass", "encrypted"].contains { raw.contains($0) })
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
