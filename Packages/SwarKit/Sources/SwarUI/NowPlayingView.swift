import SwiftUI
import Player

@MainActor
struct NowPlayingView: View {
    let player: Player
    let width: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).accessibilityLabel("Close Now Playing")
                    .keyboardShortcut(.cancelAction)
                    .help("Return to Library (Escape)")
                Text("Now Playing").font(.headline)
                Spacer()
                SleepTimerMenu(timer: player.sleepTimer)
                Toggle(isOn: $showQueue) {
                    Label("Up Next · \(player.upcomingEntries.count)", systemImage: "list.bullet")
                }
                .toggleStyle(.button)
                .accessibilityLabel(showQueue ? "Hide Up Next" : "Show Up Next")
            }
            .padding(20)
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if !showQueue || geometry.size.width >= 760 {
                        ScrollView {
                            PlaybackControls(player: player, expanded: true)
                                .padding(.vertical, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if showQueue {
                        if geometry.size.width >= 760 { Divider() }
                        QueueView(player: player, embedded: true)
                            .frame(width: geometry.size.width >= 760 ? 320 : geometry.size.width)
                            .frame(maxHeight: .infinity)
                            .background(.quaternary.opacity(0.25))
                    }
                }
            }
        }
        .frame(width: width, height: 650)
        .onExitCommand { dismiss() }
    }
}
