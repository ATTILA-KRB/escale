import SwiftUI
import EscaleCore

/// Feuille d'import des hôtes d'un ssh_config : aperçu, cases à cocher, dossier de destination.
struct ImportSheet: View {
    let model: AppModel
    @Bindable var importer: ImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importer depuis ~/.ssh/config").font(.headline)
                Text(importer.source.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(importer.source.path)
                Text("Le fichier est lu sans jamais être modifié. Les hôtes importés utilisent les réglages OpenSSH (ssh relit l'alias).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            if let error = importer.error {
                Text(error).foregroundStyle(.red).padding(20).frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else if importer.entries.isEmpty {
                Text("Aucun hôte trouvé dans ce fichier.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(importer.entries, id: \.alias) { entry in
                        row(entry)
                    }
                }
                .listStyle(.bordered)
                .padding(.horizontal, 20)
                .frame(minHeight: 150)
            }

            if !importer.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(importer.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 8)
            }

            HStack {
                Picker("Dossier", selection: $importer.folderID) {
                    Text("Racine").tag(UUID?.none)
                    ForEach(model.library.allFolderPaths, id: \.id) { Text($0.path).tag(UUID?.some($0.id)) }
                }
                .frame(maxWidth: 280)
                Spacer()
                if importer.importableCount > 0 {
                    Button("Tout cocher") { importer.selected = Set(importer.entries.filter(importer.isImportable).map(\.alias)) }
                        .buttonStyle(.link).controlSize(.small)
                    Button("Tout décocher") { importer.selected = [] }.buttonStyle(.link).controlSize(.small)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10)

            Divider().padding(.top, 12)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(importer.selected.isEmpty ? "Importer" : "Importer \(importer.selected.count) hôte\(importer.selected.count > 1 ? "s" : "")") {
                    importer.commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importer.selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560)
        .onAppear { if importer.result == nil && importer.error == nil { importer.load() } }
    }

    @ViewBuilder private func row(_ e: SSHConfigEntry) -> some View {
        let importable = importer.isImportable(e)
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { importer.selected.contains(e.alias) },
                set: { on in if on { importer.selected.insert(e.alias) } else { importer.selected.remove(e.alias) } }))
                .labelsHidden().disabled(!importable)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(e.alias).fontWeight(.medium)
                    if !importable {
                        Text("déjà présent").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(preview(e)).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .opacity(importable ? 1 : 0.45)
        .accessibilityElement(children: .combine)
    }

    private func preview(_ e: SSHConfigEntry) -> String {
        var parts: [String] = []
        parts.append("HostName : \(e.hostName ?? "—")")
        if let u = e.user { parts.append("User : \(u)") }
        if let p = e.port { parts.append("Port : \(p)") }
        if let j = e.proxyJump { parts.append("ProxyJump : \(j)") }
        return parts.joined(separator: "  ·  ")
    }
}
