import SonoraCore
import SwiftUI

@MainActor struct LyricsRepairView: View {
    @State private var session: LyricsRepairSession
    @State private var settings = MetadataAssistantSettings.shared
    @State private var preview: PreviewRequest?
    @State private var editing: EditRequest?
    @State private var previewIssue = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    private struct PreviewRequest: Identifiable { let id = UUID(); let text: String }
    private struct EditRequest: Identifiable { let proposal: LyricsRepair.Proposal; let edit: LyricsRepair.Edit; var id: Int { proposal.id } }

    init(player: PlaybackController, track: AudioTrack) {
        _session = State(initialValue:LyricsRepairSession(player:player,track:track))
    }
    var body: some View {
        Form {
            Section {
                Text(session.title).font(.headline)
                if session.review == nil {
                    Text("Comparamos la letra con una transcripción de toda la canción. Tú eliges qué corregir y qué completar.")
                    Button(settings.effectiveOffline ? "Buscar análisis guardado" : "Analizar letra con IA") { Task { await session.analyze() } }
                        .disabled(!session.canAnalyze).accessibilityIdentifier("analyzeLyricsRepair")
                    Text("Usamos ElevenLabs y guardamos el análisis para reutilizarlo. Un análisis nuevo envía el audio y consume créditos de tu cuenta. Máximo: 10 minutos.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if settings.endpoint.isEmpty { NavigationLink("Configurar asistente") { MetadataConnectionView() } }
                }
                if session.loading { ProgressView(session.phase).accessibilityIdentifier("repairProgress") }
                if let issue = session.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("repairIssue") }
                if let warning = session.warning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
            }
            if let review = session.review {
                Section {
                    Label(session.isCached ? "Análisis guardado · ElevenLabs" : "Análisis de ElevenLabs",systemImage:session.isCached ? "internaldrive" : "waveform")
                        .accessibilityIdentifier("repairAnalysisSource")
                    Toggle("Solo completar lo que falta",isOn:$session.onlyCompletions).accessibilityIdentifier("repairOnlyCompletions")
                    Text("\(session.selectedCount) cambios seleccionados").font(.subheadline).accessibilityIdentifier("repairSelectionCount")
                    Text("La IA puede confundir palabras cantadas. Escucha cada propuesta antes de aceptarla.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if review.usesPhraseTiming {
                        Text("Este análisis guardado tiene tiempos por frase. Puedes reutilizarlo sin pagar otro análisis; revisa el inicio de los fragmentos nuevos.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !session.canListen { Text("Para escuchar fragmentos, selecciona esta canción en el reproductor.").font(.footnote).foregroundStyle(.secondary) }
                }
                if session.visibleProposals.isEmpty {
                    Section {
                        Text(session.onlyCompletions && review.proposals.contains { $0.kind == .correction }
                             ? "No hay propuestas para completar. Desactiva el filtro para revisar las correcciones."
                             : "No hay correcciones ni fragmentos para completar.")
                    }
                }
                ForEach(session.visibleProposals) { proposal in
                    Section {
                        proposalCard(proposal)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(PlayerTheme(scheme).background)
        .tint(PlayerTheme(scheme).accent)
        .navigationTitle("Reparar letra").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(session.saving)
        .safeAreaInset(edge:.bottom) {
            if session.review != nil {
                Button {
                    do { preview = PreviewRequest(text:try session.draft()) }
                    catch { session.issue = error.localizedDescription; previewIssue = true }
                } label: { Text("Revisar selección (\(session.selectedCount))").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.borderedProminent).disabled(session.selectedCount == 0 || session.saving)
                    .accessibilityIdentifier("previewLyricsRepair")
                    .padding().background(PlayerTheme(scheme).surface)
            }
        }
        .task { await session.load() }
        .onDisappear { session.cancel() }
        .onChange(of:settings.configurationRevision) { session.cancel() }
        .onChange(of:settings.effectiveOffline) { session.cancel() }
        .onChange(of:scenePhase) { if scenePhase != .active { session.cancel() } }
        .onChange(of:session.player.currentTime) { session.checkPreview() }
        .alert("Revisa la selección",isPresented:$previewIssue) {
            Button("Aceptar",role:.cancel) { }
        } message: { Text(session.issue ?? "No se pudo preparar la letra.") }
        .sheet(item:$editing) { request in
            LyricsRepairEditView(proposal:request.proposal,edit:request.edit,timed:session.review?.isTimed == true) { text,time in
                session.setEdit(request.proposal,text:text,startTime:time)
            }
        }
        .sheet(item:$preview,onDismiss:{ if session.saved { dismiss() } }) { request in
            LyricsRepairPreviewView(session:session,text:request.text)
        }
    }
    @ViewBuilder private func proposalCard(_ proposal: LyricsRepair.Proposal) -> some View {
        let accepted = session.edits[proposal.id], kept = session.kept.contains(proposal.id)
        VStack(alignment:.leading,spacing:12) {
            Label(title(proposal.kind),systemImage:proposal.kind == .completion ? "text.badge.plus" : "text.badge.checkmark")
                .font(.headline).accessibilityIdentifier("repairProposal-\(proposal.id)")
            if let start = proposal.start {
                Button { session.listen(proposal) } label: { Label("Escuchar · \(playbackTime(start))",systemImage:"play.circle") }
                    .buttonStyle(.borderless).disabled(!session.canListen || session.saving)
                    .frame(minHeight:44).accessibilityIdentifier("repairListen-\(proposal.id)")
            }
            if !proposal.context.isEmpty { Text(proposal.context).font(.subheadline).foregroundStyle(.secondary) }
            if !proposal.original.isEmpty {
                Text("Original").font(.caption).foregroundStyle(.secondary)
                Text(proposal.original).textSelection(.enabled)
            }
            Text(accepted == nil ? "Propuesta" : "Selección").font(.caption).foregroundStyle(.secondary)
            Text(accepted?.text ?? proposal.suggested).font(.body.weight(.semibold)).textSelection(.enabled)
                .accessibilityIdentifier("repairSuggested-\(proposal.id)")
            if accepted != nil || kept {
                Label(kept ? "Original conservado" : "Seleccionada",systemImage:kept ? "checkmark.shield" : "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(PlayerTheme(scheme).accent)
                Button("Deshacer decisión") { session.undo(proposal) }.buttonStyle(.borderless)
                    .frame(minHeight:44).accessibilityIdentifier("repairUndo-\(proposal.id)")
            }
            ViewThatFits(in:.horizontal) {
                HStack { actions(proposal) }
                VStack(alignment:.leading) { actions(proposal) }
            }
        }
        .accessibilityElement(children:.contain)
    }
    @ViewBuilder private func actions(_ proposal:LyricsRepair.Proposal) -> some View {
        Button(proposal.kind == .completion ? "Añadir" : "Aceptar") { session.accept(proposal) }
            .buttonStyle(.bordered).frame(minHeight:44).accessibilityIdentifier("repairAccept-\(proposal.id)")
        Button("Conservar") { session.keep(proposal) }.buttonStyle(.bordered).frame(minHeight:44).accessibilityIdentifier("repairKeep-\(proposal.id)")
        Button("Editar") {
            editing = EditRequest(proposal:proposal,edit:session.edits[proposal.id] ?? .init(text:proposal.suggested,startTime:proposal.start))
        }.buttonStyle(.bordered).frame(minHeight:44).accessibilityIdentifier("repairEdit-\(proposal.id)")
    }
    private func title(_ kind:LyricsRepair.Kind) -> String {
        kind == .completion ? "Fragmento que podría faltar" : "Posible corrección"
    }
}

private struct LyricsRepairEditView: View {
    let proposal: LyricsRepair.Proposal
    let timed: Bool
    let apply: (String,Double?) -> Void
    @State private var text: String
    @State private var start: Double
    @Environment(\.dismiss) private var dismiss
    init(proposal:LyricsRepair.Proposal,edit:LyricsRepair.Edit,timed:Bool,apply:@escaping (String,Double?) -> Void) {
        self.proposal = proposal; self.timed = timed; self.apply = apply
        _text = State(initialValue:edit.text); _start = State(initialValue:edit.startTime ?? proposal.start ?? 0)
    }
    var body: some View {
        NavigationStack {
            Form {
                if !proposal.original.isEmpty { Section("Original") { Text(proposal.original).textSelection(.enabled) } }
                Section("Tu corrección") { TextEditor(text:$text).frame(minHeight:150).accessibilityLabel("Texto corregido").accessibilityIdentifier("repairEditText") }
                if timed && proposal.insertsLines {
                    Section("Inicio del fragmento") {
                        TextField("Segundos",value:$start,format:.number.precision(.fractionLength(0...2))).keyboardType(.decimalPad)
                            .accessibilityIdentifier("repairEditTime")
                    }
                }
            }
            .navigationTitle("Editar propuesta").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Usar corrección") { apply(text,timed && proposal.insertsLines ? start : proposal.start); dismiss() }.accessibilityIdentifier("repairUseEdit") }
            }
        }
    }
}

@MainActor private struct LyricsRepairPreviewView: View {
    let session: LyricsRepairSession
    let text: String
    @State private var confirmSave = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("Revisa el resultado. Guardar escribirá esta letra en el archivo de audio.").font(.footnote).foregroundStyle(.secondary)
                    if let issue = session.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("repairSaveIssue") }
                    ForEach(LyricsDocument(text:text).lines) { line in
                        VStack(alignment:.leading,spacing:4) {
                            if let time = line.time { Text(playbackTime(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            Text(line.text).font(.title3).textSelection(.enabled)
                        }
                    }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
            .navigationTitle("Vista previa").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Volver") { dismiss() }.disabled(session.saving).accessibilityIdentifier("cancelRepairPreview") }
                ToolbarItem(placement:.confirmationAction) {
                    Button(session.saving ? "Guardando…" : "Guardar") { confirmSave = true }.disabled(session.saving).accessibilityIdentifier("saveLyricsRepair")
                }
            }
            .confirmationDialog("Guardar letra en el archivo",isPresented:$confirmSave) {
                Button("Guardar en archivo") { Task { await session.save(text); if session.saved { dismiss() } } }
            } message: { Text("Se guardará la selección en \(session.track.filename).") }
            .interactiveDismissDisabled(session.saving)
        }
    }
}
