import Testing
@testable import LibronixCore

struct BiblicalMeasuresTests {
    @Test func statedAssumptionsAndExactModernConversions() throws {
        #expect(abs(try #require(BiblicalMeasureUnit.convert(1, from: .cubit, to: .centimeter)) - 44.45) < 1e-10)
        #expect(try #require(BiblicalMeasureUnit.convert(2, from: .ephah, to: .liter)) == 44)
        #expect(try #require(BiblicalMeasureUnit.convert(1, from: .homer, to: .bath)) == 10)
        #expect(try #require(BiblicalMeasureUnit.convert(5, from: .shekel, to: .gram)) == 57)
        #expect(abs(try #require(BiblicalMeasureUnit.convert(12, from: .inch, to: .foot)) - 1) < 1e-10)
    }
    @Test func incompatibleAndNonfiniteValuesAreRejected() {
        #expect(BiblicalMeasureUnit.convert(1, from: .cubit, to: .gram) == nil)
        #expect(BiblicalMeasureUnit.convert(.infinity, from: .meter, to: .foot) == nil)
        #expect(BiblicalMeasureUnit.convert(.greatestFiniteMagnitude, from: .kilogram, to: .gram) == nil)
    }
}
