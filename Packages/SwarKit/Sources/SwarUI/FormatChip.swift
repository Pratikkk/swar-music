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

    private var statusColor: Color {
        switch info.status {
        case .unverified: .secondary
        case .converted: .orange
        case .bitPerfect: .teal
        }
    }

    private var explanation: String {
        switch info.status {
        case .unverified: info.output == nil ? "Start playback to inspect the active output. Source details are available now." : "Matching formats alone don’t verify unchanged samples."
        case .converted: "A known conversion is present in this playback path."
        case .bitPerfect: "Sample integrity is verified for this playback path."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio path").font(.system(size: 22, weight: .semibold, design: .serif))
                }
                Spacer()
                Image(systemName: "waveform.path").font(.title2).foregroundStyle(SwarTheme.accent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stage(1, title: "Source", symbol: "doc.waveform") {
                        Text(info.sourceDetail).font(.callout)
                        Text(info.source.isLossless ? "Lossless source file" : "Lossy source file")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    stage(2, title: "Playback path", symbol: "waveform") {
                        if info.output == nil && info.conversionReasons.isEmpty {
                            Text("Start playback to inspect this stage.").font(.callout)
                        } else if info.conversionReasons.isEmpty {
                            Text("No format changes reported").font(.callout)
                        } else {
                            ForEach(info.conversionReasons, id: \.self) { reason in
                                Label(reason, systemImage: "arrow.triangle.2.circlepath")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                        }
                        Text(info.output == nil ? "Output path not active" : (info.isExclusive ? "Exclusive device access" : "Shared macOS output"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    stage(3, title: "Output", symbol: "speaker.wave.2") {
                        Text(info.output?.name ?? "Output unavailable").font(.callout.weight(.medium))
                        Text(info.outputDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label(info.status.rawValue, systemImage: statusSymbol)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(statusColor)
                        Text(explanation).font(.callout)
                        ForEach(info.verificationNotes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(statusColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }.padding(.trailing, 4)
            }
        }
        .padding(20).frame(width: 410, height: 550)
        .background(SwarTheme.canvas).tint(SwarTheme.accent)
        .textSelection(.enabled)
    }

    private func stage<Content: View>(_ number: Int, title: String, symbol: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SwarTheme.accent).frame(width: 24, height: 24)
                .background(SwarTheme.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14).background(SwarTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview("Hi-Res, converted output") {
    FormatChip(info: FormatClassifier.describe(
        source: SourceFormat(codec: "ALAC", sampleRate: 96_000, bitDepth: 24, channels: 2, isLossless: true),
        path: SignalPath(output: SignalOutput(name: "External Headphones", sampleRate: 96_000,
                                            bitDepth: 32, channels: 2, isFloat: true))))
        .padding(30)
}
