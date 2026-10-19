import Testing
@testable import SwarUI

@MainActor
struct WaveformSeekTests {
    @Test func pointerMappingClampsToSongBoundaries() {
        #expect(WaveformSeekSurface.fraction(-20, width: 200) == 0)
        #expect(WaveformSeekSurface.fraction(50, width: 200) == 0.25)
        #expect(WaveformSeekSurface.fraction(250, width: 200) == 1)
        #expect(WaveformSeekSurface.fraction(5, width: 0) == 0)
        #expect(WaveformSeekSurface.fraction(.nan, width: 100) == 0)
    }
}
