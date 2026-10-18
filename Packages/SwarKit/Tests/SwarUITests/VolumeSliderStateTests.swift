import Testing
@testable import SwarUI

struct VolumeSliderStateTests {
    private func ready() -> VolumeSliderState {
        var state = VolumeSliderState()
        state.synchronize(level: 0.4, deviceID: 42, available: true)
        return state
    }

    @Test func dragReleaseHoldsChosenLevelThroughDelayedAndQuantizedConfirmation() throws {
        var state = ready()
        state.begin(); state.change(to: 0.82)
        let requestCandidate = state.end()
        let request = try #require(requestCandidate)
        #expect(!state.dragging && state.value == 0.82)
        state.synchronize(level: 0.4, deviceID: 42, available: true)
        #expect(state.value == 0.82)
        let submitted = state.submit(request)
        #expect(submitted)
        state.finish(request, level: 0.4, deviceID: 42, available: true, writing: true)
        state.synchronize(level: 0.5, deviceID: 42, available: true)
        #expect(state.value == 0.82)
        state.settle(level: 0.8125, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.8125)
    }

    @Test func bindingUpdateBeforeEditingBeginsIsNotResetOrSubmittedTwice() throws {
        var state = ready()
        state.change(to: 0.75)
        let prematureCandidate = state.request()
        let premature = try #require(prematureCandidate)
        state.begin()
        let prematureSubmitted = state.submit(premature)
        #expect(state.value == 0.75 && !prematureSubmitted)
        let finalCandidate = state.end()
        let final = try #require(finalCandidate)
        let finalSubmitted = state.submit(final)
        #expect(final.level == 0.75 && finalSubmitted)
        state.finish(final, level: 0.75, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.75)
    }

    @Test func coalescedKeyboardWritesKeepLatestPreviewUntilHardwareQueueDrains() throws {
        var state = ready()
        state.change(to: 0.6)
        let firstCandidate = state.request()
        let first = try #require(firstCandidate)
        let firstSubmitted = state.submit(first)
        #expect(firstSubmitted)
        state.change(to: 0.9)
        let lastCandidate = state.request()
        let last = try #require(lastCandidate)
        // Completion of the older request cannot restore its obsolete value.
        state.finish(first, level: 0.6, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.9)
        state.settle(level: 0.6, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.9, "A queued request must keep its preview before submission")
        let lastSubmitted = state.submit(last)
        #expect(lastSubmitted)
        state.finish(last, level: 0.6, deviceID: 42, available: true, writing: true)
        #expect(state.value == 0.9)
        state.settle(level: 0.9, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.9)
    }

    @Test func aNewDragIsNotOverwrittenByAnOlderCommit() throws {
        var state = ready()
        state.change(to: 0.7)
        let oldCandidate = state.request()
        let old = try #require(oldCandidate)
        let oldSubmitted = state.submit(old)
        #expect(oldSubmitted)
        state.begin(); state.change(to: 0.55)
        state.finish(old, level: 0.7, deviceID: 42, available: true, writing: false)
        state.synchronize(level: 0.7, deviceID: 42, available: true)
        #expect(state.dragging && state.value == 0.55)
        let finalCandidate = state.end()
        let final = try #require(finalCandidate)
        let finalSubmitted = state.submit(final)
        #expect(finalSubmitted)
        state.finish(final, level: 0.55, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.55)
    }

    @Test func deviceChangesAndUnavailableControlsDiscardDrafts() throws {
        var state = ready()
        state.begin(); state.change(to: 0.8)
        let oldCandidate = state.end()
        let old = try #require(oldCandidate)
        state.synchronize(level: 0.2, deviceID: 99, available: true)
        let oldSubmitted = state.submit(old)
        #expect(!state.dragging && state.value == 0.2 && !oldSubmitted)
        state.finish(old, level: 0.8, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.2)
        state.begin(); state.change(to: 0.9)
        state.synchronize(level: 0.2, deviceID: 99, available: false)
        let ended = state.end()
        let unavailableRequest = state.request()
        #expect(state.value == 0.2 && ended == nil && unavailableRequest == nil)
    }

    @Test func idleHardwareChangesAndRejectedWritesUseActualLevel() throws {
        var state = ready()
        state.synchronize(level: 0.3, deviceID: 42, available: true)
        #expect(state.value == 0.3)
        state.change(to: 0.8)
        let rejectedCandidate = state.request()
        let rejected = try #require(rejectedCandidate)
        let submitted = state.submit(rejected)
        #expect(submitted)
        state.finish(rejected, level: 0.3, deviceID: 42, available: true, writing: false)
        #expect(state.value == 0.3)
        state.change(to: 0.9)
        let cancelledCandidate = state.request()
        let cancelled = try #require(cancelledCandidate)
        state.cancel(level: 0.3, deviceID: 42, available: true)
        let cancelledSubmitted = state.submit(cancelled)
        #expect(state.value == 0.3 && !cancelledSubmitted)
    }
}
