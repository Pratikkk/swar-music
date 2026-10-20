import SwiftUI

private struct WaveformGeometryRequest: Equatable {
    let samples: [Float]
    let size: CGSize
    let mini: Bool
}

/// Cached song geometry stays still; only the progress mask and pointer feedback move.
@MainActor
struct WaveformSeekSurface: View {
    let samples: [Float]
    let progress: Double
    let duration: Double
    let mini: Bool
    var cornerRadius: CGFloat = 6
    var isDragging = false
    let changed: (Double) -> Void
    let ended: (Double) -> Void
    let step: (Double) -> Void
    @Environment(\.swarPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool
    @State private var hoverFraction: Double?
    @State private var pointerDragging = false
    @State private var cachedPath = Path()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let played = progress.isFinite ? max(0, min(1, progress)) : 0
            let dragging = pointerDragging || isDragging
            let preview = dragging ? played : hoverFraction
            let request = WaveformGeometryRequest(samples: samples, size: geometry.size, mini: mini)

            ZStack(alignment: .leading) {
                cachedPath.fill(.primary.opacity(colorScheme == .dark ? 0.25 : 0.19))
                cachedPath.fill(palette.accent)
                    .mask(alignment: .leading) { Rectangle().frame(width: width * played) }
                Rectangle().fill(palette.accent.opacity(0.9))
                    .frame(width: 1).padding(.vertical, 1)
                    .offset(x: Self.markerX(played, width: width))
                    .allowsHitTesting(false)
                if let preview {
                    let x = Self.markerX(preview, width: width)
                    Rectangle().fill(palette.accent.opacity(0.55)).frame(width: 1)
                        .offset(x: x).allowsHitTesting(false)
                    Circle().fill(palette.accent).frame(width: 6, height: 6)
                        .offset(x: max(0, min(max(0, width - 6), x - 3)))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    pointerDragging = true
                    focused = true
                    // The first event must reach the owner so it can begin scrubbing.
                    changed(Self.fraction(value.location.x, width: width))
                }
                .onEnded { value in
                    pointerDragging = false
                    hoverFraction = nil
                    ended(Self.fraction(value.location.x, width: width))
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if !dragging {
                        let newFraction = Self.fraction(location.x, width: width)
                        // Throttle: only update hover when position changes by
                        // more than ~3 pixels, avoiding per-pixel view invalidation.
                        if let current = hoverFraction {
                            let delta = abs(newFraction - current) * width
                            guard delta > 3 else { break }
                        }
                        hoverFraction = newFraction
                    }
                case .ended: hoverFraction = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let preview, duration.isFinite, duration > 0 {
                    Text(Self.timeString(preview * duration))
                        .font(.system(size: mini ? 10 : 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .frame(minWidth: 56)
                        .background(.regularMaterial, in: Capsule())
                        .fixedSize()
                        .offset(x: max(0, min(max(0, width - 64), width * preview - 32)), y: mini ? -54 : -27)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: request, initial: true) {
                cachedPath = Self.path(samples: request.samples, size: request.size, mini: request.mini)
            }
        }
        .frame(height: mini ? 24 : 44)
        .focusable().focused($focused).focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(focused ? palette.accent.opacity(0.65) : .clear, lineWidth: 1)
                .padding(-3).allowsHitTesting(false)
        }
        .onKeyPress(.leftArrow) { step(mini ? -1 : -5); return .handled }
        .onKeyPress(.rightArrow) { step(mini ? 1 : 5); return .handled }
        .onChange(of: isDragging) { if !isDragging { pointerDragging = false } }
        .onDisappear { pointerDragging = false; hoverFraction = nil }
        // PlaybackSeekControl supplies a native accessible slider representation.
        .accessibilityHidden(true)
    }

    nonisolated static func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return max(0, min(1, Double(x / width)))
    }

    nonisolated static func markerX(_ fraction: Double, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, fraction.isFinite else { return 0 }
        return max(0, min(max(0, width - 1), width * CGFloat(fraction)))
    }

    /// One scale for the whole track. Pool energy without letting one peak fill every bar.
    nonisolated static func amplitudes(samples: [Float], count: Int) -> [Double] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let values = samples.map { $0.isFinite ? Double(max(0, min(1, $0))) : 0 }
        let maximum = values.max() ?? 0
        guard maximum > 0 else { return Array(repeating: 0, count: min(count, samples.count)) }
        let bars = min(count, samples.count)
        return (0..<bars).map { index in
            let start = index * values.count / bars
            let end = (index + 1) * values.count / bars
            let group = values[start..<end]
            let rms = sqrt(group.reduce(0) { $0 + $1 * $1 } / Double(group.count))
            let peak = group.max() ?? 0
            return min(1, (rms * 0.85 + peak * 0.15) / maximum)
        }
    }

    nonisolated static func path(samples: [Float], size: CGSize, mini: Bool) -> Path {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return Path() }
        let count = max(1, Int(min(mini ? 72 : 120, size.width / (mini ? 4 : 4.5))))
        let values = amplitudes(samples: samples, count: count)
        guard !values.isEmpty else {
            return Path(roundedRect: CGRect(x: 0, y: (size.height - 1) / 2, width: size.width, height: 1), cornerRadius: 0.5)
        }
        let cell = size.width / CGFloat(values.count)
        let gap = min(mini ? 1.5 : 1.75, cell * 0.4)
        let availableHeight = max(1, size.height - 4)
        var path = Path()
        for (index, amplitude) in values.enumerated() {
            let height = min(size.height, max(min(1.5, size.height), availableHeight * CGFloat(amplitude)))
            path.addRoundedRect(in: CGRect(x: CGFloat(index) * cell + gap / 2,
                y: (size.height - height) / 2, width: cell - gap, height: height),
                cornerSize: CGSize(width: min(1.5, cell / 2), height: 1.5))
        }
        return path
    }

    nonisolated static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
