import SwiftUI

struct LinkImportView: View {
    let imports: LinkImportController
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                if imports.hasPendingImport || imports.issue != nil || imports.completedName != nil {
                    Section { LinkImportStatusView(imports: imports) }
                }
                Section {
                    TextField("https://we.tl/…", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($editing)
                        .accessibilityLabel("Enlace de WeTransfer")
                        .accessibilityIdentifier("transferLink")
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { link = value }
                    }
                    TextField("Nombre de la carpeta (opcional)", text: $name)
                        .accessibilityIdentifier("transferName")
                } header: { Text("WeTransfer") }
                footer: {
                    Text("Sonora descargará y descomprimirá el contenido en su almacenamiento. La carpeta se añadirá a tus fuentes para escucharla sin conexión.")
                }
                .disabled(imports.hasPendingImport)
            }
            .navigationTitle("Añadir enlace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importar") {
                        editing = false
                        imports.start(link, name: name)
                    }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imports.hasPendingImport)
                    .accessibilityIdentifier("startLinkImport")
                }
            }
        }
    }
}

/// Shared by the sheet and Sources so closing the form never hides the job.
struct LinkImportStatusView: View {
    let imports: LinkImportController

    var body: some View {
        if imports.hasPendingImport {
            if imports.isImporting {
                VStack(alignment: .leading, spacing: 12) {
                    Text(imports.status).accessibilityIdentifier("linkImportStatus")
                    if let fraction = imports.fraction {
                        ProgressView(value: fraction)
                        Text("\(ByteCountFormatter.string(fromByteCount: imports.progressBytes, countStyle: .file)) de \(ByteCountFormatter.string(fromByteCount: imports.expectedBytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView() }
                }.padding(.vertical, 4)
            }
            if imports.canRetry {
                Button("Reintentar importación", systemImage: "arrow.clockwise") { imports.retry() }
                    .accessibilityIdentifier("retryLinkImport")
            }
            if imports.canCancel {
                Button(imports.canRetry ? "Descartar importación" : "Cancelar importación", role: .cancel) { imports.cancel() }
                    .accessibilityIdentifier("cancelLinkImport")
            }
        }
        if let issue = imports.issue {
            Text(issue).accessibilityIdentifier("linkImportError")
            if !imports.hasPendingImport { Button("Cerrar aviso") { imports.issue = nil } }
        }
        if let name = imports.completedName {
            Label("Añadido a la biblioteca: \(name)", systemImage: "checkmark.circle")
                .accessibilityIdentifier("linkImportCompleted")
        }
    }
}
