import Foundation
import Testing
@testable import ClickBridge

struct ClickBridgeTests {
    @Test func testButtonFramesPreservePressHoldAndRelease() {
        var buttons = ClickButtons()

        func packets(pressed: UInt32 = 0) -> [Data] {
            let bitmap = 0x10f0 & ~pressed
            let low = UInt8(bitmap & 0x7f) | 0x80
            let high = UInt8(bitmap >> 7)
            return buttons.update(Data([0x23, 0x08, low, high])).map {
                OpenBikeControlServer.packet($0.button, down: $0.down)
            }
        }

        // The released bitmap includes all four mapped bits plus the ignored Y bit.
        #expect(packets() == [])
        #expect(packets(pressed: 0x20) == [Data([0x01, 0x01, 0x01])])
        #expect(packets(pressed: 0x20) == [])
        #expect(packets(pressed: 0x1000) == [Data([0x01, 0x01, 0x00]), Data([0x01, 0x02, 0x01])])
        #expect(packets(pressed: 0x90) == [
            Data([0x01, 0x02, 0x00]), Data([0x01, 0x18, 0x01]), Data([0x01, 0x19, 0x01]),
        ])
        #expect(packets(pressed: 0xd0) == [])
        #expect(packets() == [Data([0x01, 0x18, 0x00]), Data([0x01, 0x19, 0x00])])
    }

    @Test func testUnknownFieldsAndMalformedPackets() {
        #expect(ClickButtons.bitmap(Data([0x23, 0x12, 0x02, 0xaa, 0xbb, 0x08, 0x01])) == 1)
        for malformed: [UInt8] in [
            [0xff, 0x03],
            [0x23, 0x08, 0x80],
            [0x23, 0x09, 0],
            [0x23, 0x12, 0x05, 0, 0x08, 0],
            [0x23, 0x08, 0x80, 0x80, 0x80, 0x80, 0x10],
        ] {
            #expect(ClickButtons.bitmap(Data(malformed)) == nil)
        }
    }
}
