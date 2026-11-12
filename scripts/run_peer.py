#!/usr/bin/env python3
"""Start a python-snap7 server as the test peer of the S7 client tests.

usage: run_peer.py PORT

The server is only run, never copied. Areas registered:
  DB1 256 bytes, byte i = i          DB2 8192 bytes, byte i = (i * 7 + 3) mod 256
  MK/PE/PA 64 bytes, byte i = i + 16 CT/TM 16 bytes, byte i = i
A DB that is not registered (for example DB99) answers with "object does not exist".
The script prints "READY <port>" once it listens and runs until it is killed.
Use the interpreter that has python-snap7 installed (the tests take it from S7_PEER_PYTHON).
"""
import sys
import time

from snap7.server import Server
from snap7.type import SrvArea


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    port = int(sys.argv[1])
    if port < 1024:
        print("use a port >= 1024")
        return 2
    server = Server(log=False)
    db1 = bytearray(range(256))
    db2 = bytearray((i * 7 + 3) % 256 for i in range(8192))
    server.register_area(SrvArea.DB, 1, db1)
    server.register_area(SrvArea.DB, 2, db2)
    server.register_area(SrvArea.MK, 0, bytearray((i + 16) % 256 for i in range(64)))
    server.register_area(SrvArea.PE, 0, bytearray((i + 16) % 256 for i in range(64)))
    server.register_area(SrvArea.PA, 0, bytearray((i + 16) % 256 for i in range(64)))
    server.register_area(SrvArea.CT, 0, bytearray(range(16)))
    server.register_area(SrvArea.TM, 0, bytearray(range(16)))
    server.start(tcp_port=port)
    print("READY", port, flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
