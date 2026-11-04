import Testing
@testable import SMCKit

@Suite struct FourCCTests {
    @Test func roundTrip() {
        #expect(FourCC("F0Ac").description == "F0Ac")
        #expect(FourCC("flt").description == "flt ")
        #expect(FourCC("#KEY").rawValue == 0x234B_4559)
    }
}

@Suite struct SMCCodecTests {
    @Test func floatLittleEndian() throws {
        let bytes = try #require(SMCCodec.encode(1234.5, type: "flt ", size: 4))
        #expect(bytes == [0x00, 0x50, 0x9A, 0x44])
        #expect(SMCCodec.decode(type: "flt ", bytes: bytes) == 1234.5)
    }

    @Test func fpe2() throws {
        // 2000 rpm in fpe2 = 2000 * 4 = 0x1F40
        #expect(SMCCodec.decode(type: "fpe2", bytes: [0x1F, 0x40]) == 2000)
        #expect(SMCCodec.encode(2000, type: "fpe2", size: 2) == [0x1F, 0x40])
    }

    @Test func sp78Signed() {
        #expect(SMCCodec.decode(type: "sp78", bytes: [0x2A, 0x80]) == 42.5)
        #expect(SMCCodec.decode(type: "sp78", bytes: [0xFF, 0x00]) == -1)
    }

    @Test func integers() {
        #expect(SMCCodec.decode(type: "ui8 ", bytes: [3]) == 3)
        #expect(SMCCodec.decode(type: "ui32", bytes: [0, 0, 0x05, 0x39]) == 1337)
        #expect(SMCCodec.decode(type: "si16", bytes: [0xFF, 0xFE]) == -2)
        #expect(SMCCodec.encode(1, type: "ui8 ", size: 1) == [1])
        #expect(SMCCodec.encode(256, type: "ui8 ", size: 1) == nil)
        #expect(SMCCodec.encode(-1, type: "ui8 ", size: 1) == nil)
        #expect(SMCCodec.encode(-2, type: "si16", size: 2) == [0xFF, 0xFE])
    }

    @Test func unknownTypeIsNil() {
        #expect(SMCCodec.decode(type: "ch8*", bytes: [0x41]) == nil)
        #expect(SMCCodec.encode(1, type: "{fds", size: 16) == nil)
    }
}

@Suite struct ChipTests {
    @Test func parse() {
        #expect(ChipFamily.parse(brand: "Apple M4") == .apple(generation: 4, variant: nil))
        #expect(ChipFamily.parse(brand: "Apple M3 Max") == .apple(generation: 3, variant: "Max"))
        #expect(ChipFamily.parse(brand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz") == .intel)
    }
}
