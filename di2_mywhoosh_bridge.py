#!/usr/bin/env python3
"""Shimano Di2 D-FLY -> OpenBikeControl -> MyWhoosh bridge.

This is a small proof-of-concept for macOS/Python.

What it does:
  1. Connects to Shimano Di2 over BLE with Bleak.
  2. Reads reverse-engineered D-FLY button events.
  3. Advertises itself as an OpenBikeControl controller over mDNS.
  4. MyWhoosh connects to it over TCP.
  5. D-FLY CH1/CH2 become virtual shift down/up actions.

The Shimano BLE details are reverse-engineered, not an official Shimano API.
Use --probe first on a new Di2 system to confirm the characteristic and packets.
"""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
from typing import Optional

from bleak import BleakClient, BleakScanner
from openbikecontrol import OBC_MSG_BUTTON_STATE, OpenBikeControlServer

# ----- Shimano Di2 (reverse-engineered) ------------------------------------
# Shimano vendor UUID base observed by community implementations.
DI2_SERVICE_UUID = "000018ef-5348-494d-414e-4f5f424c4500"
DI2_BUTTON_CHAR_UUID = "00002ac2-5348-494d-414e-4f5f424c4500"

# D-FLY event bits in each channel byte.
DFLY_SHORT = 0x10
DFLY_LONG = 0x20
DFLY_DOUBLE = 0x40
DFLY_UNMAPPED = 0xF0

OBC_SHIFT_UP = 0x01
OBC_SHIFT_DOWN = 0x02


async def shift(obc: OpenBikeControlServer, button_id: int) -> None:
    print(f"SHIFT {'UP' if button_id == OBC_SHIFT_UP else 'DOWN'} -> OpenBikeControl 0x{button_id:02x}")
    await obc._broadcast(bytes((OBC_MSG_BUTTON_STATE, button_id, 1)))
    await asyncio.sleep(0.025)
    await obc._broadcast(bytes((OBC_MSG_BUTTON_STATE, button_id, 0)))


@dataclass
class Di2Bridge:
    obc: OpenBikeControlServer
    up_channel: int = 2
    down_channel: int = 1
    button_char_uuid: str = DI2_BUTTON_CHAR_UUID
    last_counter: Optional[int] = None

    def _decode_packet(self, data: bytes) -> None:
        # Reverse-engineered D-FLY button packet:
        # [counter, ch1, ch2, ch3, ch4]
        if len(data) < 5:
            return

        counter = data[0]
        channels = list(data[1:5])
        print(
            f"Di2 packet counter={counter:02x} "
            + " ".join(f"CH{i+1}={v:02x}" for i, v in enumerate(channels))
        )

        # Avoid replaying an identical indication if the BLE stack duplicates it.
        # If your firmware legitimately reuses counters, remove these two lines.
        if counter == self.last_counter:
            return
        self.last_counter = counter

        for channel_num, value in enumerate(channels, start=1):
            if value == DFLY_UNMAPPED:
                continue

            # For this minimal bridge, only a normal short click shifts.
            if value & DFLY_SHORT:
                if channel_num == self.up_channel:
                    asyncio.create_task(self.shift(obc, OBC_SHIFT_UP))
                elif channel_num == self.down_channel:
                    asyncio.create_task(self.shift(obc, OBC_SHIFT_DOWN))

    async def scan(self):
        print("Scanning for Shimano Di2 BLE...")
        found = await BleakScanner.discover(timeout=10.0, return_adv=True)
        candidates = []
        for device, adv in found.values():
            name = adv.local_name or device.name or ""
            services = [s.lower() for s in (adv.service_uuids or [])]
            if "shimano" in name.lower() or DI2_SERVICE_UUID.lower() in services:
                candidates.append(device)
                print(f"  found {name or '<unnamed>'}: {device.address}")

        if not candidates:
            raise RuntimeError(
                "No Shimano Di2 found. Wake the bike / enter Di2 Bluetooth pairing mode, "
                "then try again."
            )
        return candidates[0]

    async def run(self, probe: bool = False) -> None:
        device = await self.scan()
        print(f"Connecting to Di2: {device.address}")

        async with BleakClient(device) as client:
            print("Di2 connected")

            # Print Shimano characteristics. This is useful because Shimano has
            # not published this as a stable public developer API.
            vendor_chars = []
            for service in client.services:
                for char in service.characteristics:
                    if "5348-494d-414e-4f5f424c4500" in char.uuid.lower():
                        vendor_chars.append(char)
                        print(f"  {char.uuid} [{', '.join(char.properties)}]")

            # Prefer the currently reverse-engineered button characteristic.
            target = client.services.get_characteristic(self.button_char_uuid)

            if target is None:
                print("\nExpected D-FLY button characteristic was not found:")
                print(f"  {self.button_char_uuid}")
                print("Run in --probe mode and press the Di2 buttons to identify which")
                print("notify/indicate characteristic carries the 5-byte D-FLY packets.")

                if not probe:
                    raise RuntimeError("Unknown Di2 button characteristic on this firmware")

                # Probe all Shimano vendor notify/indicate characteristics.
                targets = [
                    c
                    for c in vendor_chars
                    if "notify" in c.properties or "indicate" in c.properties
                ]
            else:
                targets = [target]

            loop = asyncio.get_running_loop()

            def make_handler(char_uuid: str):
                def handler(_sender, data: bytearray):
                    b = bytes(data)
                    print(f"BLE {char_uuid}: {b.hex(' ')}")
                    if not probe or char_uuid.lower() == self.button_char_uuid.lower():
                        loop.call_soon_threadsafe(self._decode_packet, b)
                return handler

            if not targets:
                raise RuntimeError("No Shimano notify/indicate characteristics found")

            for char in targets:
                await client.start_notify(char.uuid, make_handler(char.uuid))
                print(f"Subscribed: {char.uuid}")

            print("\nReady. Press Di2 D-FLY buttons. Ctrl+C to quit.")
            while client.is_connected:
                await asyncio.sleep(1.0)


