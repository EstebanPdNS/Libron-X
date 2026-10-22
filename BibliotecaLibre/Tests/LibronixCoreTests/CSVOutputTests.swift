import Testing
@testable import LibronixCore

struct CSVOutputTests {
    @Test func quotesNewlinesUnicodeAndFormulaPrefixesArePreservedSafely() {
        #expect(CSVOutput.row(["a,\"b\"", "😀 a\u{301}\r\ntext", "", "  =SUM(1,2)", "\t@x", "plain"])
            == "\"a,\"\"b\"\"\",\"😀 a\u{301}\r\ntext\",\"\",\"'  =SUM(1,2)\",\"'\t@x\",\"plain\"\r\n")
    }
}
