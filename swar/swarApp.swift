//
//  swarApp.swift
//  swar
//
//  Created by pratik on 15/10/26.
//

import SwiftUI
import SwarUI
import Library

@main
struct swarApp: App {
    @State private var library = LibraryModel()
    var body: some Scene {
        Window("Swar", id: "library") {
            #if DEBUG
            if CommandLine.arguments.contains("--format-chip-preview") {
                FormatChipPreview()
            } else {
                LibraryView(library: library)
                    .frame(minWidth: 760, minHeight: 500)
            }
            #else
            LibraryView(library: library)
                .frame(minWidth: 760, minHeight: 500)
            #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1224, height: 740)
        .commands { SwarCommands() }

        Settings {
            LibrarySettingsView(library: library)
        }
    }
}
