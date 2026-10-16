import SwiftUI

struct PlaylistNameEditor: View {
    let initialName: String
    let renaming: Bool
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre de la playlist") {
                    TextField("Nombre", text: $name).focused($focused).submitLabel(.done)
                        .accessibilityIdentifier("playlistName")
                        .onSubmit { commit() }
                }
            }
            .navigationTitle(renaming ? "Renombrar playlist" : "Nueva playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(renaming ? "Guardar" : "Crear") { commit() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { name = initialName; focused = true }
        }
    }
    private func commit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value); dismiss()
    }
}
