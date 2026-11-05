import Foundation

enum ClickButton: UInt32, CaseIterable {
    case b = 0x0020
    case plus = 0x1000
    case z = 0x0080
    case a = 0x0010
}

struct ClickButtons {
    private static let released = ClickButton.allCases.reduce(0) { $0 | $1.rawValue }
    private var previous = Self.released

    mutating func update(_ frame: Data) -> [(button: ClickButton, down: Bool)] {
        guard let current = Self.bitmap(frame) else { return [] }
        let changed = previous ^ current
        previous = current
        return ClickButton.allCases.compactMap { button in
            guard changed & button.rawValue != 0 else { return nil }
            return (button, current & button.rawValue == 0)
        }
    }

    // The 0x23 notification carries an active-low bitmap in protobuf field 1.
    static func bitmap(_ frame: Data) -> UInt32? {
        var bytes = frame.makeIterator()
        guard bytes.next() == 0x23 else { return nil }
        var remaining = frame.count - 1

        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard let byte = bytes.next(), shift != 63 || byte <= 1 else { return nil }
                remaining -= 1
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
            }
            return nil
        }

        while remaining > 0 {
            guard let tag = varint(), tag >> 3 != 0 else { return nil }
            let length: UInt64
            switch tag & 7 {
            case 0:
                guard let fieldValue = varint() else { return nil }
                if tag >> 3 == 1 { return UInt32(exactly: fieldValue) }
                continue
            case 1:
                length = 8
            case 2:
                guard let size = varint() else { return nil }
                length = size
            case 5:
                length = 4
            default:
                return nil
            }
            guard length <= remaining else { return nil }
            for _ in 0..<length { _ = bytes.next() }
            remaining -= Int(length)
        }
        return nil
    }
}
