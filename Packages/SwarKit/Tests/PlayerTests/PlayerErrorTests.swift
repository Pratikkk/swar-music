import Foundation
import Player
import Testing

@MainActor
struct PlayerErrorTests {
    @Test func openErrorSurvivesRoutinePolling() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("corrupt audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = Player()
        await player.open(file)
        let message = try #require(player.errorMessage)
        await player.refresh()
        #expect(player.errorMessage == message)
        #expect(!player.isPlaying)
        #expect(player.duration == 0)
        #expect(!player.isBusy)
    }

    @Test func filePickerErrorSurvivesRoutinePolling() async {
        let player = Player()
        player.reportImportError(CocoaError(.fileReadNoPermission))
        let message = player.errorMessage
        await player.refresh()
        #expect(message != nil)
        #expect(player.errorMessage == message)
    }
}
