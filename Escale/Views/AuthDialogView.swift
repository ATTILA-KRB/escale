import SwiftUI
import EscaleCore

/// Feuille d'une demande d'authentification (une seule à la fois : voir `AuthDialogCenter`).
struct AuthDialogView: View {
    let dialog: AuthDialog
    let center: AuthDialogCenter

    @State private var secret = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                // Icône calée sur le bord gauche du corps (frame leading), centrée sur le bloc titre + sous-titre.
                Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(tint)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("Connexion à « \(dialog.hostName) »").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            content
            if dialog.request.attempt > 1, !isHostKey {
                Label("La saisie précédente a été refusée par le serveur.", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled()
        .onAppear { focused = true }
    }

    /// ssh écrit « [127.0.0.1]:2222 ([127.0.0.1]:2222) » quand l'adresse égale le nom : une seule occurrence.
    private func displayHost(_ host: String?) -> String {
        guard let host else { return dialog.hostName }
        if let r = host.range(of: " ("), host.hasSuffix(")") {
            let a = String(host[..<r.lowerBound]), b = String(host[r.upperBound...].dropLast())
            return a == b ? a : host
        }
        return host
    }

    private var isHostKey: Bool { if case .hostKeyConfirmation = dialog.request.kind { true } else { false } }

    // MARK: Contenu par type d'invite

    @ViewBuilder private var content: some View {
        switch dialog.request.kind {
        case .password(let userAtHost):
            if let u = userAtHost { Text(u).font(.callout).foregroundStyle(.secondary) }
            SecureField("Mot de passe", text: $secret).focused($focused).onSubmit(submit)
            rememberToggle
        case .passphrase(let keyPath):
            Text("Clé : \((keyPath as NSString).lastPathComponent)").font(.callout.weight(.medium))
            Text(keyPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(keyPath)
            SecureField("Phrase de passe", text: $secret).focused($focused).onSubmit(submit)
            rememberToggle
        case .verificationCode:
            // Texte de l'invite du serveur, tel quel (il explique d'où vient le code).
            Text(dialog.request.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            TextField("Code de vérification", text: $secret).focused($focused).onSubmit(submit)
                .disableAutocorrection(true)
        case .hostKeyConfirmation(let keyType, let fingerprint, let host):
            Text("L'authenticité de cet hôte ne peut pas être vérifiée : sa clé n'est pas encore connue. Comparez l'empreinte avec celle de votre administrateur avant de faire confiance.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("Hôte").foregroundStyle(.secondary); Text(displayHost(host)).textSelection(.enabled) }
                GridRow { Text("Type de clé").foregroundStyle(.secondary); Text(keyType ?? "inconnu").textSelection(.enabled) }
                GridRow(alignment: .top) {
                    Text("Empreinte").foregroundStyle(.secondary)
                    Text(fingerprint ?? "indisponible")
                        .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.7) // jamais coupée au milieu : une empreinte se compare d'un coup d'œil
                }
            }
        case .hostKeyChanged, .other:
            Text(dialog.request.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if case .other = dialog.request.kind {
                SecureField("Réponse", text: $secret).focused($focused).onSubmit(submit)
            }
        }
    }

    @ViewBuilder private var rememberToggle: some View {
        if dialog.canRemember {
            Toggle("Mémoriser dans le Trousseau", isOn: $remember)
            Text("Enregistré seulement après une connexion réussie.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Boutons

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            if isHostKey {
                // Bouton par défaut (Entrée) = Annuler : faire confiance exige un clic délibéré.
                Button("Faire confiance") { center.resolve(dialog.id, .accept) }
                Button("Annuler") { center.resolve(dialog.id, .cancel) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Annuler") { center.resolve(dialog.id, .cancel) }.keyboardShortcut(.cancelAction)
                Button("Continuer", action: submit).keyboardShortcut(.defaultAction).disabled(secret.isEmpty)
            }
        }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        center.resolve(dialog.id, .secret(Secret(secret), remember: dialog.canRemember && remember))
    }

    // MARK: Présentation

    private var title: String {
        switch dialog.request.kind {
        case .password: "Mot de passe requis"
        case .passphrase: "Phrase de passe requise"
        case .verificationCode: "Code de vérification requis"
        case .hostKeyConfirmation: "Hôte inconnu"
        case .hostKeyChanged: "Clé d'hôte modifiée"
        case .other: "Information demandée par le serveur"
        }
    }

    private var symbol: String {
        switch dialog.request.kind {
        case .password: "key.fill"
        case .passphrase: "lock.fill"
        case .verificationCode: "number.circle.fill"
        case .hostKeyConfirmation: "lock.shield.fill" // « questionmark.shield » n'existe pas : l'icône restait vide
        case .hostKeyChanged: "exclamationmark.shield.fill"
        case .other: "text.bubble.fill"
        }
    }

    private var tint: Color {
        switch dialog.request.kind {
        case .hostKeyConfirmation: .orange
        case .hostKeyChanged: .red
        default: .accentColor
        }
    }
}
