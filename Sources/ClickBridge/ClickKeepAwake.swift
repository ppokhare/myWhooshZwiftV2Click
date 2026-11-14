import Foundation

/// Only the sequence observed on the right Click V2, firmware 1.2.0.
/// This uses the firmware-update interface; flash effects are not established.
struct ClickKeepAwake {
    enum Channel: String {
        case data = "00000100-19ca-4651-86e5-fa29dcdd09d1"
        case control = "00000102-19ca-4651-86e5-fa29dcdd09d1"
    }
    struct Write: Equatable {
        let channel: Channel
        let bytes: Data
    }
    enum State: Equatable { case idle, opening, payload, closing, disabled }
    private(set) var state: State = .idle

    static func eligible(optIn: Bool, rightPod: Bool, firmware: Data) -> Bool {
        optIn && rightPod && firmware == Data("1.2.0".utf8)
    }

    mutating func begin() -> Write? {
        guard state == .idle else { return nil }
        state = .opening
        return Write(channel: .control, bytes: Data([0x01]))
    }

    mutating func receive(_ bytes: Data, on channel: Channel) -> Write? {
        switch (state, channel, bytes) {
        case (.opening, .control, Data([0x01, 0xf0, 0x00])):
            state = .payload
            return Write(channel: .data, bytes: Data([
                0x3d, 0xb8, 0xf3, 0x96, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0xb0, 3, 0, 0, 0,
            ]))
        case (.payload, .data, Data([0x00])):
            state = .closing
            return Write(channel: .control, bytes: Data([0x03]))
        case (.closing, .control, Data([0x12, 0, 0, 0, 0, 0])):
            state = .idle
        default:
            disable()
        }
        return nil
    }

    // Timeout, disconnect, backpressure or unexpected reply: never retry a partial sequence.
    mutating func disable() { state = .disabled }
}
