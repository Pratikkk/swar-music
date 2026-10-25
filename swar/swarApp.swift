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
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
