import Foundation
import Testing
@testable import EscaleCore

// Imbriqué dans la suite PTY (sérialisée) : son test de fuite compte les pty du processus entier,
// aucun autre test ne doit donc en ouvrir en parallèle.
extension PTYProcessTests {
    /// Assemblage des trois briques contre un sshd local : un shell interactif dans un pty,
    /// le client SFTP et un second shell partagent UNE connexion authentifiée.
    @Suite("Assemblage SSH + PTY + SFTP", .enabled(if: LocalSSHD.isAvailable, "sshd local non privilégié indisponible sur cet hôte"), .serialized)
    struct Assemblage {
        /// Accumule la sortie d'un pty et attend une sous-chaîne.
        private final class Sortie: @unchecked Sendable {
            private let lock = NSLock()
            private var buf = Data()
            init(_ p: PTYProcess) {
                Task { [self] in for await d in p.output { lock.withLock { buf.append(d) } } }
            }
            var texte: String { lock.withLock { String(decoding: buf, as: UTF8.self) } }
            func attend(_ s: String, _ delai: Double = 10) async -> Bool {
                let fin = Date().addingTimeInterval(delai)
                while Date() < fin {
                    if texte.contains(s) { return true }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return texte.contains(s)
            }
        }

        @Test func shellInteractifEtSFTPSurUneSeuleConnexion() async throws {
            try await LocalSSHD.with { d in
                let t = OpenSSHTransport(profile: d.profile(), configuration: .init(ssh: d.sshOptions(), masterReadyTimeout: 15))
                let dossier = FileManager.default.temporaryDirectory.appendingPathComponent("escale-int-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dossier) }
                do {
                    try await t.connect()

                    // 1. Shell interactif distant dans un pty local, comme le fera un onglet.
                    let cmd = try await t.shellCommand()
                    var env = cmd.environment
                    env["TERM"] = "xterm-256color"
                    let pty = try PTYProcess(executable: cmd.executable, arguments: cmd.arguments, environment: env, columns: 97, rows: 31)
                    let sortie = Sortie(pty)
                    // Le marqueur est calculé par le shell distant : l'écho de la ligne tapée ne le contient pas.
                    pty.write(Data("echo PRET-$((40+2))\r".utf8))
                    #expect(await sortie.attend("PRET-42"), "sortie : \(sortie.texte.suffix(300))")

                    // 2. La taille du pty local arrive jusqu'au pty distant, y compris après redimensionnement.
                    pty.write(Data("echo T1 $(stty size) F\r".utf8))
                    #expect(await sortie.attend("T1 31 97 F"), "sortie : \(sortie.texte.suffix(300))")
                    pty.resize(columns: 120, rows: 40)
                    try await Task.sleep(for: .milliseconds(300))
                    pty.write(Data("echo T2 $(stty size) F\r".utf8))
                    #expect(await sortie.attend("T2 40 120 F"), "sortie : \(sortie.texte.suffix(300))")

                    // 3. SFTP sur la même connexion, pendant que le shell est ouvert.
                    let sftp = try await SFTPClient.connect(channel: try await t.openSFTPChannel())
                    let distant = dossier.path
                    let source = dossier.appendingPathComponent("envoi été 🚀.bin")
                    var octets = Data(count: 3 * 1024 * 1024)
                    octets.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
                    try octets.write(to: source)
                    _ = try await sftp.upload(localURL: source, to: "\(distant)/reçu.bin", progress: { _ in })
                    let retour = dossier.appendingPathComponent("retour.bin")
                    _ = try await sftp.download(remotePath: "\(distant)/reçu.bin", to: retour, progress: { _ in })
                    #expect(try Data(contentsOf: retour) == octets)

                    // 4. Le shell voit le fichier déposé par SFTP (même machine distante, même session vivante).
                    pty.write(Data("ls '\(distant)' | grep -c bin | sed 's/^ */NB=/'\r".utf8))
                    #expect(await sortie.attend("NB=3"), "sortie : \(sortie.texte.suffix(300))")
                    let noms = try await sftp.listDirectory(distant).map(\.name)
                    #expect(noms.contains("reçu.bin") && noms.contains("envoi été 🚀.bin"))

                    // 5. Une seule authentification côté serveur pour le maître, le shell et SFTP.
                    #expect(d.acceptedAuthenticationCount() == 1, "journal sshd : \(d.log().suffix(600))")
                    #expect(await t.sessionCount == 2)

                    // 6. Fin propre du shell : code de sortie distant propagé.
                    await sftp.close()
                    pty.write(Data("exit 5\r".utf8))
                    let garde = Task { try? await Task.sleep(for: .seconds(10)); pty.kill() }
                    let statut = await pty.waitForExit()
                    garde.cancel()
                    #expect(statut == .exited(5))
                    await t.shellSessionDidEnd()
                    await t.disconnect()
                } catch {
                    await t.disconnect()
                    throw error
                }
            }
        }
    }
}
