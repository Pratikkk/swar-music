@testable import SwarUI
import Testing

struct PlaybackRefreshRequestTests {
    @Test func occlusionChangeRestartsRefreshForPlayingTrack() {
        let visible = PlaybackRefreshRequest(isPlaying: true, isPaused: false)
        let occluded = PlaybackRefreshRequest(isPlaying: true, isPaused: true)

        #expect(visible != occluded)
        #expect(occluded != visible)
    }
}
