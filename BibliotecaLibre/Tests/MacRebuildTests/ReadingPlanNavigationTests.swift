import Testing
@testable import MacRebuild

struct ReadingPlanNavigationTests {
    @Test func startsRangesAtFirstAddressAndRejectsAnExplicitEdition() {
        #expect(ReadingPlanNavigation.start("John 3:16-18") == "jn 3:16")
        #expect(ReadingPlanNavigation.start("John 3") == "jn 3:1")
        #expect(ReadingPlanNavigation.start("John") == "jn 1:1")
        #expect(ReadingPlanNavigation.start("John 3:16(RVR60)") == nil)
        #expect(ReadingPlanNavigation.start("not a passage") == nil)
    }
}
