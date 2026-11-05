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
import socket
from dataclasses import dataclass, field
from typing import Optional

from bleak import BleakClient, BleakScanner
from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

# ----- Shimano Di2 (reverse-engineered) ------------------------------------
# Shimano vendor UUID base observed by community implementations.
DI2_SERVICE_UUID = "000018ef-5348-494d-414e-4f5f424c4500"
DI2_BUTTON_CHAR_UUID = "00002ac2-5348-494d-414e-4f5f424c4500"

# D-FLY event bits in each channel byte.
DFLY_SHORT = 0x10
DFLY_LONG = 0x20
DFLY_DOUBLE = 0x40
DFLY_UNMAPPED = 0xF0

# ----- OpenBikeControl v1 ---------------------------------------------------
OBC_SERVICE_TYPE = "_openbikecontrol._tcp.local."
OBC_SERVICE_UUID = "d273f680-d548-419d-b9d1-fa0472345229"
OBC_MSG_BUTTON_STATE = 0x01
OBC_MSG_DEVICE_STATUS = 0x02
OBC_SHIFT_UP = 0x01
OBC_SHIFT_DOWN = 0x02


def get_local_ipv4() -> str:
    """Best-effort LAN IPv4 address for mDNS advertisement."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packet is actually sent; connect() asks the OS which interface
        # it would use for an outbound IPv4 route.
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    finally:
        s.close()

    host = socket.gethostname()
    for ip in socket.gethostbyname_ex(host)[2]:
        if ip and not ip.startswith("127."):
            return ip
    raise RuntimeError("Could not determine a non-loopback IPv4 address")


@dataclass
class OpenBikeControlServer:
    name: str = "Di2 Python Bridge"
    host: str = field(default_factory=get_local_ipv4)
    server: Optional[asyncio.AbstractServer] = None
    zeroconf: Optional[AsyncZeroconf] = None
    clients: set[asyncio.StreamWriter] = field(default_factory=set)
    debug: bool = False

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle_client, "0.0.0.0", 0)
        port = self.server.sockets[0].getsockname()[1]

        hostname = socket.gethostname().replace(" ", "-") + ".local."
        service_name = f"{self.name}.{OBC_SERVICE_TYPE}"
        properties = {
            "version": "1",
            "id": "di2-python-bridge",
            "name": self.name,
            "service-uuids": OBC_SERVICE_UUID,
            "manufacturer": "Python",
            "model": "Di2-OBC-Bridge",
        }

        service_info = ServiceInfo(
            type_=OBC_SERVICE_TYPE,
            name=service_name,
            addresses=[socket.inet_aton(self.host)],
            port=port,
            properties=properties,
            server=hostname,
        )
        self.zeroconf = AsyncZeroconf()
        announcement = await self.zeroconf.async_register_service(service_info)
        await announcement

        print(f"OpenBikeControl advertised as: {self.name}")
        print(f"  {self.host}:{port}")
        print("  In MyWhoosh, open Connections and select OpenBikeControl.")

    async def close(self) -> None:
        for writer in list(self.clients):
            writer.close()
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        if self.zeroconf:
            await self.zeroconf.async_close()

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = writer.get_extra_info("peername")
        try:
            # Report ready with no battery reading, as in the TCP reference controller.
            writer.write(bytes((OBC_MSG_DEVICE_STATUS, 0xFF, 0x01)))
            await writer.drain()
            self.clients.add(writer)
            print(f"MyWhoosh/OpenBikeControl client connected: {peer}")
            if self.debug:
                await self._log_client_capabilities(reader)
            while await reader.read(1024):
                pass
        except (ConnectionError, asyncio.IncompleteReadError, asyncio.CancelledError):
            pass
        finally:
            self.clients.discard(writer)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
            print(f"OpenBikeControl client disconnected: {peer}")

    async def _log_client_capabilities(self, reader: asyncio.StreamReader) -> None:
        while True:
            message_type = (await reader.readexactly(1))[0]
            if message_type == 0x03:  # Haptic feedback
                await reader.readexactly(3)
                continue
            if message_type != 0x04:  # App Information
                print(f"OpenBikeControl RX unknown message type 0x{message_type:02x}")
                return
            version, app_length = await reader.readexactly(2)
            if version != 1:
                print(f"OpenBikeControl App Information version {version} is unknown")
                return
            app = await reader.readexactly(app_length)
            app_version = await reader.readexactly((await reader.readexactly(1))[0])
            buttons = await reader.readexactly((await reader.readexactly(1))[0])
            print(f"OpenBikeControl App Information from {app!r} {app_version!r}: "
                  f"button IDs {buttons.hex(' ') or 'all (per protocol)'}")

    async def _broadcast(self, payload: bytes) -> None:
        dead: list[asyncio.StreamWriter] = []
        for writer in list(self.clients):
            try:
                writer.write(payload)
                await writer.drain()
            except (ConnectionError, OSError):
                dead.append(writer)
        for writer in dead:
            self.clients.discard(writer)

    async def tap(self, button_id: int) -> None:
        """Send one OpenBikeControl press + release transition."""
        press = bytes([OBC_MSG_BUTTON_STATE, button_id, 0x01])
        release = bytes([OBC_MSG_BUTTON_STATE, button_id, 0x00])
        await self._broadcast(press)
        await asyncio.sleep(0.025)
        await self._broadcast(release)

    async def shift_up(self) -> None:
        print("SHIFT UP   -> OpenBikeControl 0x01")
        await self.tap(OBC_SHIFT_UP)

    async def shift_down(self) -> None:
        print("SHIFT DOWN -> OpenBikeControl 0x02")
        await self.tap(OBC_SHIFT_DOWN)


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
                    asyncio.create_task(self.obc.shift_up())
                elif channel_num == self.down_channel:
                    asyncio.create_task(self.obc.shift_down())

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
            await obc.shift_up()
        elif cmd == "d":
            await obc.shift_down()
        elif cmd == "q":
            return


async def amain(args) -> None:
    obc = OpenBikeControlServer()
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
