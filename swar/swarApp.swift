//
//  swarApp.swift
//  swar
//
//  Created by pratik on 15/10/26.
//

import SwiftUI
import SwarUI

@main
struct swarApp: App {
    var body: some Scene {
        WindowGroup("Swar") {
            LibraryView()
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 740)
    }
}
