import SwiftUI
import Player
import Decoding

private struct WaveformRequest: Equatable {
    let url: URL?
    let enabled: Bool
    let revision: UInt64
}

@MainActor
struct PlaybackSeekControl: View {
    let player: Player
    @Binding var state: SeekSliderState
    var mini = false
    @AppStorage("waveformSeekBar") private var waveformEnabled = true
    @State private var samples: [Float] = []
    @State private var waveformURL: URL?
    @State private var waveformUnavailable = false

    private var waveformRequest: WaveformRequest {
        WaveformRequest(url: player.currentURL, enabled: waveformEnabled, revision: player.sourceRevision)
    }

    var body: some View {
        Group {
            if waveformEnabled {
                WaveformSeekSurface(samples: waveformURL == player.currentURL ? samples : [],
                    progress: player.duration > 0 ? state.displayedPosition(player.position) / player.duration : 0,
                    mini: mini, changed: { fraction in
                        if !state.dragging { state.begin() }
                        state.change(to: fraction * player.duration)
                    }, ended: { fraction in
                        state.change(to: fraction * player.duration)
                        if let request = state.end() { commit(request) }
                    }, step: { delta in
                        state.change(to: state.displayedPosition(player.position) + delta)
                        if let request = state.request() { commit(request) }
                    })
                    .id(player.sourceRevision)
                    .accessibilityRepresentation { nativeSlider }
                    .help(waveformUnavailable ? "Waveform unavailable. Click or drag to seek." : "Click or drag the waveform to seek.")
            } else { nativeSlider }
        }
        .disabled(player.duration <= 0)
        .allowsHitTesting(!player.isBusy || player.isSeeking)
        .task(id: state.dragging) {
            guard state.dragging else { return }
            var lastPosition: Double? = player.position
            while state.dragging && !Task.isCancelled {
                // Send an explicit end-of-song seek only when the pointer is released.
                if lastPosition != state.value, player.duration - state.value > 0.05,
                   let request = state.request() {
                    lastPosition = request.position
                    await write(request)
                }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
        }
        .onChange(of: player.currentURL, initial: true) { synchronize() }
        .onChange(of: player.position) { synchronize() }
        .onChange(of: player.duration) { synchronize() }
        .onChange(of: player.sourceRevision) { cancel() }
        .onChange(of: player.isSeeking) {
            state.settle(position: player.position, seeking: player.isSeeking)
        }
        .onChange(of: player.isBusy) {
            if player.isBusy && !player.isSeeking { cancel() }
        }
        .onDisappear { cancel() }
        .task(id: waveformRequest) {
            let request = waveformRequest
            samples = []; waveformURL = nil; waveformUnavailable = false
            guard request.enabled, let url = request.url else { return }
            do {
                let result = try await WaveformStore.shared.waveform(url: url, accessRoot: player.currentAccessRoot ?? url)
                guard !Task.isCancelled, waveformRequest == request else { return }
                samples = result; waveformURL = url
            } catch {
                guard !Task.isCancelled, waveformRequest == request else { return }
                waveformUnavailable = true
            }
        }
        .onChange(of: waveformEnabled) { cancel() }
    }

    private var nativeSlider: some View {
        Slider(value: Binding(get: { state.displayedPosition(player.position) }, set: {
            state.change(to: $0)
            if !state.dragging, let request = state.request() { commit(request) }
        }), in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
            if editing { state.begin() }
            else if let request = state.end() { commit(request) }
        })
        .controlSize(mini ? .mini : .regular)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(state.displayedPosition(player.position))) of \(Int(max(0, player.duration))) seconds")
    }

    private func synchronize() {
        state.synchronize(position: player.position, duration: player.duration, url: player.currentURL)
    }

    private func cancel() {
        state.cancel(position: player.position, duration: player.duration, url: player.currentURL)
    }

    private func commit(_ request: SeekSliderState.Request) {
        Task { await write(request) }
    }

    private func write(_ request: SeekSliderState.Request) async {
        guard !Task.isCancelled else { return }
        guard request.url == player.currentURL, player.duration > 0,
              !player.isBusy || player.isSeeking else { cancel(); return }
        guard state.submit(request) else { return }
        await player.seek(to: request.position)
        guard request.url == player.currentURL else { synchronize(); return }
        state.finish(request, position: player.position, seeking: player.isSeeking)
    }
}
