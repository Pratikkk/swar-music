#if DEBUG
import Decoding
import FormatInfo
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only visual harness. Decodes real files without changing an audio device.
@MainActor
public struct FormatChipPreview: View {
    private enum Scenario: String, CaseIterable {
        case unavailable = "Unavailable"
        case matching = "Matching format"
        case floating = "Float output"
        case resampled = "Resampled"
    }
    private enum Appearance: String, CaseIterable {
        case light = "Light", dark = "Dark"
        var scheme: ColorScheme { self == .light ? .light : .dark }
    }

    @State private var source: SourceFormat?
    @State private var filename = "No file decoded"
    @State private var errorMessage: String?
    @State private var importing = false
    @State private var decoding = false
    @State private var scenario: Scenario = .unavailable
    @State private var appearance: Appearance = .light
    @State private var increasedContrast = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Format Chip Preview").font(.title2.bold())
            Text("Decode a real file without opening an audio output. Output scenarios below are simulated.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Decode Audio File…") { importing = true }.disabled(decoding)
                if decoding { ProgressView().controlSize(.small) }
                Text(filename).lineLimit(1)
            }
            Picker("Output scenario", selection: $scenario) {
                ForEach(Scenario.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if let source {
                FormatChip(info: FormatClassifier.describe(source: source, path: path(for: source)),
                           increasedContrastPreview: increasedContrast)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Choose a file to inspect its decoder-reported format.")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
            HStack {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Chip contrast", isOn: $increasedContrast)
            }
        }
        .padding(30)
        .frame(minWidth: 600, minHeight: 380)
        .preferredColorScheme(appearance.scheme)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                decoding = true
                Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        decoding = false
                    }
                    do {
                        let decoded = try await Task.detached(priority: .userInitiated) {
                            try DecoderFactory.open(url: url).source
                        }.value
                        source = decoded
                        filename = url.lastPathComponent
                        errorMessage = nil
                    } catch {
                        source = nil
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func path(for source: SourceFormat) -> SignalPath {
        guard scenario != .unavailable else { return SignalPath() }
        let output = SignalOutput(name: "Simulated output",
            sampleRate: scenario == .resampled ? (source.sampleRate == 48_000 ? 44_100 : 48_000) : source.sampleRate,
            bitDepth: scenario == .floating ? 32 : source.bitDepth,
            channels: source.channels, isFloat: scenario == .floating || source.isFloat)
        return SignalPath(output: output)
    }
}
#endif
