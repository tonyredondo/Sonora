import SonoraCore
import SwiftUI

struct MetadataConnectionView: View {
    @State private var settings = MetadataAssistantSettings.shared
    @State private var archive = MetadataArchiveController.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var savedToken = ""
    @State private var message: String?
    @State private var checking = false
    @State private var cacheBytes = 0
    @State private var confirmClear = false
    @State private var check: Task<Void, Never>?
    private var unsaved: Bool { endpoint != settings.endpoint || token != savedToken }

    var body: some View {
        Form {
            Section {
                Toggle("Modo desconectado", isOn: $settings.offline)
                    .accessibilityIdentifier("metadataOffline")
                Text("La reproducción y la edición de tus archivos funcionan sin conexión. El asistente podrá consultar las búsquedas, letras y carátulas guardadas en este iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !settings.networkAvailable { Label("Sin conexión de red", systemImage: "wifi.slash") }
            }
            Section("Conexión del asistente") {
                TextField("Dirección del servidor", text: $endpoint, prompt: Text("https://…"))
                    .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().accessibilityIdentifier("metadataEndpoint")
                SecureField("Token de acceso", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("metadataToken")
                Text("Usa el token de tu servidor Sonora. Las claves de AcoustID y ElevenLabs se configuran en el servidor.")
                    .font(.footnote).foregroundStyle(.secondary)
                CompactActionRow(layout: .inline) {
                    Button { save() } label: {
                        CompactActionLabel(title: "Guardar conexión", icon: "square.and.arrow.down", caption: "Guardar")
                    }.accessibilityIdentifier("saveMetadataConnection")
                    Button { verify() } label: {
                        CompactActionLabel(title: "Comprobar conexión", icon: "network", caption: "Comprobar")
                    }.disabled(checking || settings.effectiveOffline || unsaved)
                        .accessibilityIdentifier("testMetadataConnection")
                }
                if unsaved { Text("Guarda la conexión para comprobarla.").font(.footnote).foregroundStyle(.secondary) }
                if checking { ProgressView("Comprobando…") }
                if let message { Text(message).font(.footnote).accessibilityIdentifier("metadataConnectionMessage") }
                if let issue = settings.configurationIssue { Text(issue).foregroundStyle(.red) }
            }
            Section("Copias de tus ediciones") {
                LabeledContent("Pendientes de enviar",value:String(archive.pending))
                    .accessibilityIdentifier("metadataArchivePending")
                if archive.otherServersPending > 0 {
                    Text("\(archive.otherServersPending) copias pendientes pertenecen a otra dirección. Vuelve a guardar esa conexión para enviarlas.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if archive.synchronizing { ProgressView("Guardando copias en el servidor…") }
                if let issue = archive.issue { Text(issue).foregroundStyle(.secondary) }
                Button("Enviar copias pendientes") { archive.retry() }
                    .disabled(archive.synchronizing || settings.effectiveOffline || archive.destination == nil)
                    .accessibilityIdentifier("retryMetadataArchive")
                Text("Al guardar etiquetas se conserva una copia de la información, carátula y letra. El audio se queda en tu iPhone. Sin conexión, las copias esperan a que vuelvas a conectarte o abras Sonora. Puedes recuperarlas desde Información → Recuperar información guardada.")
                    .font(.footnote).foregroundStyle(.secondary)
                if archive.destination == nil { Text("Configura la conexión para guardar nuevas ediciones en el servidor. Las copias actuales siguen en este iPhone.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Caché de consultas en este iPhone") {
                LabeledContent("Información, letras y carátulas", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                Button("Borrar información guardada", role: .destructive) { confirmClear = true }
                Text("Hasta 100 MB. Borrarla no cambia tu música, sus etiquetas ni las copias de tus ediciones. Las consultas nuevas necesitan conexión.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Asistente de información").navigationBarTitleDisplayMode(.inline)
        .task {
            endpoint = settings.endpoint
            do { savedToken = try settings.savedToken(); token = savedToken; cacheBytes = try await settings.cache.size() }
            catch { message = error.localizedDescription }
        }
        .onDisappear { check?.cancel(); checking = false }
        .onChange(of: endpoint) { cancelCheck() }
        .onChange(of: token) { cancelCheck() }
        .onChange(of: settings.effectiveOffline) { if settings.effectiveOffline { check?.cancel(); checking = false } }
        .confirmationDialog("¿Borrar la información guardada para usar sin conexión?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar información guardada", role: .destructive) {
                Task {
                    do { try await settings.cache.clear(); cacheBytes = try await settings.cache.size(); message = "Información guardada borrada." }
                    catch { message = error.localizedDescription }
                }
            }
        }
    }

    private func save() {
        check?.cancel(); checking = false
        do { try settings.save(endpoint: endpoint, token: token); savedToken = token; endpoint = settings.endpoint; message = "Conexión guardada." }
        catch { message = error.localizedDescription }
    }
    private func verify() {
        check?.cancel(); checking = true; message = nil
        check = Task {
            defer { if !Task.isCancelled { checking = false } }
            do {
                let status = try await settings.client().status()
                try Task.checkCancellation()
                let identification = status.providers["acoustid"].map { $0.enabled && $0.configured } == true
                message = "Conexión comprobada a las \(Date.now.formatted(date: .omitted, time: .shortened))." +
                    (identification ? " AcoustID configurado en el servidor." : " AcoustID pendiente de configurar en el servidor.")
            } catch is CancellationError { }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func cancelCheck() {
        if checking { check?.cancel(); checking = false; message = nil }
    }
}
