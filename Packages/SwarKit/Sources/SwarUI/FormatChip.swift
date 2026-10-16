import SwiftUI
import FormatInfo
import Decoding

/// Reusable for the toolbar, queue, and Now Playing views as those surfaces arrive.
public struct FormatChip: View {
    public let info: FormatChipInfo
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showSignalPath = false
    private var previewIncreasedContrast = false

    public init(info: FormatChipInfo) { self.info = info }

    #if DEBUG
    init(info: FormatChipInfo, increasedContrastPreview: Bool) {
        self.info = info
        self.previewIncreasedContrast = increasedContrastPreview
    }
    #endif

    private var accented: Bool { info.tier == .hiResLossless || info.tier == .dsd }
    private var highContrast: Bool { contrast == .increased || previewIncreasedContrast }

    public var body: some View {
        Button { showSignalPath.toggle() } label: {
            HStack(spacing: 5) {
                if accented { Image(systemName: "waveform").accessibilityHidden(true) }
                Text(info.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                if info.status == .converted {
                    Circle().fill(.orange).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(accented ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(accented ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(highContrast ? 0.6 : 0.15), lineWidth: highContrast ? 1.5 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityHint("Show source format and output signal path")
        .help("Source: \(info.sourceDetail)\nOutput: \(info.output.map { $0.name + " · " } ?? "")\(info.outputDetail)\n\(info.status.rawValue)")
        .popover(isPresented: $showSignalPath, arrowEdge: .top) {
            SignalPathPopover(info: info)
        }
    }
}

private struct SignalPathPopover: View {
    let info: FormatChipInfo

    private var statusSymbol: String {
        switch info.status {
        case .unverified: "questionmark.circle"
        case .converted: "arrow.triangle.2.circlepath"
        case .bitPerfect: "checkmark.seal"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Signal Path").font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                Label("Source", systemImage: "doc.waveform")
                    .font(.subheadline.weight(.semibold))
                Text(info.sourceDetail)
                    .font(.callout).foregroundStyle(.secondary)
                Text(info.source.isLossless ? "Lossless source" : "Lossy source")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label(info.output?.name ?? "Output unavailable", systemImage: "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                if info.output != nil {
                    Text(info.outputDetail)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Label(info.isExclusive ? "Exclusive mode" : "Shared output",
                      systemImage: info.isExclusive ? "lock.fill" : "speaker.wave.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label(info.status.rawValue, systemImage: statusSymbol)
                    .font(.subheadline.weight(.semibold))
                ForEach(info.conversionReasons, id: \.self) { reason in
                    Text(reason).font(.callout)
                }
                ForEach(info.verificationNotes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 350, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

#Preview("Hi-Res, converted output") {
    FormatChip(info: FormatClassifier.describe(
        source: SourceFormat(codec: "ALAC", sampleRate: 96_000, bitDepth: 24, channels: 2, isLossless: true),
        path: SignalPath(output: SignalOutput(name: "External Headphones", sampleRate: 96_000,
                                            bitDepth: 32, channels: 2, isFloat: true))))
        .padding(30)
}
