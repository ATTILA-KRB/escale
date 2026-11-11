import SwiftUI
import AppKit
import EscaleCore

/// Validation pure des champs de l'éditeur d'hôte (testable sans interface).
enum HostFormValidation {
    static func isSuspicious(_ s: String) -> Bool { s.hasPrefix("-") }

    static func host(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "L'hôte est obligatoire." }
        if isSuspicious(t) { return "L'hôte ne peut pas commencer par « - »." }
        if t.contains(where: \.isWhitespace) { return "L'hôte ne peut pas contenir d'espace." }
        return nil
    }
    static func port(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard let p = Int(t), (1...65535).contains(p) else { return "Le port doit être un nombre entre 1 et 65535." }
        return nil
    }
    static func user(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if isSuspicious(t) { return "L'utilisateur ne peut pas commencer par « - »." }
        if t.contains(where: \.isWhitespace) || t.contains("@") { return "Utilisateur invalide." }
        return nil
    }
    static func keyPath(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Choisissez un fichier de clé." }
        if isSuspicious(t) { return "Le chemin ne peut pas commencer par « - »." }
        return nil
    }
    static func jumpHosts(_ s: String) -> String? {
        for j in split(s) {
            if isSuspicious(j) { return "Un bastion ne peut pas commencer par « - »." }
            if j.contains(where: \.isWhitespace) { return "Bastions : séparez-les par des virgules, sans espace interne." }
        }
        return nil
    }
    static func name(_ s: String) -> String? {
        isSuspicious(s.trimmingCharacters(in: .whitespaces)) ? "Le nom ne peut pas commencer par « - »." : nil
    }
    static func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Feuille d'édition (ou de création) d'un hôte.
struct HostEditorSheet: View {
    let model: AppModel
    let host: HostProfile?
    let initialFolder: UUID?
    @Environment(\.dismiss) private var dismiss

    private enum AuthChoice: Hashable { case defaults, keyFile, keychain }

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = ""
    @State private var user = ""
    @State private var authChoice: AuthChoice = .defaults
    @State private var keyPath = ""
    /// Identifiant de l'hôte (celui de l'hôte édité, ou un nouvel identifiant) : le compte Trousseau en dérive.
    @State private var hostID = UUID()
    @State private var hasStoredSecret = false
    @State private var secretMessage: String?
    @State private var jumpHosts = ""
    @State private var tags = ""
    @State private var folderID: UUID?
    @State private var tunnels: [TunnelSpec] = []
    @State private var x11Forwarding = false
    @State private var startupCommand = ""
    @State private var loaded = false

    private var errors: [String] {
        var e: [String] = []
        [HostFormValidation.name(name), HostFormValidation.host(hostname), HostFormValidation.port(port),
         HostFormValidation.user(user), authChoice == .keyFile ? HostFormValidation.keyPath(keyPath) : nil,
         HostFormValidation.jumpHosts(jumpHosts)].forEach { if let m = $0 { e.append(m) } }
        if let m = StartupCommand.validationMessage(startupCommand) { e.append(m) }
        e += TunnelValidation.listErrors(tunnels) + tunnels.filter { !TunnelValidation.errors($0).isEmpty }.map { "Tunnel « \($0.title) » invalide." }
        return e
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nom", text: $name, prompt: Text("Identique à l'hôte si vide"))
                    TextField("Hôte", text: $hostname, prompt: Text("nom, adresse IP ou alias ssh_config"))
                        .disableAutocorrection(true)
                    TextField("Port", text: $port, prompt: Text("22"))
                    TextField("Utilisateur", text: $user, prompt: Text("Utilisateur courant"))
                }
                Section("Authentification") {
                    Picker("Méthode", selection: $authChoice) {
                        Text("Réglages OpenSSH par défaut").tag(AuthChoice.defaults)
                        Text("Fichier de clé").tag(AuthChoice.keyFile)
                        Text("Mot de passe (Trousseau)").tag(AuthChoice.keychain)
                    }
                    if authChoice == .keyFile {
                        LabeledContent("Clé privée") {
                            HStack(spacing: 8) {
                                // Chemin long : troncature au milieu (début et nom du fichier restent lisibles), chemin complet en infobulle.
                                Text(keyPath.isEmpty ? "Aucun fichier choisi" : keyPath)
                                    .foregroundStyle(keyPath.isEmpty ? .secondary : .primary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(keyPath.isEmpty ? "Aucun fichier choisi" : keyPath)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Choisir…") { chooseKey() }
                            }
                        }
                        Text("Si la clé est protégée par une phrase de passe, elle vous sera demandée à la connexion.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if authChoice == .keychain {
                        Text("Le mot de passe est demandé à la première connexion. La case « Mémoriser dans le Trousseau » l'enregistre, après une connexion réussie.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if hasStoredSecret {
                            HStack {
                                Label("Un mot de passe est enregistré dans le Trousseau.", systemImage: "checkmark.seal")
                                    .font(.caption)
                                Spacer()
                                Button("Oublier le mot de passe enregistré") { forgetSecret() }.controlSize(.small)
                            }
                        } else if let m = secretMessage {
                            Text(m).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if authChoice == .defaults {
                        Text("Agent ssh, clés par défaut et ~/.ssh/config.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Bastions", text: $jumpHosts, prompt: Text("user@bastion:22, autre-bastion"))
                    TextField("Étiquettes", text: $tags, prompt: Text("prod, web"))
                    Picker("Dossier", selection: $folderID) {
                        Text("Racine").tag(UUID?.none)
                        ForEach(model.library.allFolderPaths, id: \.id) { Text($0.path).tag(UUID?.some($0.id)) }
                    }
                }
                TunnelEditorSection(tunnels: $tunnels)
                X11EditorSection(isOn: $x11Forwarding, detect: { [connections = model.connections] in connections.x11Detect() })
                StartupCommandEditorSection(text: $startupCommand)
            }
            .formStyle(.grouped)

            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 6)
            }
            Divider()
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(host == nil ? "Ajouter" : "Enregistrer") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!errors.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480)
        .onAppear(perform: load)
        .navigationTitle(host == nil ? "Nouvel hôte" : "Modifier l'hôte")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        folderID = initialFolder
        guard let h = host else { return }
        hostID = h.id
        name = h.name; hostname = h.host; port = h.port.map(String.init) ?? ""; user = h.user ?? ""
        jumpHosts = h.jumpHosts.joined(separator: ", "); tags = h.tags.joined(separator: ", ")
        tunnels = h.tunnels; x11Forwarding = h.x11Forwarding; startupCommand = h.startupCommand ?? ""
        switch h.auth {
        case .openSSHDefaults: authChoice = .defaults
        case .keyFile(let p): authChoice = .keyFile; keyPath = p
        case .keychainPassword: authChoice = .keychain; refreshStoredSecret()
        }
    }

