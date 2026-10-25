import SwiftUI
import Player
import Library

@MainActor
struct NowPlayingView: View {
    @Environment(\.swarPalette) private var palette
    let player: Player
    let library: LibraryModel
    let width: CGFloat
    let browseArtist: (String) -> Void
    let browseAlbum: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showAppearance = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close Now Playing")
                .help("Return to Library (Escape)")
                Text("Now Playing").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { showAppearance.toggle() } label: {
                    Image(systemName: "paintpalette").frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Now Playing appearance")
                .help("Now Playing appearance")
                .popover(isPresented: $showAppearance) {
                    NowPlayingAppearanceControls().padding(20).frame(width: 320)
                        .onExitCommand { showAppearance = false }
                }
                Color.clear.frame(width: 0, height: 28)
                    .currentSongActions(library: library, player: player, showsButton: true)
                SleepTimerMenu(timer: player.sleepTimer)
                Button { showLyrics.toggle(); if showLyrics { showQueue = false } } label: {
                    Label("Lyrics", systemImage: "quote.bubble")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 28)
                        .foregroundStyle(showLyrics ? palette.accent : .primary)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showLyrics ? "Hide Lyrics" : "Show Lyrics")
                .accessibilityAddTraits(showLyrics ? .isSelected : [])
                .help("Lyrics from the song's lyrics tag or an .lrc file in its folder")
                Button { showQueue.toggle(); if showQueue { showLyrics = false } } label: {
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
                        if showLyrics && !sideBySide {
                            LyricsView(player: player, library: library)
                                .frame(maxHeight: .infinity)
                        } else if showQueue && !sideBySide {
                            QueueView(player: player, library: library, embedded: true)
                                .frame(maxHeight: .infinity)
                        } else {
                            NowPlayingArtwork(player: player, library: library, size: min(250, max(180, geometry.size.height * 0.40)),
                                browseArtist: { name in dismiss(); browseArtist(name) },
                                browseAlbum: { name in dismiss(); browseAlbum(name) })
                        }
                        ExpandedPlayerControls(player: player)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showLyrics && sideBySide {
                        LyricsView(player: player, library: library)
                            .frame(width: 320)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .padding(.trailing, 16).padding(.bottom, 16)
                    } else if showQueue && sideBySide {
                        QueueView(player: player, library: library, embedded: true)
                            .frame(width: 300)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .padding(.trailing, 16).padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(width: width, height: 650)
        .background { NowPlayingBackdrop(artworkURL: player.artworkURL) }
        .interactiveDismissDisabled(showAppearance)
        .clipped().tint(palette.accent)
        .accentColor(palette.accent)
        .onExitCommand {
            if showAppearance { showAppearance = false } else { dismiss() }
        }
    }
}

@MainActor
private struct NowPlayingArtwork: View {
    let player: Player
    let library: LibraryModel
    let size: CGFloat
    let browseArtist: (String) -> Void
    let browseAlbum: (String) -> Void
    @State private var showActivity = false
    @AppStorage("nowPlayingTechnicalDetails") private var technicalDetails = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        player.currentURL == nil ? (player.queue.isEmpty ? "Nothing Playing" : "Queue Ready") : player.title
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                CoverArt(url: player.artworkURL, title: player.title, cornerRadius: 14, crossfade: true)
                    .frame(width: size, height: size)
                    .currentSongActions(library: library, player: player)
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
                    if technicalDetails {
                        ZStack {
                            if let info = player.formatInfo { FormatChip(info: info) }
                        }.frame(height: 28)
                    }
                    ZStack { status }.frame(height: 26)
                }
                .frame(maxWidth: 440)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: player.currentURL)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 8)
        }
        .scrollIndicators(.never)
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
        } else if player.isCrossfadeProcessing {
            Label("Smart Crossfade · Processed audio", systemImage: "waveform.path")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
