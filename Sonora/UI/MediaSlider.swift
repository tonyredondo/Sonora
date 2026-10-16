import SwiftUI
import UIKit

/// Native media sliders share thumb-free styling while retaining system gestures and accessibility.
struct MediaSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let label: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if #available(iOS 26.0, *) {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .sliderThumbVisibility(.hidden).tint(tint).accessibilityLabel(label)
        } else {
            LegacyMediaSlider(value: $value, range: range, tint: tint,
                              label: label, onEditingChanged: onEditingChanged)
        }
    }
}

private struct LegacyMediaSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let label: String
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        for state: UIControl.State in [.normal, .highlighted, .disabled] {
            slider.setThumbImage(MediaSliderImages.invisibleThumb, for: state)
        }
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        if !slider.isTracking { slider.value = Float(value) }
        slider.isEnabled = context.environment.isEnabled
        slider.tintColor = UIColor(tint)
        slider.accessibilityLabel = label
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: 44)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: LegacyMediaSlider
        init(_ parent: LegacyMediaSlider) { self.parent = parent }
        @objc func began(_ slider: UISlider) {
            parent.value = Double(slider.value)
            parent.onEditingChanged(true)
        }
        @objc func changed(_ slider: UISlider) {
            // VoiceOver adjustments arrive without a touch-down/touch-up pair.
            if !slider.isTracking { parent.onEditingChanged(true) }
            parent.value = Double(slider.value)
            if !slider.isTracking { parent.onEditingChanged(false) }
        }
        @objc func ended() { parent.onEditingChanged(false) }
    }
}

@MainActor enum MediaSliderImages {
    // Keep a nonzero thumb size for native hit testing while drawing no handle.
    static let invisibleThumb = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in }
}