    private var account: String { AuthKeychain.passwordAccount(for: hostID) }

    private func refreshStoredSecret() {
        let store = model.connections.secretStore, account = account
        Task { hasStoredSecret = ((try? await store.secret(for: account)) ?? nil) != nil }
    }

    private func forgetSecret() {
        let store = model.connections.secretStore, account = account
        Task {
            do { try await store.removeSecret(for: account); hasStoredSecret = false; secretMessage = "Mot de passe oublié." }
            catch { secretMessage = "Suppression impossible : \(error)" }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.prompt = "Choisir"
        panel.message = "Choisissez le fichier de clé privée (il n'est jamais copié ni modifié)."
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    private func save() {
        let hostTrim = hostname.trimmingCharacters(in: .whitespaces)
        let nameTrim = name.trimmingCharacters(in: .whitespaces)
        let userTrim = user.trimmingCharacters(in: .whitespaces)
        let auth: HostProfile.Auth = switch authChoice {
        case .defaults: .openSSHDefaults
        case .keyFile: .keyFile(path: keyPath.trimmingCharacters(in: .whitespaces))
        case .keychain: .keychainPassword(account: account)
        }
        var h = host ?? HostProfile(id: hostID, name: "", host: "")
        // Méthode quittée : le mot de passe enregistré ne doit pas rester orphelin dans le Trousseau.
        if case .keychainPassword = h.auth, authChoice != .keychain {
            let store = model.connections.secretStore, hid = h.id
            Task { try? await store.removeSecret(for: AuthKeychain.passwordAccount(for: hid)) }
        }
        h.name = nameTrim.isEmpty ? hostTrim : nameTrim
        h.host = hostTrim
        h.port = Int(port.trimmingCharacters(in: .whitespaces))
        h.user = userTrim.isEmpty ? nil : userTrim
        h.auth = auth
        h.jumpHosts = HostFormValidation.split(jumpHosts)
        h.tags = HostFormValidation.split(tags)
        h.folderID = folderID
        h.tunnels = tunnels
        h.x11Forwarding = x11Forwarding
        h.startupCommand = StartupCommand.normalized(startupCommand)
        let previousTunnels = host?.tunnels ?? []
        model.library.upsert(h)
        model.tunnels.hostSaved(oldTunnels: previousTunnels, host: h) // modification à chaud des tunnels actifs
        dismiss()
    }
}

/// Création ou renommage d'un dossier.
struct FolderSheet: View {
    let model: AppModel
    let folder: HostFolder?
    let parent: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var error: String? { HostFormValidation.name(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder == nil ? "Nouveau dossier" : "Renommer le dossier").font(.headline)
            TextField("Nom", text: $name).onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(folder == nil ? "Créer" : "Renommer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || error != nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = folder?.name ?? "" }
    }

    private func save() {
        guard !trimmed.isEmpty, error == nil else { return }
        if let f = folder { model.library.renameFolder(f.id, to: trimmed) } else { model.library.addFolder(name: trimmed, parentID: parent) }
        dismiss()
    }
}
