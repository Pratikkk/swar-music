import SwiftUI
import Player

@MainActor
struct NowPlayingView: View {
    @Environment(\.swarPalette) private var palette
    let player: Player
    let width: CGFloat
    let browseArtist: (String) -> Void
    let browseAlbum: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close Now Playing")
                .keyboardShortcut(.cancelAction).help("Return to Library (Escape)")
                Text("Now Playing").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                SleepTimerMenu(timer: player.sleepTimer)
                Button { showQueue.toggle() } label: {
                    Label("Up Next · \(player.upcomingEntries.count)", systemImage: "list.bullet")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 28)
                        .foregroundStyle(showQueue ? palette.accent : .primary)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showQueue ? "Hide Up Next" : "Show Up Next")
                .accessibilityAddTraits(showQueue ? .isSelected : [])
            }
            .padding(.horizontal, 20).frame(height: 56)
            GeometryReader { geometry in
                let sideBySide = geometry.size.width >= 800
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if showQueue && !sideBySide {
                            QueueView(player: player, embedded: true)
                                .frame(maxHeight: .infinity)
                        } else {
                            NowPlayingArtwork(player: player, size: min(250, max(180, geometry.size.height * 0.40)),
                                browseArtist: { name in dismiss(); browseArtist(name) },
                                browseAlbum: { name in dismiss(); browseAlbum(name) })
                        }
                        ExpandedPlayerControls(player: player)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showQueue && sideBySide {
                        QueueView(player: player, embedded: true)
                            .frame(width: 300)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .padding(.trailing, 16).padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(width: width, height: 650)
        .background {
            SwarTheme.canvas
            if !reduceTransparency, player.artworkURL != nil {
                CoverArt(url: player.artworkURL, crossfade: true)
                    .frame(width: 480, height: 480).blur(radius: 70).scaleEffect(1.4)
                    .opacity(colorScheme == .dark ? 0.26 : 0.13)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipped().tint(palette.accent)
        .accentColor(palette.accent)
        .onExitCommand { dismiss() }
    }
}

@MainActor
private struct NowPlayingArtwork: View {
    let player: Player
    let size: CGFloat
    let browseArtist: (String) -> Void
    let browseAlbum: (String) -> Void
    @State private var showActivity = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        player.currentURL == nil ? (player.queue.isEmpty ? "Nothing Playing" : "Queue Ready") : player.title
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                CoverArt(url: player.artworkURL, title: player.title, cornerRadius: 14, crossfade: true)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .overlay {
                        ProgressView().controlSize(.small).padding(10)
                            .background(.regularMaterial, in: Circle()).opacity(showActivity ? 1 : 0)
                    }
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 23, weight: .semibold))
                        .lineLimit(2).frame(height: 54).frame(maxWidth: .infinity)
                        .textSelection(.enabled).help(title)
                        .contentTransition(.opacity)
                    metadata.frame(height: 18)
                    ZStack {
                        if let info = player.formatInfo { FormatChip(info: info) }
                    }.frame(height: 28)
                    status.frame(height: 26)
                }
                .frame(maxWidth: 440)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: player.currentURL)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: player.isBusy) {
            showActivity = false
            guard player.isBusy else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            showActivity = true
        }
    }

    @ViewBuilder private var metadata: some View {
        if player.currentArtist != nil || player.currentAlbum != nil {
            HStack(spacing: 6) {
                if let artist = player.currentArtist, !artist.isEmpty {
                    Button { browseArtist(artist) } label: { Text(artist).lineLimit(1) }
                        .help("Browse artist: " + artist).accessibilityLabel("Browse artist " + artist)
                }
                if let album = player.currentAlbum, !album.isEmpty {
                    if player.currentArtist?.isEmpty == false { Text("·").accessibilityHidden(true) }
                    Button { browseAlbum(album) } label: { Text(album).lineLimit(1) }
                        .help("Browse album: " + album).accessibilityLabel("Browse album " + album)
                }
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            Text(player.subtitle.isEmpty ? "Choose a song from your library" : player.subtitle)
                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var status: some View {
        if let error = player.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).lineLimit(2).help(error).textSelection(.enabled)
        } else if let notice = player.sessionNotice {
            HStack(spacing: 6) {
                Text(notice).lineLimit(2)
                Button { player.dismissSessionNotice() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss session notice")
            }.font(.caption).foregroundStyle(.orange).help(notice)
        } else if player.underrunFrames > 0 {
            Label("Buffer underruns: \(player.underrunFrames) frames", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text(player.isRestoredSession ? "Ready to resume" : (player.currentURL == nil ? "Local music, ready when you are" : (player.isPlaying ? "Playing" : "Paused")))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
