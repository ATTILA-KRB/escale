import Foundation

/// Réglages X11 appliqués aux lignes ssh d'un hôte dont la redirection est activée.
/// Absents (`nil` dans `OpenSSHOptions.x11`) : aucune option X11 n'est jamais passée à ssh.
public struct X11Settings: Sendable, Equatable {
    /// `ForwardX11Trusted=yes` (équivalent de `-Y`) : le serveur distant a tous les droits sur l'écran local.
    /// Par défaut non : les clients distants passent par l'extension SECURITY (cookie « untrusted »).
    public var trusted: Bool
    /// Chemin de `xauth` (celui de XQuartz : `/opt/X11/bin/xauth`).
    public var xauthPath: String
    /// Valeur de `DISPLAY` à donner à ssh (socket launchd de XQuartz) ; `nil` : hérité de l'environnement.
    public var display: String?
    /// Valeur de `XAUTHORITY` pour ssh (serveur intégré : fichier privé) ; `nil` : héritée (`~/.Xauthority`).
    public var xauthority: String?

    public init(trusted: Bool = false, xauthPath: String, display: String? = nil, xauthority: String? = nil) {
        self.trusted = trusted; self.xauthPath = xauthPath; self.display = display; self.xauthority = xauthority
    }
}

/// État de l'affichage X11 sur ce Mac : serveur intégré à Escale (prioritaire), sinon XQuartz installé, `xauth`, `DISPLAY`. Pur : le système de fichiers et l'environnement
/// sont injectés pour les tests (aucune détection ne modifie quoi que ce soit).
public struct X11Detection: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Tout est là : la redirection peut être demandée à ssh.
        case ready
        case notInstalled
        /// XQuartz est installé mais `xauth` est introuvable (installation incomplète).
        case missingXauth
        /// XQuartz est installé mais aucun `DISPLAY` (launchd le fournit après une réouverture de session).
        case noDisplay
    }

    public var xquartzPath: String?
    public var xauthPath: String?
    public var display: String?
    /// Serveur intégré (`Contents/Helpers/EscaleX11.app`) : démarré à la demande, avant la connexion du maître.
    public var embedded: Bool
    /// `XAUTHORITY` à donner à ssh (serveur intégré).
    public var xauthority: String?

    public init(xquartzPath: String? = nil, xauthPath: String? = nil, display: String? = nil,
                embedded: Bool = false, xauthority: String? = nil) {
        self.xquartzPath = xquartzPath; self.xauthPath = xauthPath; self.display = display
        self.embedded = embedded; self.xauthority = xauthority
    }

    /// Détection pour le serveur intégré : toujours prête (le serveur démarre à la première connexion X11).
    public static func embedded(_ server: EmbeddedX11Server) -> X11Detection {
        X11Detection(xquartzPath: server.bundle.appPath, xauthPath: server.bundle.xauthPath, display: server.display,
                     embedded: true, xauthority: server.xauthority)
    }

    public static let installURL = URL(string: "https://www.xquartz.org")!
    public static let appCandidates = ["/Applications/Utilities/XQuartz.app", "/opt/X11"]
    public static let xauthCandidates = ["/opt/X11/bin/xauth", "/usr/X11/bin/xauth", "/opt/homebrew/bin/xauth", "/usr/local/bin/xauth"]

    public var status: Status {
        guard xquartzPath != nil else { return .notInstalled }
        guard xauthPath != nil else { return .missingXauth }
        guard let d = display, !d.isEmpty else { return .noDisplay }
        return .ready
    }

    public var isReady: Bool { status == .ready }

    /// Réglages à donner au transport, ou `nil` si X11 n'est pas utilisable (alors jamais de `-X`).
    public func settings(trusted: Bool) -> X11Settings? {
        guard isReady, let x = xauthPath else { return nil }
        return X11Settings(trusted: trusted, xauthPath: x, display: display, xauthority: xauthority)
    }

    /// Message français pour l'utilisateur.
    public var explanation: String {
        switch status {
        case .ready where embedded:
            return "Serveur X11 intégré à Escale : les applications X11 s'affichent sur ce Mac, sans rien installer."
        case .ready:
            return "XQuartz détecté (\(xquartzPath ?? "")). Les applications X11 s'afficheront sur ce Mac."
        case .notInstalled:
            return "XQuartz n'est pas installé : sans lui, ssh ne peut pas afficher d'application X11. Installez-le depuis xquartz.org, puis fermez et rouvrez votre session macOS."
        case .missingXauth:
            return "XQuartz est installé, mais le programme xauth est introuvable : réinstallez XQuartz."
        case .noDisplay:
            return "XQuartz est installé, mais la variable DISPLAY est absente : fermez et rouvrez votre session macOS (ou lancez XQuartz une fois), puis relancez Escale."
        }
    }

    // MARK: Détection

    /// Détecte XQuartz. `fileExists`, `environment`, `launchctlDisplay` et `listDirectory` sont injectables.
    /// `DISPLAY` : environnement de l'app → `launchctl getenv DISPLAY` → socket `org.xquartz:0` de launchd.
    public static func detect(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchctlDisplay: () -> String? = { X11Detection.launchctlGetenvDisplay() },
        listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> X11Detection {
        let app = appCandidates.first(where: fileExists)
        let xauth = xauthCandidates.first(where: fileExists)
        guard app != nil else { return X11Detection(xquartzPath: nil, xauthPath: xauth, display: nil) }
        var display = environment["DISPLAY"].flatMap { $0.isEmpty ? nil : $0 }
        if display == nil { display = launchctlDisplay().flatMap { $0.isEmpty ? nil : $0 } }
        if display == nil {
            for dir in listDirectory("/private/tmp").sorted() where dir.hasPrefix("com.apple.launchd.") {
                let socket = "/private/tmp/\(dir)/org.xquartz:0"
                if fileExists(socket) { display = socket; break }
            }
        }
        return X11Detection(xquartzPath: app, xauthPath: xauth, display: display)
    }

    /// `launchctl getenv DISPLAY` (vide si absent). Lecture seule.
    public static func launchctlGetenvDisplay() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", "DISPLAY"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }
}

/// Validation de la commande saisie pour « Lancer une application X11 ».
public enum X11LaunchCommand {
    public static let defaultCommand = "xeyes"
    public static let maxLength = 500

    /// Commande nettoyée (une seule ligne, interprétée par le shell distant), ou message d'erreur français.
    public static func validate(_ text: String) -> Result<String, X11LaunchError> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(.init(message: "Saisissez une commande (par exemple xeyes).")) }
        if t.count > maxLength { return .failure(.init(message: "Commande trop longue (\(maxLength) caractères au plus).")) }
        if t.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return .failure(.init(message: "La commande doit tenir sur une seule ligne, sans caractère de contrôle."))
        }
        return .success(t)
    }
}

public struct X11LaunchError: Error, Equatable, Sendable { public var message: String }
