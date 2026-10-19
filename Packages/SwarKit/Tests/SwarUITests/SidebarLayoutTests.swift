import Foundation
import Testing
@testable import SwarUI

struct SidebarLayoutTests {
    @Test func orderAndVisibilityRoundTripWithoutLosingHiddenItems() {
        var layout = SidebarLayout()
        layout.moveSections(from: IndexSet(integer: 4), to: 0)
        layout.setVisible(.genres, false)
        layout.setVisible(.home, false)
        layout.moveGroups(from: IndexSet(integer: 2), to: 0)
        layout.setVisible(.playlists, false)
        let restored = SidebarLayout(serialized: layout.serialized)
        #expect(restored == layout)
        #expect(restored.visibleSections.first == .songs)
        #expect(!restored.visibleSections.contains(.home) && !restored.visibleSections.contains(.genres))
        #expect(restored.sections.count == LibrarySection.allCases.count)
        #expect(restored.visibleGroups == [.folders, .library])
    }

    @Test func corruptedUnknownDuplicateAndMissingItemsRecoverSafely() {
        #expect(SidebarLayout(serialized: "broken") == SidebarLayout())
        let partial = #"{"sections":["Songs","Songs","Future Item"],"hidden":["Artists","Future Item"],"groups":["folders","folders","future"],"hiddenGroups":["library","playlists","future"]}"#
        let layout = SidebarLayout(serialized: partial)
        #expect(layout.sections.first == .songs && Set(layout.sections).count == LibrarySection.allCases.count)
        #expect(layout.sections.count == LibrarySection.allCases.count)
        #expect(layout.hidden == [.artists])
        #expect(layout.groups == [.folders, .library, .playlists])
        #expect(layout.visibleGroups == [.folders, .library])
    }

    @Test func keepsOneShortcutAndLibrarySectionAvailable() throws {
        var layout = SidebarLayout()
        for section in LibrarySection.allCases { layout.setVisible(section, false) }
        #expect(layout.visibleSections.count == 1)
        layout.setVisible(SidebarGroup.library, false)
        #expect(layout.visibleGroups.contains(.library))
        layout.setVisible(.home, true)
        #expect(layout.visibleSections.contains(.home))
        let hidden = LibrarySection.allCases.map { "\"" + $0.rawValue + "\"" }.joined(separator: ",")
        let malformed = "{\"sections\":[],\"hidden\":[" + hidden + "],\"groups\":[],\"hiddenGroups\":[\"library\"]}"
        let recovered = SidebarLayout(serialized: malformed)
        #expect(recovered.visibleSections == [.home] && recovered.visibleGroups.contains(.library))
    }

    @Test func multipleMovesAndInvalidOffsetsKeepStableOrder() {
        var layout = SidebarLayout()
        layout.moveSections(from: IndexSet([1, 2]), to: 5)
        #expect(Array(layout.sections.prefix(5)) == [.home, .albums, .songs, .recentlyAdded, .artists])
        let before = layout
        layout.moveSections(from: IndexSet(integer: 100), to: 0)
        layout.moveGroups(from: IndexSet(integer: 0), to: -1)
        #expect(layout == before)
        #expect(SidebarLayout(serialized: "") == SidebarLayout())
    }
}
