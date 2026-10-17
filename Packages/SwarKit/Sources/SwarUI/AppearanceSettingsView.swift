import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var mode: SwarAppearanceMode = .system
    @AppStorage("accentPalette") private var accent: SwarAccent = .violet
    @AppStorage("interfaceDensity") private var density: SwarDensity = .comfortable

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $mode) {
                    ForEach(SwarAppearanceMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("Accent colour") {
                HStack(spacing: 22) {
                    ForEach(SwarAccent.allCases) { colour in
                        Button { accent = colour } label: {
                            VStack(spacing: 7) {
                                Circle().fill(colour.buttonFill)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if accent == colour {
                                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .padding(4)
                                    .overlay(Circle().strokeBorder(accent == colour ? colour.accent : .clear, lineWidth: 2))
                                Text(colour.title).font(.caption).foregroundStyle(.primary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(colour.title + " accent")
                            .accessibilityAddTraits(accent == colour ? .isSelected : [])
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            Section("Spacing") {
                Picker("Density", selection: $density) {
                    ForEach(SwarDensity.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("Adjusts library rows, artwork spacing and the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
