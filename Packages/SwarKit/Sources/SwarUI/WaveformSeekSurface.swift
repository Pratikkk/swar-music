import SwiftUI

/// A song overview, not an FFT or a simulated live spectrum. Only progress moves.
@MainActor
struct WaveformSeekSurface: View {
    let samples: [Float]
    let progress: Double
    let mini: Bool
    let changed: (Double) -> Void
    let ended: (Double) -> Void
    let step: (Double) -> Void
    @Environment(\.swarPalette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        let accent = palette.accent
        GeometryReader { geometry in
            Canvas { context, size in
                let path = Self.path(samples: samples, size: size)
                context.fill(path, with: .color(.secondary.opacity(0.32)))
                context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * max(0, min(1, progress)), height: size.height)))
                context.fill(path, with: .color(accent))
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(accent)
                    .frame(width: 2).offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * progress)))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in focused = true; changed(Self.fraction(value.location.x, width: geometry.size.width)) }
                .onEnded { value in ended(Self.fraction(value.location.x, width: geometry.size.width)) })
        }
        .frame(height: mini ? 16 : 40)
        .focusable().focused($focused).focusEffectDisabled()
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(focused ? accent.opacity(0.7) : .clear, lineWidth: 1).padding(-2) }
        .onKeyPress(.leftArrow) { step(-5); return .handled }
        .onKeyPress(.rightArrow) { step(5); return .handled }
    }

    nonisolated static func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return max(0, min(1, Double(x / width)))
    }

    nonisolated private static func path(samples: [Float], size: CGSize) -> Path {
        guard !samples.isEmpty else {
            return Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2), cornerRadius: 1)
        }
        let bars = max(1, min(256, Int(size.width / 3)))
        let width = size.width / CGFloat(bars)
        let maximum = max(0.000001, samples.max() ?? 0)
        var path = Path()
        for index in 0..<bars {
            let start = index * samples.count / bars
            let end = max(start + 1, (index + 1) * samples.count / bars)
            let peak = samples[start..<min(end, samples.count)].max() ?? 0
            let height = max(2, size.height * CGFloat(pow(Double(peak / maximum), 0.55)))
            path.addRoundedRect(in: CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2,
                                          width: max(1, width - 1), height: height), cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}
