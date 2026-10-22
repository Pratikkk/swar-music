import Testing
import Library
@testable import SwarUI

struct RecentLibrarySearchTests {
    @Test func remembersTrimmedQueryAndScope() {
        let result = RecentLibrarySearch.recording("  Arijit  \n", scope: .artist, in: [])
        #expect(result == [.init(query: "Arijit", scope: "Artist")])
    }
    @Test func duplicateMovesToFrontButDifferentScopesRemain() {
        let history: [RecentLibrarySearch] = [.init(query: "Other", scope: "Artist"), .init(query: "arijit", scope: "Artist"), .init(query: "Arijit", scope: "All Fields")]
        let result = RecentLibrarySearch.recording("Arijit", scope: .artist, in: history)
        #expect(result.count == 3)
        #expect(result.first?.query == "Arijit")
        #expect(result.last?.scope == "All Fields")
    }
    @Test func historyIsBoundedAndEmptyQueriesAreIgnored() {
        let history = (0..<8).map { RecentLibrarySearch(query: "Song \($0)", scope: "All Fields") }
        #expect(RecentLibrarySearch.recording(" \n", scope: .all, in: history) == history)
        let result = RecentLibrarySearch.recording("New", scope: .all, in: history)
        #expect(result.count == 8)
        #expect(result.first?.query == "New")
        #expect(result.last?.query == "Song 6")
    }
}
