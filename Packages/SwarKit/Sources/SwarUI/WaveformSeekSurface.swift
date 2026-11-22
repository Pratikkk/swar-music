import SwiftUI

private struct WaveformGeometryRequest: Equatable {
    let samples: [Float]
    let size: CGSize
    let mini: Bool
}

/// Cached song geometry stays still; only the progress mask and pointer feedback move.
/// Uses Canvas + drawingGroup for Metal-backed GPU rendering at 120 Hz on ProMotion.
@MainActor
struct WaveformSeekSurface: View {
    let samples: [Float]
    let progress: Double
    let duration: Double
    let mini: Bool
    var isPlaying: Bool = false
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
    // State for 120 Hz interpolation: track last known base progress and when it was observed
    @State private var lastBaseProgress: Double = 0
    @State private var lastBaseTime: TimeInterval = 0
    @State private var cachedPath: Path = Path()
    @StateObject private var occlusionObserver = OcclusionObserver.shared

    var body: some View {
        // TimelineView drives 120 Hz interpolation on ProMotion when playing,
        // pausing when playback stops, at end of track, or when app is occluded/backgrounded.
        // The base `progress` comes from the low-frequency player.position (~25 Hz / 40 ms timer).
        // We interpolate between updates using the timeline's high-resolution date.
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !isPlaying || progress >= 1.0 || duration <= 0 || progress.isNaN || progress.isInfinite || occlusionObserver.shouldPauseAnimations)) { timeline in
            waveformView(progress: displayProgress(at: timeline.date))
        }
        .onChange(of: progress, initial: true) { _, newProgress in
            guard newProgress.isFinite, (0...1).contains(newProgress) else { return }
            lastBaseProgress = newProgress
            lastBaseTime = Date.timeIntervalSinceReferenceDate
        }
    }

    private func displayProgress(at date: Date) -> Double {
        let now = date.timeIntervalSinceReferenceDate
        let extrapolatedProgress = duration > 0 && lastBaseTime > 0
            ? min(1, max(0, lastBaseProgress + (now - lastBaseTime) / duration))
            : progress
        return extrapolatedProgress.isFinite ? max(0, min(1, extrapolatedProgress)) : 0
    }

    private func waveformView(progress: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let played = progress
            let dragging = pointerDragging || isDragging
            let preview = dragging ? played : hoverFraction
            let request = WaveformGeometryRequest(samples: samples, size: geometry.size, mini: mini)

            Canvas { context, size in
                let path = cachedPath.isEmpty ? Self.path(samples: request.samples, size: request.size, mini: request.mini) : cachedPath
                context.fill(path, with: .color(.primary.opacity(colorScheme == .dark ? 0.25 : 0.19)))

                var playedContext = context
                playedContext.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * played, height: size.height)))
                playedContext.fill(path, with: .color(palette.accent))

                let playheadX = Self.markerX(played, width: size.width)
                let playheadRect = CGRect(x: playheadX, y: 1, width: 1, height: size.height - 2)
                context.fill(Path(playheadRect), with: .color(palette.accent.opacity(0.9)))

                if let preview, !dragging {
                    let previewX = Self.markerX(preview, width: size.width)
                    let previewRect = CGRect(x: previewX, y: 1, width: 1, height: size.height - 2)
                    context.fill(Path(previewRect), with: .color(palette.accent.opacity(0.55)))
                    let circleRect = CGRect(
                        x: max(0, min(max(0, size.width - 6), previewX - 3)),
                        y: (size.height - 6) / 2,
                        width: 6, height: 6
                    )
                    context.fill(Path(ellipseIn: circleRect), with: .color(palette.accent))
                }
            }
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .frame(height: mini ? 24 : 44)
            .onChange(of: request, initial: true) { _, newRequest in
                cachedPath = Self.path(samples: newRequest.samples, size: newRequest.size, mini: newRequest.mini)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    pointerDragging = true
                    focused = true
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
            .focusable().focused($focused).focusEffectDisabled()
            .overlay {
                // Subtle focus ring that only appears when focused, matching bottom player style
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(focused ? palette.accent.opacity(0.35) : .clear, lineWidth: 1)
                    .padding(-2).allowsHitTesting(false)
            }
            .onKeyPress(.leftArrow) { step(mini ? -1 : -5); return .handled }
            .onKeyPress(.rightArrow) { step(mini ? 1 : 5); return .handled }
            .onChange(of: isDragging) { if !isDragging { pointerDragging = false } }
            .onDisappear { pointerDragging = false; hoverFraction = nil }
            .accessibilityHidden(true)
        }
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
        // Bottom inset for proper baseline alignment (matches mini player bar)
        let bottomInset: CGFloat = 2
        guard !values.isEmpty else {
            return Path(roundedRect: CGRect(x: 0, y: size.height - bottomInset - 1, width: size.width, height: 1), cornerRadius: 0.5)
        }
        let cell = size.width / CGFloat(values.count)
        let gap = min(mini ? 1.5 : 1.75, cell * 0.4)
        // Use full available height minus bottom inset for proper baseline alignment
        let availableHeight = size.height - bottomInset
        var path = Path()
        for (index, amplitude) in values.enumerated() {
            let barHeight = max(1.5, availableHeight * CGFloat(amplitude))
            let height = min(availableHeight, max(1.5, availableHeight * CGFloat(amplitude)))
            path.addRoundedRect(in: CGRect(x: CGFloat(index) * cell + gap / 2,
                y: size.height - bottomInset - height, width: cell - gap, height: height),
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
