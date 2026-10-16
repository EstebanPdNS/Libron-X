import Testing
@testable import LibronixCore

@Suite struct ReadingHistoryTests {
    @Test func aNewVisitAfterBackDropsOnlyForwardHistory() {
        var history = ReadingHistory()
        for section in [2, 4, 6] { history.visit(section) }
        #expect(history.back() == 4)
        history.visit(8)
        #expect(history.sections == [2, 4, 8])
        #expect(history.next == nil)
        #expect(history.back() == 4)
        #expect(history.forward() == 8)
    }
    @Test func repeatedCurrentAndInvalidDestinationsDoNotChangeHistory() {
        var history = ReadingHistory()
        history.visit(0); history.visit(0); history.visit(-1)
        #expect(history.sections == [0])
        #expect(history.back() == nil)
        #expect(history.forward() == nil)
        #expect(history.current == 0)
    }
    @Test func oldestEntriesExpireWithoutChangingTheCurrentDestination() {
        var history = ReadingHistory(limit: 2)
        for section in [1, 2, 3] { history.visit(section) }
        #expect(history.sections == [2, 3])
        #expect(history.current == 3)
        #expect(history.back() == 2)
        #expect(history.back() == nil)
        var single = ReadingHistory(limit: 0)
        single.visit(8); single.visit(9)
        #expect(single.sections == [9])
        #expect(single.previous == nil)
    }
}
