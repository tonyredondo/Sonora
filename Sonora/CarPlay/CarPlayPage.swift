import CarPlay
import UIKit

@MainActor struct CarPlayRow {
    let title: String
    var subtitle: String? = nil
    var symbol = "waveform"
    var artwork: (() -> UIImage?)? = nil
    var playing = false
    var selected = false
    var enabled = true
    var disclosure = false
    let action: () -> Void

    func item() -> CPListItem {
        let image = artwork?() ?? UIImage(systemName: symbol)
        let item = CPListItem(text: title, detailText: subtitle, image: image)
        item.isPlaying = playing
        item.playingIndicatorLocation = .trailing
        item.isEnabled = enabled
        if selected { item.setAccessoryImage(UIImage(systemName: "checkmark")) }
        else if disclosure { item.accessoryType = .disclosureIndicator }
        item.handler = { _, done in
            defer { done() }
            if enabled { action() }
        }
        return item
    }
}

/// A template owns its page. The coordinator keeps only weak references, so
/// popped pages release their rows, images and observation work.
@MainActor final class CarPlayPage {
    weak var template: CPListTemplate?
    private let rows: () -> [CarPlayRow]
    private let featured: () -> CPListImageRowItem?
    private var offset = 0
    private let pageSize = max(1, min(96, Int(CPListTemplate.maximumItemCount) - 3))

    init(template: CPListTemplate, rows: @escaping () -> [CarPlayRow],
         featured: @escaping () -> CPListImageRowItem? = { nil }) {
        self.template = template; self.rows = rows; self.featured = featured
        update()
    }

    func update() {
        let values = rows()
        offset = min(offset, max(0, values.count - 1) / pageSize * pageSize)
        var items: [CPListTemplateItem] = []
        if offset == 0, let featured = featured() { items.append(featured) }
        if offset > 0 {
            let previous = CPListItem(text: "Anterior", detailText: nil, image: UIImage(systemName: "chevron.left"))
            previous.handler = { [weak self] _, done in
                if let self { offset = max(0, offset - pageSize); update() }
                done()
            }
            items.append(previous)
        }
        // Resolve artwork only for this page, never for the entire collection.
        items.append(contentsOf: values.dropFirst(offset).prefix(pageSize).map { $0.item() })
        if offset + pageSize < values.count {
            let next = CPListItem(text: "Más", detailText: "\(offset + pageSize) de \(values.count)",
                                  image: UIImage(systemName: "chevron.right"))
            next.handler = { [weak self] _, done in
                if let self { offset += pageSize; update() }
                done()
            }
            items.append(next)
        }
        template?.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }
}

@MainActor struct WeakCarPlayPage {
    weak var value: CarPlayPage?
}
