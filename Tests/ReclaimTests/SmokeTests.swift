import Testing
@testable import DiskMap

@Test func byteFormatting() {
    #expect(ByteFormat.string(0) == "0 B")
    #expect(ByteFormat.string(1023) == "1023 B")
    #expect(ByteFormat.string(1024) == "1.0 KB")
}
