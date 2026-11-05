"""OpenBikeControl TCP server and mDNS discovery."""

from __future__ import annotations

import asyncio
import socket
from dataclasses import dataclass, field
from typing import Optional

from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

# ----- OpenBikeControl v1 ---------------------------------------------------
OBC_SERVICE_TYPE = "_openbikecontrol._tcp.local."
OBC_SERVICE_UUID = "d273f680-d548-419d-b9d1-fa0472345229"
OBC_MSG_BUTTON_STATE = 0x01
OBC_MSG_DEVICE_STATUS = 0x02


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
    name: str
    device_id: str
    model: str
    host: str = field(default_factory=get_local_ipv4)
    server: Optional[asyncio.AbstractServer] = None
    zeroconf: Optional[AsyncZeroconf] = None
    clients: set[asyncio.StreamWriter] = field(default_factory=set)

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle_client, "0.0.0.0", 0)
        port = self.server.sockets[0].getsockname()[1]

        hostname = socket.gethostname().replace(" ", "-") + ".local."
        service_name = f"{self.name}.{OBC_SERVICE_TYPE}"
        properties = {
            "version": "1",
            "id": self.device_id,
            "name": self.name,
            "service-uuids": OBC_SERVICE_UUID,
            "manufacturer": "Python",
            "model": self.model,
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
