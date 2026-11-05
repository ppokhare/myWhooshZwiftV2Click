#!/usr/bin/env python3
"""Zwift Click V2 RIGHT pod -> OpenBikeControl -> MyWhoosh (macOS/Python).

No Zwift login required. LEFT pod buttons are not supported.
Protocol based on thomaschampagne/zwiftboard (MIT), dev branch, Nov 2026.

The Camera View 5 value is an *experiment*: OpenBikeControl reserves camera
values 2..31 for app-defined views; MyWhoosh's exact mapping is undocumented.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import suppress
import time

ZWIFT_COMPANY = 0x094A
RIGHT_POD = 0x0A
ASYNC = "00000002-19ca-4651-86e5-fa29dcdd09d1"  # notifications
SYNC_RX = "00000003-19ca-4651-86e5-fa29dcdd09d1"  # writes
SYNC_TX = "00000004-19ca-4651-86e5-fa29dcdd09d1"  # handshake indications

# Click 0x23 frame: protobuf field #1 uint32; 0 bit = pressed.
# (Click button bit, name, OpenBikeControl action ID)
BUTTONS = (
    (0x0020, "B", 0x01),        # harder gear
    (0x1000, "PLUS", 0x02),     # easier gear
    (0x0080, "Z", 0x18),        # steer left
    (0x0010, "A", 0x19),        # steer right
)
CAMERA_BUTTON = (0x0040, "Y", 0x40)
KNOWN_MASK = sum(bit for bit, _, _ in BUTTONS) | CAMERA_BUTTON[0]


def _varint(data: bytes, i: int) -> tuple[int | None, int]:
    start = i
    value = 0
    while i < len(data) and i - start < 10:
        b = data[i]
        value |= (b & 0x7F) << (7 * (i - start))
        i += 1
        if b < 0x80:
            return value, i
    return None, i


def bitmap(frame: bytes) -> int | None:
    """Get protobuf field #1 from a 0x23 button notification."""
    if not frame or frame[0] != 0x23:
        return None
    i = 1
    while i < len(frame):
        tag, i = _varint(frame, i)
        if tag is None:
            return None
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, i = _varint(frame, i)
            if value is None:
                return None
            if field == 1:
                return value
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        elif wire == 2:
            length, i = _varint(frame, i)
            if length is None:
                return None
            i += length
        else:
            return None
        if i > len(frame):
            return None
    return None


class ClickMapper:
    """Physical button transitions -> OpenBikeControl press/release events.

    Shift buttons produce one press per physical tap, steering preserves holds,
    and every pressed button is released if Bluetooth disconnects.
    """

    def __init__(self, camera: str = "off"):
        self.camera = camera
        self.buttons = BUTTONS if camera == "off" else BUTTONS + (CAMERA_BUTTON,)
        self.pressed: set[int] = set()
        self.previous = KNOWN_MASK  # all known buttons released

    def _packet(self, action: int, pressed: bool) -> bytes:
        value = 5 if self.camera == "select5" else 1
        return bytes((0x01, action, (value if action == 0x40 else 1) if pressed else 0))

    def feed(self, frame: bytes) -> list[tuple[str, bool, bytes]]:
        cur = bitmap(frame)
        if cur is None:
            return []
        changed = (cur ^ self.previous) & KNOWN_MASK
        self.previous = cur
        events = []
        for bit, name, action in self.buttons:
            if not (changed & bit):
                continue
            down = not bool(cur & bit)
            if down:
                self.pressed.add(bit)
            else:
                self.pressed.discard(bit)
            events.append((name, down, self._packet(action, down)))
        return events

    def release_all(self) -> list[tuple[str, bool, bytes]]:
        released = [(name, False, self._packet(action, False))
                    for bit, name, action in self.buttons if bit in self.pressed]
        self.pressed.clear()
        self.previous = KNOWN_MASK
        return released


def describe(name: str, pressed: bool) -> str:
    return f"{name:4s} {'DOWN' if pressed else 'UP  '}"


async def discover_right(scanner) -> object:
    while True:
        print("Scanning for RIGHT Click V2 pod (press a button to wake it)...", flush=True)
        seen = await scanner.discover(timeout=8, return_adv=True)
        for device, advertisement in seen.values():
            maker = (advertisement.manufacturer_data or {}).get(ZWIFT_COMPANY, b"")
            if maker[:1] == bytes((RIGHT_POD,)):
                print(f"Found RIGHT: {advertisement.local_name or device.name} / {device.address}")
                return device
        await asyncio.sleep(2)


