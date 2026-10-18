import SwiftUI
import UIKit

struct ServiceIssueView: View {
    let message: String
    private var summary: String {
        guard let range = message.range(of: "HTTP ") else { return message }
        return String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.isEmpty ? "No se pudo completar la consulta." : summary).foregroundStyle(.red)
            DisclosureGroup("Detalles técnicos") {
                Text(message).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copiar diagnóstico", systemImage: "doc.on.doc") { UIPasteboard.general.string = message }
                    .frame(minHeight: 44)
            }
        }
    }
}
