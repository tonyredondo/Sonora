import SonoraCore
import SwiftUI

private func lyricRepairTimestamp(_ time:Double) -> String {
    guard time.isFinite, abs(time) < 86_400 else { return "Tiempo no válido" }
    let ticks = Int((abs(time) * 100).rounded())
    return (time < 0 ? "−" : "") + String(format:"%d:%02d.%02d",ticks / 6000,ticks / 100 % 60,ticks % 100)
}

@MainActor struct LyricsRepairView: View {
    @State private var session: LyricsRepairSession
    @State private var settings = MetadataAssistantSettings.shared
    @State private var preview: PreviewRequest?
    @State private var editing: EditRequest?
    @State private var previewIssue = false
    @State private var confirmDiscard = false
    private var hasDecisions: Bool { !session.saved && (!session.edits.isEmpty || !session.kept.isEmpty) }
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
                    Text("Primero reutilizamos el análisis guardado. Si no existe, ElevenLabs analiza el audio y consume créditos de tu cuenta. Máximo: 10 minutos.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if settings.endpoint.isEmpty { NavigationLink("Configurar asistente") { MetadataConnectionView() } }
                }
                if session.loading { ProgressView(session.phase).accessibilityIdentifier("repairProgress") }
                if let issue = session.issue { ServiceIssueView(message: issue).accessibilityIdentifier("repairIssue") }
                ForEach(session.timingProblemProposals) { proposal in
                    Button("Editar fragmento: \(String(proposal.suggested.prefix(60)))") { edit(proposal) }
                        .frame(minHeight:44).accessibilityIdentifier("repairFixTiming-\(proposal.id)")
                }
                if let warning = session.warning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
            }
            if let review = session.review {
                Section {
                    Label(session.isCached ? "Análisis guardado · ElevenLabs" : "Análisis de ElevenLabs",systemImage:session.isCached ? "internaldrive" : "waveform")
                        .accessibilityIdentifier("repairAnalysisSource")
                    Toggle("Solo completar lo que falta",isOn:$session.onlyCompletions).accessibilityIdentifier("repairOnlyCompletions")
                    let visibleIDs = Set(session.visibleProposals.map(\.id))
                    let reviewed = Set(session.edits.keys).union(session.kept).intersection(visibleIDs).count
                    Text("\(reviewed) de \(visibleIDs.count) propuestas revisadas").accessibilityIdentifier("repairReviewProgress")
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
                        Text(session.onlyCompletions && review.proposals.contains { $0.kind == .correction || $0.kind == .timing }
                             ? "No hay propuestas para completar. Desactiva el filtro para revisar los demás cambios."
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
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(session.saving || hasDecisions)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Volver", systemImage: "chevron.left") {
                    if hasDecisions { confirmDiscard = true } else { dismiss() }
                }.disabled(session.saving)
            }
        }
        .alert("Hay decisiones sin guardar", isPresented: $confirmDiscard) {
            Button("Descartar decisiones", role: .destructive) { dismiss() }
            Button("Seguir revisando", role: .cancel) { }
        }
        .safeAreaInset(edge:.bottom) {
            if session.review != nil {
                Button {
                    session.stopPreview()
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
            if let proposal = session.timingProblemProposals.first { Button("Editar fragmento") { edit(proposal) } }
            Button("Aceptar",role:.cancel) { }
        } message: { Text(session.issue ?? "No se pudo preparar la letra.") }
        .sheet(item:$editing,onDismiss:{ session.stopPreview() }) { request in
            LyricsRepairEditView(session:session,proposal:request.proposal,edit:request.edit,timed:session.review?.isTimed == true,
                                 issue:session.timingIssue?.proposalIDs.contains(request.proposal.id) == true ? session.timingIssue : nil) { text,time in
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
            if proposal.kind != .timing, let start = proposal.start {
                LyricsRepairAudioButton(session:session,proposal:proposal,reference:.fragment,time:start,
                                        title:"fragmento · \(playbackTime(start))",identifier:"repairListen-\(proposal.id)")
            }
            if !proposal.context.isEmpty { Text(proposal.context).font(.subheadline).foregroundStyle(.secondary) }
            if proposal.kind == .timing, let original = proposal.originalStart, let start = accepted?.startTime ?? proposal.start {
                LabeledContent("Inicio actual",value:lyricRepairTimestamp(original))
                    .accessibilityElement(children:.combine).accessibilityLabel("Inicio actual: \(lyricRepairTimestamp(original))")
                    .accessibilityIdentifier("repairOriginalTiming-\(proposal.id)")
                LyricsRepairAudioButton(session:session,proposal:proposal,reference:.current,time:original,
                                        title:"inicio actual",identifier:"repairListenCurrent-\(proposal.id)")
                LabeledContent(accepted == nil ? "Inicio propuesto" : "Inicio seleccionado",value:lyricRepairTimestamp(start))
                    .accessibilityElement(children:.combine).accessibilityLabel("\(accepted == nil ? "Inicio propuesto" : "Inicio seleccionado"): \(lyricRepairTimestamp(start))")
                    .accessibilityIdentifier("repairTiming-\(proposal.id)")
                LyricsRepairAudioButton(session:session,proposal:proposal,reference:.proposed,time:start,
                                        title:accepted == nil ? "inicio propuesto" : "inicio seleccionado",identifier:"repairListenProposed-\(proposal.id)")
                Text("\(start < original ? "Adelantar" : "Retrasar") \(String(format:"%.2f",abs((start * 100).rounded() - (original * 100).rounded()) / 100)) s")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Fragmentos de 4 s, con hasta medio segundo de audio anterior.").font(.footnote).foregroundStyle(.secondary)
            } else {
                if !proposal.original.isEmpty {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    Text(proposal.original).textSelection(.enabled)
                }
                Text(accepted == nil ? "Propuesta" : "Selección").font(.caption).foregroundStyle(.secondary)
                Text(accepted?.text ?? proposal.suggested).font(.body.weight(.semibold)).textSelection(.enabled)
                    .accessibilityIdentifier("repairSuggested-\(proposal.id)")
            }
            if session.timingIssue?.proposalIDs.contains(proposal.id) == true {
                Label("Revisa el tiempo de este fragmento",systemImage:"exclamationmark.circle")
                    .foregroundStyle(.red).accessibilityIdentifier("repairTimingIssue-\(proposal.id)")
            }
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
        Button(proposal.kind == .completion ? "Añadir" : proposal.kind == .timing ? "Aceptar tiempo" : "Aceptar") { session.accept(proposal) }
            .buttonStyle(.bordered).frame(minHeight:44).accessibilityIdentifier("repairAccept-\(proposal.id)")
        Button("Conservar") { session.keep(proposal) }.buttonStyle(.bordered).frame(minHeight:44).accessibilityIdentifier("repairKeep-\(proposal.id)")
        Button("Editar") { edit(proposal) }.buttonStyle(.bordered).frame(minHeight:44).accessibilityIdentifier("repairEdit-\(proposal.id)")
    }
    private func edit(_ proposal:LyricsRepair.Proposal) {
        session.stopPreview()
        editing = EditRequest(proposal:proposal,edit:session.edits[proposal.id] ?? .init(text:proposal.suggested,startTime:proposal.start))
    }
    private func title(_ kind:LyricsRepair.Kind) -> String {
        kind == .timing ? "Ajuste de tiempo" : kind == .completion ? "Fragmento que podría faltar" : "Posible corrección"
    }
}

@MainActor private struct LyricsRepairAudioButton: View {
    let session: LyricsRepairSession
    let proposal: LyricsRepair.Proposal
    let reference: LyricsRepairSession.PreviewReference
    let time: Double?
    let title: String
    let identifier: String
    var body: some View {
        let playing = session.isPreviewing(proposal,reference:reference,at:time)
        Button { session.listen(proposal,reference:reference,at:time) } label: {
            Label("\(playing ? "Detener" : "Escuchar") \(title)",systemImage:playing ? "stop.circle" : "play.circle")
        }
        .buttonStyle(.borderless).disabled(!session.canPreview(at:time))
        .frame(minHeight:44).accessibilityIdentifier(identifier)
        .accessibilityValue(playing ? "Reproduciendo" : "Detenido")
    }
}

private struct LyricsRepairEditView: View {
    let session: LyricsRepairSession
    let proposal: LyricsRepair.Proposal
    let timed: Bool
    let issue: LyricsRepair.TimingIssue?
    let apply: (String,Double?) -> Void
    @State private var text: String
    @State private var startText: String
    @Environment(\.dismiss) private var dismiss
    init(session:LyricsRepairSession,proposal:LyricsRepair.Proposal,edit:LyricsRepair.Edit,timed:Bool,issue:LyricsRepair.TimingIssue?,apply:@escaping (String,Double?) -> Void) {
        self.session = session
        self.proposal = proposal; self.timed = timed; self.issue = issue; self.apply = apply
        _text = State(initialValue:edit.text)
        _startText = State(initialValue:String(format:"%.2f",((edit.startTime ?? proposal.start ?? 0) * 100).rounded() / 100))
    }
    private var parsedStart: Double? {
        guard let time = Double(startText.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:",",with:".")), time.isFinite else { return nil }
        return time
    }
    var body: some View {
        NavigationStack {
            Form {
                if !proposal.original.isEmpty { Section(proposal.kind == .timing ? "Frase" : "Original") { Text(proposal.original).textSelection(.enabled) } }
                if proposal.kind != .timing {
                    Section("Tu corrección") { TextEditor(text:$text).frame(minHeight:150).accessibilityLabel("Texto corregido").accessibilityIdentifier("repairEditText") }
                }
                if timed && proposal.allowsTimingEdit {
                    Section("Inicio del fragmento") {
                        if let original = proposal.originalStart, proposal.kind == .timing {
                            Text("Inicio actual: \(lyricRepairTimestamp(original))")
                            LyricsRepairAudioButton(session:session,proposal:proposal,reference:.current,time:original,
                                                    title:"inicio actual",identifier:"repairListenCurrentEdit-\(proposal.id)")
                        }
                        TextField("Segundos",text:$startText).keyboardType(.decimalPad)
                            .accessibilityIdentifier("repairEditTime")
                        if parsedStart == nil { Text("Escribe un inicio válido en segundos.").foregroundStyle(.red) }
                        LyricsRepairAudioButton(session:session,proposal:proposal,reference:.proposed,time:parsedStart,
                                                title:"este inicio",identifier:"repairListenEdited-\(proposal.id)")
                        if let issue { Text("Inicio permitido: \(lyricRepairTimestamp(issue.minimum)) – \(lyricRepairTimestamp(issue.maximum))").font(.footnote).foregroundStyle(.secondary) }
                    }
                } else if issue != nil {
                    Text("Revisa los saltos de línea de esta corrección o conserva el fragmento original.").font(.footnote)
                }
            }
            .navigationTitle("Editar propuesta").navigationBarTitleDisplayMode(.inline)
            .onChange(of:startText) { session.stopPreview() }
            .onChange(of:session.player.currentTime) { session.checkPreview() }
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Usar corrección") { apply(text,timed && proposal.allowsTimingEdit ? parsedStart : proposal.start); dismiss() }
                        .disabled(timed && proposal.allowsTimingEdit && parsedStart == nil)
                        .accessibilityIdentifier("repairUseEdit")
                }
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
                            if let time = line.time { Text(lyricRepairTimestamp(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            Text(line.text).font(.title3).textSelection(.enabled)
                        }
                    }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
            .accessibilityIdentifier("repairPreviewContent")
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
