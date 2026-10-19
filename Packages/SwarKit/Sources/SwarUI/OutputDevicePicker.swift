import SwiftUI
import Player

@MainActor
struct OutputDevicePicker: View {
    let player: Player
    var expanded = false
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "hifispeaker")
                if expanded { Text(player.selectedOutputName).lineLimit(1).frame(maxWidth: 120) }
            }
            .font(.system(size: expanded ? 10 : 13))
            .foregroundStyle(player.outputNotice == nil ? Color.secondary : Color.orange)
            .frame(minWidth: 24, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio Output")
        .accessibilityValue(player.selectedOutputName)
        .help("Audio output: " + player.selectedOutputName)
        .popover(isPresented: $presented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio Output").font(.headline)
                outputRow("System Default", uid: nil, subtitle: player.audioOutputs.devices.first { $0.id == player.audioOutputs.defaultID }?.name)
                Divider()
                if !player.audioOutputs.devices.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(player.audioOutputs.devices) { device in outputRow(device.name, uid: device.uid) }
                        }
                    }.frame(height: min(260, CGFloat(player.audioOutputs.devices.count) * 34))
                }
                if player.audioOutputs.devices.isEmpty { Text("No outputs available").foregroundStyle(.secondary) }
                if player.preferredOutputUnavailable {
                    Text("Saved output unavailable. Using the system default until it reconnects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let notice = player.outputNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                if player.currentURL != nil {
                    Divider()
                    Button("Reconnect Output") { Task { await player.retryOutputRecovery() } }
                        .disabled(!player.canRetryOutput)
                }
            }
            .padding(16).frame(width: 280)
            .task { await player.refreshOutputs(force: true) }
        }
    }
    private func outputRow(_ name: String, uid: String?, subtitle: String? = nil) -> some View {
        Button {
            Task { await player.selectOutput(uid: uid) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "checkmark").opacity(player.preferredOutputUID == uid ? 1 : 0)
            }.contentShape(Rectangle()).padding(.vertical, 4)
        }.buttonStyle(.plain).disabled(player.isBusy)
        .accessibilityLabel(name).accessibilityValue(player.preferredOutputUID == uid ? "Selected" : "")
    }
}
