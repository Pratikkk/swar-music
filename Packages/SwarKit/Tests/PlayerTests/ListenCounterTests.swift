import Foundation
import Testing
@testable import Player

struct ListenCounterTests {
    @Test func countsOnceAfterThirtySecondsAndPausesDoNotAccumulate() {
        var counter = ListenCounter()
        #expect(!Bool(counter.sample(time: 0, position: 0, duration: 200, playing: true)))
        for i in 1..<30 { #expect(!Bool(counter.sample(time: Double(i), position: Double(i), duration: 200, playing: true))) }
        #expect(!Bool(counter.sample(time: 29, position: 29, duration: 200, playing: false)))
        #expect(!Bool(counter.sample(time: 300, position: 29, duration: 200, playing: false)))
        #expect(!Bool(counter.sample(time: 301, position: 29, duration: 200, playing: true)))
        #expect(Bool(counter.sample(time: 302, position: 30, duration: 200, playing: true)))
        #expect(!Bool(counter.sample(time: 303, position: 31, duration: 200, playing: true)))
    }

    @Test func seekingDoesNotCountDistanceAndRetainsEarlierListening() {
        var counter = ListenCounter()
        _ = counter.sample(time: 0, position: 0, duration: 20, playing: true)
        for i in 1...5 { #expect(!Bool(counter.sample(time: Double(i), position: Double(i), duration: 20, playing: true))) }
        counter.interrupt()
        #expect(!Bool(counter.sample(time: 6, position: 15, duration: 20, playing: true)))
        for i in 1..<5 { #expect(!Bool(counter.sample(time: Double(6+i), position: Double(15+i), duration: 20, playing: true))) }
        #expect(Bool(counter.sample(time: 11, position: 20, duration: 20, playing: false)))
    }

    @Test func unobservedGapsInvalidSamplesAndBackwardProgressDoNotInflatePlays() {
        var counter = ListenCounter()
        _ = counter.sample(time: 0, position: 0, duration: 200, playing: true)
        #expect(!Bool(counter.sample(time: 100, position: 100, duration: 200, playing: true)))
        #expect(!Bool(counter.sample(time: 101, position: 0, duration: 200, playing: true)))
        #expect(!Bool(counter.sample(time: .nan, position: 0, duration: 200, playing: true)))
        #expect(!Bool(counter.sample(time: 102, position: 150, duration: 200, playing: true)))
        #expect(!Bool(counter.sample(time: 103, position: 150, duration: 200, playing: true)))
    }
}