async def run_click(obc, args) -> None:
    from bleak import BleakClient, BleakScanner

    while True:
        mapper = ClickMapper(args.camera)
        worker = None
        try:
            device = await discover_right(BleakScanner)
            async with BleakClient(device, timeout=20) as client:
                print("BLE connected; subscribing to Click button stream...")
                loop = asyncio.get_running_loop()
                events = asyncio.Queue()
                write_lock = asyncio.Lock()
                last_rx = time.monotonic()
                last_ack = 0.0

                async def write(payload: bytes) -> None:
                    async with write_lock:
                        try:
                            await client.write_gatt_char(SYNC_RX, payload, response=False)
                        except Exception:
                            await client.write_gatt_char(SYNC_RX, payload, response=True)

                async def ack() -> None:
                    nonlocal last_ack
                    await write(b"\xff\x04\x00")
                    last_ack = time.monotonic()

                def enqueue(source: str, raw) -> None:
                    # BLE callbacks may arrive off the asyncio loop on macOS.
                    loop.call_soon_threadsafe(events.put_nowait, (source, bytes(raw)))

                async def consume() -> None:
                    nonlocal last_rx
                    while True:
                        source, frame = await events.get()
                        last_rx = time.monotonic()
                        if args.debug:
                            print(f"RX {source}: {frame.hex(' ')}")
                        if source == "async":
                            if frame.startswith(b"\xff\x03"):
                                # Right pod uses unsigned ACK; LEFT unlock isn't attempted.
                                await ack()
                                continue
                            for name, pressed, payload in mapper.feed(frame):
                                print(f"CLICK {describe(name, pressed)} -> OBC {payload.hex(' ')}")
                                await obc._broadcast(payload)
                        elif frame.startswith(b"RideOn"):
                            print("Click handshake acknowledged")
                            await ack()

                def on_async(_, raw):
                    enqueue("async", raw)

                def on_sync(_, raw):
                    enqueue("sync", raw)

                worker = asyncio.create_task(consume())
                await client.start_notify(ASYNC, on_async)
                try:
                    await client.start_notify(SYNC_TX, on_sync)
                except Exception as error:
                    print(f"Sync indication unavailable (non-fatal): {error}")

                for message in (b"RideOn\x02\x03", b"\x00\x08\x00", b"\x00\x08\x10"):
                    await write(message)
                    await asyncio.sleep(.1)

                print("READY: B=harder, +=easier, Z=steer left, A=steer right")
                if args.camera != "off":
                    print(f"Y=camera ({args.camera})")
                while client.is_connected:
                    await asyncio.sleep(3)
                    if worker.done():
                        # Don't silently ignore a notification processing crash.
                        worker.result()
                    if not client.is_connected:
                        break
                    if args.idle_reset and time.monotonic() - last_rx >= args.idle_reset:
                        print("Idle reset requested; reconnecting Click pod...")
                        await write(b"\x18")
                        break
                    if last_ack and time.monotonic() - last_ack >= 15:
                        await ack()
                    else:
                        await write(b"RideOn")
        except asyncio.CancelledError:
            raise
        except Exception as error:
            print(f"Click BLE error/disconnect: {type(error).__name__}: {error}")
        finally:
            if worker is not None:
                worker.cancel()
                with suppress(asyncio.CancelledError):
                    await worker
            # Ensure held steering or other actions don't stick in MyWhoosh.
            for name, pressed, payload in mapper.release_all():
                print(f"RELEASE {name} after disconnect -> OBC {payload.hex(' ')}")
                await obc._broadcast(payload)
        print("Reconnecting in 3 seconds...")
        await asyncio.sleep(3)


async def simulate(obc, args) -> None:
    """Exercise MyWhoosh/OpenBikeControl with no Click pod or trainer."""
    mapper = ClickMapper(args.camera)
    names = {name: action for _, name, action in mapper.buttons}
    names["+"] = names["PLUS"]
    keys = "B + Z A" if args.camera == "off" else "B + Z A Y"
    hold_seconds = {"Z": 2, "A": 2, "Y": 0.1}
    print(f"SIMULATE: type one of {keys} then Enter. Type q to quit.")
    print("Z and A hold steering for 2 seconds.")
    while True:
        key = (await asyncio.to_thread(input, "> ")).strip().upper()
        if key in ("Q", "QUIT", "EXIT"):
            return
        if key not in names:
            print(f"Valid: {keys} q")
            continue
        if not obc.clients:
            print("No OpenBikeControl client connected. Select Click Python Bridge in MyWhoosh and try again.")
            continue
        action = names[key]
        down = mapper._packet(action, True)
        up = mapper._packet(action, False)
        print(f"SIM {key} -> {down.hex(' ')} then {up.hex(' ')}")
        await obc._broadcast(down)
        await asyncio.sleep(hold_seconds.get(key, 0.035))
        await obc._broadcast(up)


async def main(args) -> None:
    from openbikecontrol import OpenBikeControlServer

    obc = OpenBikeControlServer(
        name="Click Python Bridge",
        device_id="click-python-bridge",
        model="Click-OBC-Bridge",
        debug=args.debug,
    )
    try:
        await obc.start()
        if args.simulate:
            await simulate(obc, args)
        else:
            await run_click(obc, args)
    finally:
        await obc.close()


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--camera", choices=("off", "select5", "cycle"), default="off",
                   help="Y is off by default. Select an experimental OpenBikeControl camera mode to enable it.")
    p.add_argument("--idle-reset", type=int, default=0, metavar="SECONDS",
                   help="Experimental: reset pod after idle; default OFF (Mac tests showed idle stability)")
    p.add_argument("--simulate", action="store_true",
                   help="Test OpenBikeControl by typing Click button names, without BLE")
    p.add_argument("--debug", action="store_true", help="Log BLE frames and OpenBikeControl app capabilities")
    return p.parse_args()


if __name__ == "__main__":
    try:
        asyncio.run(main(parse_args()))
    except KeyboardInterrupt:
        pass
