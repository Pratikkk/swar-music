import Foundation
import Testing
@testable import SwarUI

struct SeekSliderStateTests {
    let song = URL(fileURLWithPath: "/tmp/song.wav")
    private func ready() -> SeekSliderState {
        var state = SeekSliderState()
        state.synchronize(position: 10, duration: 100, url: song)
        return state
    }

    @Test func dragStartsAtTheLiveClockWithoutMirroringEveryTick() {
        var state = ready()
        #expect(state.value == 10)
        #expect(state.displayedPosition(55.25) == 55.25)
        state.begin(at: state.displayedPosition(55.25))
        #expect(state.value == 55.25 && state.displayedPosition(56) == 55.25)
        state.change(to: 72)
        #expect(state.displayedPosition(56) == 72)
    }

    @Test func elapsedAndRemainingAdvanceWithoutSynchronizingTheDraft() throws {
        var state = ready()
        for position in [11.0, 24.5, 55.0] {
            #expect(state.displayedPosition(position) == position)
            #expect(100 - state.displayedPosition(position) == 100 - position)
        }
        #expect(state.value == 10, "The clock must not depend on the stale drag draft")
        state.begin(at: 55)
        state.change(to: 80)
        let candidate = state.end()
        let request = try #require(candidate)
        let submitted = state.submit(request)
        #expect(submitted)
        #expect(state.displayedPosition(56) == 80, "Keep the seek preview until completion")
        state.finish(request, position: 80, seeking: false)
        #expect(state.displayedPosition(82) == 82)
        #expect(100 - state.displayedPosition(82) == 18)
    }

    @Test func liveDragAndReleaseKeepLatestPreviewUntilFinalSeekSettles() throws {
        var state = ready()
        state.begin(); state.change(to: 40)
        let firstCandidate = state.request()
        let first = try #require(firstCandidate)
        let firstSubmitted = state.submit(first)
        #expect(firstSubmitted)
        state.change(to: 70)
        state.finish(first, position: 40, seeking: false)
        state.synchronize(position: 40, duration: 100, url: song)
        #expect(state.displayedPosition(40) == 70)
        let finalCandidate = state.end()
        let final = try #require(finalCandidate)
        state.settle(position: 40, seeking: false)
        #expect(state.displayedPosition(40) == 70, "Release must not flash the previous seek position")
        let submitted = state.submit(final)
        #expect(submitted)
        state.finish(final, position: 40, seeking: true)
        #expect(state.displayedPosition(40) == 70)
        state.settle(position: 70, seeking: false)
        #expect(state.displayedPosition(71) == 71, "The playback clock takes over after confirmation")
    }

    @Test func olderSeekCannotOverwriteANewDragAndBindingBeforeBeginIsSafe() throws {
        var state = ready()
        state.change(to: 30)
        let candidate = state.request()
        let old = try #require(candidate)
        state.begin()
        let oldSubmitted = state.submit(old)
        #expect(!oldSubmitted && state.value == 30)
        state.change(to: 60)
        state.finish(old, position: 30, seeking: false)
        #expect(state.displayedPosition(30) == 60)
        let nextCandidate = state.end()
        let next = try #require(nextCandidate)
        let nextSubmitted = state.submit(next)
        #expect(nextSubmitted)
        state.begin(); state.change(to: 90)
        state.finish(next, position: 60, seeking: false)
        #expect(state.dragging && state.displayedPosition(60) == 90)
    }

    @Test func trackChangesUnavailableDurationAndRejectedSeeksDiscardDrafts() throws {
        var state = ready()
        state.begin(); state.change(to: 80)
        let candidate = state.end()
        let old = try #require(candidate)
        let other = URL(fileURLWithPath: "/tmp/other.wav")
        state.synchronize(position: 0, duration: 200, url: other)
        let submitted = state.submit(old)
        #expect(!submitted && state.displayedPosition(0) == 0 && !state.dragging)
        state.change(to: 400)
        #expect(state.value == 200)
        state.synchronize(position: 0, duration: .nan, url: other)
        let invalid = state.request()
        #expect(invalid == nil)
        state.synchronize(position: 20, duration: 100, url: song)
        state.change(to: 90)
        let rejectedCandidate = state.request()
        let rejected = try #require(rejectedCandidate)
        let accepted = state.submit(rejected)
        #expect(accepted)
        state.finish(rejected, position: 20, seeking: false)
        #expect(state.displayedPosition(20) == 20)
    }
}
