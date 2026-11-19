//
//  swarApp.swift
//  swar
//
//  Created by pratik on 15/10/26.
//

import SwiftUI
import AppKit
import SwarUI
import Library
import Player

@main
struct swarApp: App {
    @NSApplicationDelegateAdaptor(SwarAppDelegate.self) private var appDelegate
    @State private var library = LibraryModel()
    @State private var player = Player(sessionStore: .applicationDefault())
    init() {
        if CommandLine.arguments.contains("--verify-bundled-codecs") {
            BundledCodecVerification.runAndExit()
        }
    }

    var body: some Scene {
        Window("Swar", id: "library") {
            #if DEBUG
            if CommandLine.arguments.contains("--format-chip-preview") {
                FormatChipPreview().swarAppearancePreferences()
            } else {
                LibraryView(library: library, player: player)
                    .welcomeGuide(library: library)
                    .frame(minWidth: 760, minHeight: 500)
                    .swarAppearancePreferences()
            }
            #else
            LibraryView(library: library, player: player)
                .welcomeGuide(library: library)
                .frame(minWidth: 760, minHeight: 500)
                .swarAppearancePreferences()
            #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1224, height: 740)
        .commands { SwarCommands() }

        Settings {
            LibrarySettingsView(library: library, player: player).swarAppearancePreferences()
        }
    }
}

/// Refresh the running Dock tile as well as the bundle's Finder/About icon.
/// Development builds can otherwise keep a cached generic icon across rebuilds.
final class SwarAppDelegate: NSObject, NSApplicationDelegate {
    private var occlusionObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon

        // Initialize occlusion observer
        _ = OcclusionObserver.shared

        // Notify Player and AudioEngine of occlusion changes
        occlusionObserver = NotificationCenter.default
            .publisher(for: NSApplication.didChangeOcclusionStateNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification))
            .sink { [weak self] _ in
                self?.notifyOcclusionChange()
            }
    }

    private func notifyOcclusionChange() {
        let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
        let occluded = windows.isEmpty || windows.allSatisfy { $0.occlusionState.contains(.visible) == false }
        let backgrounded = !NSApp.isActive

        // Post custom notification for Player/AudioEngine
        NotificationCenter.default.post(
            name: .swarOcclusionStateChanged,
            object: nil,
            userInfo: ["occluded": occluded || backgrounded, "backgrounded": backgrounded]
        )
    }
}

extension Notification.Name {
    static let swarOcclusionStateChanged = Notification.Name("swarOcclusionStateChanged")
}
