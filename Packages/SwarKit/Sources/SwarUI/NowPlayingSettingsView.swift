import SwiftUI

enum NowPlayingBackground: String, CaseIterable, Identifiable {
    case artwork, neutral
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Shared by Settings and the player so changes can be previewed while listening.
struct NowPlayingAppearanceControls: View {
    @AppStorage("nowPlayingBackground") private var background: NowPlayingBackground = .artwork
    @AppStorage("nowPlayingBlur") private var storedBlur = 70.0
    @AppStorage("nowPlayingTechnicalDetails") private var technicalDetails = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var blur: Binding<Double> {
        Binding(get: { NowPlayingBackdrop.blurRadius(storedBlur) }, set: { storedBlur = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Background", selection: $background) {
                ForEach(NowPlayingBackground.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Blur")
                    Spacer()
                    Text("\(Int(blur.wrappedValue))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: blur, in: 20...100, step: 5)
                    .accessibilityLabel("Artwork background blur")
                    .accessibilityValue("\(Int(blur.wrappedValue)) percent")
                    .disabled(background != .artwork || reduceTransparency)
            }
            Toggle("Show technical details", isOn: $technicalDetails)
            Text("Shows the audio format and signal path beneath the song title.")
                .font(.caption).foregroundStyle(.secondary)
            if reduceTransparency {
                Text("Reduce Transparency uses a neutral background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NowPlayingSettingsView: View {
    @AppStorage("waveformSeekBar") private var waveform = true
    var body: some View {
        Form {
            Section("Now Playing") { NowPlayingAppearanceControls() }
            Section("Seek Bar") {
                Toggle("Show song waveform", isOn: $waveform)
            }
        }.formStyle(.grouped)
    }
}

/// Artwork decoding is shared with CoverArt; neutral mode avoids creating the blurred layer.
struct NowPlayingBackdrop: View {
    let artworkURL: URL?
    @AppStorage("nowPlayingBackground") private var background: NowPlayingBackground = .artwork
    @AppStorage("nowPlayingBlur") private var storedBlur = 70.0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func blurRadius(_ value: Double) -> Double {
        value.isFinite ? min(100, max(20, value)) : 70
    }

    var body: some View {
        ZStack {
            SwarTheme.canvas
            if background == .artwork, !reduceTransparency, let artworkURL {
                CoverArt(url: artworkURL, crossfade: true)
                    .frame(width: 480, height: 480)
                    .blur(radius: Self.blurRadius(storedBlur)).scaleEffect(1.4)
                    .opacity(colorScheme == .dark ? 0.26 : 0.13)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
