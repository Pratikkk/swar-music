import SwiftUI
import Player

@MainActor
struct PlaybackSeekControl: View {
    let player: Player
    @Binding var state: SeekSliderState
    var mini = false

    var body: some View {
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
        .onChange(of: player.isSeeking) {
            state.settle(position: player.position, seeking: player.isSeeking)
        }
        .onChange(of: player.isBusy) {
            if player.isBusy && !player.isSeeking { cancel() }
        }
        .onDisappear { cancel() }
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
