import SwiftUI

/// A gradient slider that previews instantly and sends updates while dragging, one request at a
/// time: a request in flight is never cancelled, and the newest value goes out once it completes.
/// Follows `remote` whenever the user isn't touching it.
struct LiveSlider: View {
    var remote: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var gradient: Gradient
    var format: (Double) -> String
    var commit: (Double) async -> Void

    @State private var local: Double = 0
    @State private var isDragging = false
    @State private var queue: CommitQueue<Double>?

    var body: some View {
        VStack(spacing: 6) {
            GradientSlider(value: $local, in: range, step: step, gradient: gradient) { dragging in
                isDragging = dragging
                if !dragging { send(local) }
            }
            .onChange(of: local) { _, newValue in
                if isDragging { send(newValue) }
            }
            Text(format(local))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear { local = remote.clamped(to: range) }
        .onChange(of: remote) { _, newValue in
            if !isDragging { local = newValue.clamped(to: range) }
        }
    }

    private func send(_ value: Double) {
        if queue == nil { queue = CommitQueue(commit: commit) }
        queue?.send(value)
    }
}

struct GradientSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var gradient: Gradient
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    private let trackHeight: CGFloat = 26
    private let knobSize: CGFloat = 32

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1,
         gradient: Gradient, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.gradient = gradient
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - knobSize, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobX = CGFloat(fraction.clamped(to: 0...1)) * travel + knobSize / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackHeight)
                    .padding(.horizontal, (knobSize - trackHeight) / 2)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.08)).padding(.horizontal, (knobSize - trackHeight) / 2))
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .position(x: knobX, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let f = Double(((drag.location.x - knobSize / 2) / travel).clamped(to: 0...1))
                        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        value = ((raw / step).rounded() * step).clamped(to: range)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: knobSize)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? step : -step
            value = (value + delta).clamped(to: range)
            onEditingChanged(true)
            onEditingChanged(false)
        }
    }
}
