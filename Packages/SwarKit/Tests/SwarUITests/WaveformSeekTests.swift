import Testing
import SwiftUI
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
    @Test func geometryStaysInsideCompactAndExpandedBounds() {
        for size in [CGSize(width: 0.1, height: 1), CGSize(width: 180, height: 24), CGSize(width: 460, height: 44)] {
            for samples: [Float] in [[], [0], [1], [0, .nan, .infinity, -1, 0.5, 1]] {
                let path = WaveformSeekSurface.path(samples: samples, size: size, mini: size.height < 30)
                let box = path.boundingRect
                #expect(box.minX >= -0.001 && box.minY >= -0.001)
                #expect(box.maxX <= size.width + 0.001 && box.maxY <= size.height + 0.001)
            }
        }
        #expect(WaveformSeekSurface.path(samples: [1], size: .zero, mini: true).isEmpty)
    }

    @Test func pooledBarsKeepQuietSectionsQuietAndIncludeTheSongEnd() {
        let samples: [Float] = Array(repeating: 0.1, count: 256) + Array(repeating: 0.8, count: 255) + [1]
        let bars = WaveformSeekSurface.amplitudes(samples: samples, count: 64)
        #expect(bars.count == 64 && bars[0] < 0.11)
        #expect(bars[40] > 0.79 && bars.last! > bars[40])
        #expect(WaveformSeekSurface.amplitudes(samples: [0, .nan, .infinity, -1], count: 100) == [0, 0, 0, 0])
    }

    @Test func previewMarkersAndLongTimestampsAreSafeAtTheEdges() {
        #expect(WaveformSeekSurface.markerX(0, width: 180) == 0)
        #expect(WaveformSeekSurface.markerX(1, width: 180) == 179)
        #expect(WaveformSeekSurface.markerX(.infinity, width: 180) == 0)
        #expect(WaveformSeekSurface.timeString(3661) == "1:01:01")
        #expect(WaveformSeekSurface.timeString(.infinity) == "0:00")
        #expect(WaveformSeekSurface.timeString(Double.greatestFiniteMagnitude) == "0:00")
    }
}
