import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Library

@MainActor
enum LocalLyricsPicker {
    static func choose() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Lyrics File"
        panel.message = "Choose a UTF-8 .lrc file. The original file stays where it is."
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                MainActor.assumeIsolated { continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
        }
    }
}

@MainActor
struct LyricsSettingsView: View {
    let track: LibraryTrack
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var delay = 0.0
    @State private var ready = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Lyrics Timing").font(.title2.bold())
            Text(track.title).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text("Adjustment")
                Spacer()
                TextField("Seconds", value: $delay, format: .number.precision(.fractionLength(1)))
                    .frame(width: 70).multilineTextAlignment(.trailing)
                Text("seconds").foregroundStyle(.secondary)
            }
            HStack {
                Button("Earlier −0.1s") { delay = max(-60, delay - 0.1) }
                Button("Later +0.1s") { delay = min(60, delay + 0.1) }
                Spacer()
                Button("Reset") { delay = 0 }
            }
            Text("Negative values show lyrics earlier; positive values show them later. Saved for this song only. The lyrics file stays unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        do { try await library.setLyricsDelay(delay, for: track.id); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || saving || !delay.isFinite || abs(delay) > 60)
            }
        }
        .padding(24).frame(width: 430)
        .task {
            do { delay = try await library.lyricsSettings(for: track.id).delay; ready = true }
            catch { self.error = error.localizedDescription }
        }
    }
}
