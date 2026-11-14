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

struct KeepAwakeTests {
    @Test func guardsRequireExactFirmwareAndExplicitRightPodOptIn() {
        #expect(ClickKeepAwake.eligible(optIn: true, rightPod: true, firmware: Data("1.2.0".utf8)))
        #expect(!ClickKeepAwake.eligible(optIn: false, rightPod: true, firmware: Data("1.2.0".utf8)))
        #expect(!ClickKeepAwake.eligible(optIn: true, rightPod: false, firmware: Data("1.2.0".utf8)))
        for version in ["", "1.2.1", "1.2.0\0", "1.2.0 "] {
            #expect(!ClickKeepAwake.eligible(optIn: true, rightPod: true, firmware: Data(version.utf8)))
        }
    }

    @Test func capturedSequenceAndRepeat() {
        var sequence = ClickKeepAwake()
        for _ in 0..<2 {
            #expect(sequence.begin() == .init(channel: .control, bytes: Data([1])))
            #expect(sequence.begin() == nil) // No overlap.
            let payload = sequence.receive(Data([1, 0xf0, 0]), on: .control)
            #expect(payload == .init(channel: .data, bytes: Data([
                0x3d, 0xb8, 0xf3, 0x96, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0xb0, 3, 0, 0, 0,
            ])))
            #expect(sequence.receive(Data([0]), on: .data) == .init(channel: .control, bytes: Data([3])))
            #expect(sequence.receive(Data([0x12, 0, 0, 0, 0, 0]), on: .control) == nil)
            #expect(sequence.state == .idle)
        }
    }

    @Test func failuresLatchAtEveryStage() {
        for stage in 0..<4 {
            var sequence = ClickKeepAwake()
            if stage > 0 { _ = sequence.begin() }
            if stage > 1 { _ = sequence.receive(Data([1, 0xf0, 0]), on: .control) }
            if stage > 2 { _ = sequence.receive(Data([0]), on: .data) }
            var disconnected = sequence
            disconnected.disable() // Same terminal path used by timeout, backpressure and disconnect.
            #expect(disconnected.begin() == nil)
            #expect(disconnected.receive(Data([1, 0xf0, 0]), on: .control) == nil)
            #expect(sequence.receive(Data([0xff, 4, 0]), on: .control) == nil)
            #expect(sequence.state == .disabled)
            #expect(sequence.begin() == nil)
        }
        var wrongChannel = ClickKeepAwake()
        _ = wrongChannel.begin()
        #expect(wrongChannel.receive(Data([1, 0xf0, 0]), on: .data) == nil)
        #expect(wrongChannel.state == .disabled)
        var duplicate = ClickKeepAwake()
        _ = duplicate.begin()
        _ = duplicate.receive(Data([1, 0xf0, 0]), on: .control)
        #expect(duplicate.receive(Data([1, 0xf0, 0]), on: .control) == nil)
        #expect(duplicate.state == .disabled)
    }
}
