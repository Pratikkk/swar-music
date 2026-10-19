import Testing
@testable import SwarUI

struct WelcomeGuideTests {
    @Test func freshInstallWaitsForLibraryThenPresents() {
        #expect(WelcomeGuidePolicy.action(completed: false, ready: false, folderCount: 0, trackCount: 0) == .wait)
        #expect(WelcomeGuidePolicy.action(completed: false, ready: true, folderCount: 0, trackCount: 0) == .present)
    }

    @Test func existingCollectionsAreAcknowledgedWithoutInterruptingAnUpgrade() {
        #expect(WelcomeGuidePolicy.action(completed: false, ready: true, folderCount: 1, trackCount: 0) == .acknowledgeExisting)
        #expect(WelcomeGuidePolicy.action(completed: false, ready: true, folderCount: 0, trackCount: 12) == .acknowledgeExisting)
        #expect(WelcomeGuidePolicy.action(completed: false, ready: false, folderCount: 1, trackCount: 12) == .wait)
    }

    @Test func finishingOrSkippingDoesNotReappearEvenWhenTheLibraryIsEmptied() {
        #expect(WelcomeGuidePolicy.action(completed: true, ready: true, folderCount: 0, trackCount: 0) == .none)
        #expect(WelcomeGuidePolicy.action(completed: true, ready: false, folderCount: 0, trackCount: 0) == .none)
    }
}