async def keyboard_test(obc: OpenBikeControlServer) -> None:
    """Test MyWhoosh side without any Di2 hardware: u=up, d=down."""
    print("Keyboard test: type 'u' + Enter (harder), 'd' + Enter (easier), 'q' to quit")
    while True:
        cmd = (await asyncio.to_thread(input, "> ")).strip().lower()
        if cmd == "u":
            await shift(obc, OBC_SHIFT_UP)
        elif cmd == "d":
            await shift(obc, OBC_SHIFT_DOWN)
        elif cmd == "q":
            return


async def amain(args) -> None:
    obc = OpenBikeControlServer(
        name="Di2 Python Bridge",
        device_id="di2-python-bridge",
        model="Di2-OBC-Bridge",
    )
    try:
        await obc.start()
        if args.keyboard_test:
            await keyboard_test(obc)
            return

        bridge = Di2Bridge(
            obc=obc,
            up_channel=args.up_channel,
            down_channel=args.down_channel,
            button_char_uuid=args.char_uuid,
        )
        await bridge.run(probe=args.probe)
    finally:
        await obc.close()


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--up-channel",
        type=int,
        choices=(1, 2, 3, 4),
        default=2,
        help="D-FLY channel used for Shift Up / harder gear (default: 2)",
    )
    p.add_argument(
        "--down-channel",
        type=int,
        choices=(1, 2, 3, 4),
        default=1,
        help="D-FLY channel used for Shift Down / easier gear (default: 1)",
    )
    p.add_argument(
        "--char-uuid",
        default=DI2_BUTTON_CHAR_UUID,
        help="Override the reverse-engineered Di2 button characteristic UUID",
    )
    p.add_argument(
        "--probe",
        action="store_true",
        help="Subscribe broadly and print Shimano BLE notifications for protocol discovery",
    )
    p.add_argument(
        "--keyboard-test",
        action="store_true",
        help="Skip Di2; test OpenBikeControl/MyWhoosh using u/d keyboard commands",
    )
    return p.parse_args()


if __name__ == "__main__":
    try:
        asyncio.run(amain(parse_args()))
    except KeyboardInterrupt:
        pass
