import unittest
from click_mywhoosh_bridge import ClickMapper, bitmap


def varint(x):
    out = bytearray()
    while True:
        b = x & 0x7f
        x >>= 7
        out.append(b | (0x80 if x else 0))
        if not x:
            return bytes(out)


def frame(pressed=0):
    # All known bits are normally high (released), low means pressed.
    from click_mywhoosh_bridge import KNOWN_MASK
    return b'\x23\x08' + varint(KNOWN_MASK & ~pressed)


class TestClickMapper(unittest.TestCase):
    def test_shift_up_and_release(self):
        m = ClickMapper()
        self.assertEqual(m.feed(frame(0x20)), [("B", True, b'\x01\x01\x01')])
        self.assertEqual(m.feed(frame(0x20)), [])  # no duplicate on mirrored frame
        self.assertEqual(m.feed(frame()), [("B", False, b'\x01\x01\x00')])

    def test_shift_down(self):
        m = ClickMapper()
        self.assertEqual(m.feed(frame(0x1000))[0][2], b'\x01\x02\x01')

    def test_steering_holds_then_releases(self):
        m = ClickMapper()
        self.assertEqual(m.feed(frame(0x80))[0][2], b'\x01\x18\x01')
        self.assertEqual(m.feed(frame(0x80)), [])
        self.assertEqual(m.feed(frame(0x80 | 0x10))[0][2], b'\x01\x19\x01')
        releases = [e[2] for e in m.feed(frame())]
        self.assertEqual(releases, [b'\x01\x18\x00', b'\x01\x19\x00'])

    def test_camera_direct_or_cycle(self):
        self.assertEqual(ClickMapper().feed(frame(0x40)), [])
        self.assertEqual(ClickMapper('select5').feed(frame(0x40))[0][2], b'\x01\x40\x05')
        self.assertEqual(ClickMapper('cycle').feed(frame(0x40))[0][2], b'\x01\x40\x01')

    def test_disconnection_clears_all_buttons(self):
        m = ClickMapper()
        m.feed(frame(0x80 | 0x20))
        self.assertEqual([e[2] for e in m.release_all()],
                         [b'\x01\x01\x00', b'\x01\x18\x00'])
        self.assertEqual(m.release_all(), [])
        self.assertEqual(m.feed(frame(0x80))[0][2], b'\x01\x18\x01')

    def test_malformed_and_non_button_frames(self):
        self.assertIsNone(bitmap(b'\xff\x03'))
        self.assertIsNone(bitmap(b'\x23\x08\x80'))
        self.assertIsNone(bitmap(b'\x23\x12\xff'))
        self.assertIsNone(bitmap(b'\x23\x09\x00'))
        self.assertEqual(ClickMapper().feed(b'\xff\x03'), [])

    def test_extra_unknown_protobuf_field(self):
        self.assertEqual(bitmap(b'\x23\x10\x10\x08\x00'), 0)


if __name__ == '__main__':
    unittest.main()
