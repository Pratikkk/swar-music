import SwiftUI
import Player

@MainActor
struct SleepTimerMenu: View {
    @Environment(\.swarPalette) private var palette
    let timer: SleepTimer

    var body: some View {
        Menu {
            if let deadline = timer.deadline {
                Text("Pauses at " + deadline.formatted(date: .omitted, time: .shortened))
                Button("Cancel Sleep Timer", role: .destructive) { timer.cancel() }
                Divider()
            }
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                Button("\(minutes) minutes") { timer.start(minutes: minutes) }
            }
        } label: {
            Image(systemName: "timer")
                .foregroundStyle(timer.deadline == nil ? Color.secondary : palette.accent)
                .frame(width: 24, height: 32)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(timer.deadline == nil ? Color.secondary : palette.accent)
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(timer.deadline.map { "Pauses at " + $0.formatted(date: .omitted, time: .shortened) } ?? "Off")
        .help(timer.deadline.map { "Sleep Timer · Pauses at " + $0.formatted(date: .omitted, time: .shortened) } ?? "Sleep Timer · Off")
    }
}
