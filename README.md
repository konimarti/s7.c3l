# s7.c3l

Siemens S7comm client library for [C3](http://c3-lang.org).

* The classic S7comm protocol of the S7-300/400 and, with PUT/GET enabled, S7-1200/1500 (not S7comm-plus).
* TPKT and COTP framing, Setup Communication (PDU size negotiation), Read Var and Write Var with automatic splitting
  into PDUs, system status lists (SZL: module, component, CPU state) and the PLC clock.
* An address parser (`DB1.DBX0.3`, `MW20`, ...) and the S7 value types (INT, REAL, STRING, DTL, S5TIME, ...).
* A sans-IO core (`Session`) with a blocking adapter (`Client`) over a small `Transport` interface; a TCP transport is
  included.
* `s7tool`, a small command line tool.
* Writes to a PLC are refused unless explicitly allowed.

Requires c3c v0.8.6 or newer. Licence: MIT.

## Reading and writing

```c3
module app;
import s7;

fn void? read_a_word(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	char[] bytes = client.read_bytes(s7::parse_address("DB1.DBW2")!, mem)!;
	defer free(bytes.ptr);
	assert(bytes.len == 2);
}
```

The transport of the example comes from `tcp_connect(host, port = 102, timeout)`, which returns a `TcpTransport`.
Writing needs `allow_write` in the configuration; without it every write is refused with `WRITE_NOT_ALLOWED` before
a single byte reaches the PLC:

```c3
module app;
import s7;

fn void? write_a_word(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	cfg.allow_write = true;
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	char[2] value = { 0x12, 0x34 };
	client.write_bytes(s7::parse_address("DB1.DBW2")!, value[..])!;
}
```

Several addresses go into one request; a large one is cut into PDUs of the negotiated size. Every item of the answer
carries its own fault, so one missing data block does not fail the others:

```c3
module app;
import std::io;
import s7;

fn void? read_many(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	s7::Address[2] items = { s7::parse_address("DB1.DBB0[200]")!, s7::parse_address("DB99.DBW0")! };
	s7::Completion done = client.read(items[..])!;
	defer done.free();
	if (done.results[1].status) io::printfn("DB99: %s", done.results[1].status);
}
```

`read`, `read_bytes`, `read_value`, `write` and `write_bytes`, `read_szl`, `cpu_info`, `cpu_state` and `read_clock`
return the PLC's answer or a fault. A client is not thread-safe: use one per thread.

Rack and slot (`tsaps_from_rack_slot(type, rack, slot)`): S7-300 and S7-400 are rack 0 slot 2, S7-1200 and S7-1500 are
rack 0 slot 1 (firmware dependent). S7-200 and LOGO! take raw TSAPs: build a `Tsaps` with `tsap_from_u16` or
`tsap_from_bytes` (1 to 16 bytes each).

## Addresses

`parse_address` takes (case-insensitive, no spaces):

| text | meaning |
|---|---|
| `DB1.DBX0.3` | bit 3 of byte 0 of DB1 |
| `DB1.DBB0`, `DB1.DBW2`, `DB1.DBD4` | byte, word, double word |
| `DB10.DBB0[16]` or `DB10.DBB0:16` | a range of 16 bytes |
| `DI2.DIW0` or `DI2.DBW0` | instance data block |
| `MB0`, `MW20`, `MD100`, `M20.1` | flags |
| `I0.1`, `IB4`, `E0.1` | inputs (`E` is the German spelling) |
| `Q4.0`, `QB4`, `A4.0` | outputs |
| `PIB4`, `PIW4`, `PQW8` | peripheral inputs and outputs |
| `T5`, `C3` (also `Z3`) | timer and counter |

Out of range numbers (`DB0`, a bit above 7, an offset above 2097151, a count above 65535) are `ADDRESS_RANGE`, anything
else that does not parse is `INVALID_ADDRESS_TEXT`. On the wire every item is a bit, byte, timer or counter item: a word
is read as two bytes.

## Values

`decode_value`, `encode_value` and `parse_value` convert between wire bytes and `Value` for BOOL, BYTE, WORD, DWORD, INT,
DINT, REAL, LREAL, CHAR, STRING, WSTRING, DATE, TIME, TOD, DATE_AND_TIME, DTL, S5TIME and BCD counters, big-endian.
`read_value(addr, kind, allocator)` reads and decodes in one call. STRING and CHAR are ISO 8859-1 on the wire and UTF-8
in the `Value`.

## Session: the sans-IO core

`Session` never does I/O and never reads a clock. The adapter gives it received bytes (`feed`), sends what
`pending_output` holds (then `consume_output`), passes the current monotonic time as a `std::time::Clock` and polls
`next_event` (`CONNECTED`, `JOB_DONE`, `JOB_FAILED`, `DISCONNECTED`). `next_deadline` says when to call `on_timeout`;
`on_closed` reports end of stream; `close` queues a Disconnect Request. One job is in flight at a time, and new jobs are
refused with `BUSY` while events are still waiting to be taken. The strictness switches `lenient_reserved`,
`lenient_pdu_ref` and `lenient_dst_ref` default to strict, strict, lenient.

## Transport

`Client` runs a `Session` over a `Transport`, a blocking byte stream with three methods, each taking a `Duration`
timeout (negative: no limit, zero: poll once):

```c3
interface Transport
{
	fn usz? read(char[] buf, time::Duration timeout);     // 1..buf.len bytes, or TIMEOUT / CLOSED
	fn void? write(char[] data, time::Duration timeout);  // all of data, or a fault
	fn void? close();                                     // idempotent
}
```

Any type with that method shape, for example a TLS transport, can be passed through an explicit cast:
`Transport t = (Transport)&other;`. `TcpTransport` waits with `poll` (`WSAPoll` on Windows), so the timeouts are real,
sets TCP_NODELAY and never raises SIGPIPE (`MSG_NOSIGNAL` on Linux, `SO_NOSIGPIPE` on macOS and the BSDs). A write that
fails or times out ends the connection: the client never repeats a frame that may have been sent in part. A connection
that cannot be established is `CONNECT_REFUSED`. `Client.close` closes the transport, also after an error on a connected client; after a failed `open` the transport still belongs to the caller, who closes it.

## s7tool

`c3c build s7tool` builds a small command line tool (`build/s7tool --help` lists everything):

```sh
s7tool --host 192.168.0.10 info
s7tool --host 192.168.0.10 read DB1.DBW2 --type INT
s7tool --host 192.168.0.10 dump DB1.DBB0 16
s7tool --host 192.168.0.10 write DB1.DBW2 515 --type INT --allow-write
```

`--model s7-300|s7-400|s7-1200|s7-1500|s7-200|logo` presets rack and slot (or the raw TSAPs of an S7-200 and a LOGO!);
`--rack`, `--slot` and `--tsap LOCAL:REMOTE` (hex) override it. `write` is refused (exit code 2) unless `--allow-write` is
given, and that check happens before any connection is made. Exit codes: 0 ok, 1 usage, 2 write refused, 3 connection or
protocol failure, 4 the PLC refused or lacks the object (`ACCESS_DENIED` prints a PUT/GET hint). Everything the PLC sends as
text is printed with control characters and invalid UTF-8 shown as `\xNN`.

## Safety

* Writes need `SessionConfig.allow_write` (the tool: `--allow-write`). Without it `submit_write` returns
  `WRITE_NOT_ALLOWED` and nothing is sent.
* Every length that comes from the network is checked against the frame before use; a frame larger than
  `Limits.max_frame` (8192 by default) is refused before it is buffered; a request is limited to 20 items and
  `Limits.max_request_bytes` (1 MiB).
* The core has no global state and the library uses only the allocators it is given.

## Testing

`c3c test` runs the unit tests: hex fixtures for every codec, the session against scripted frames, the client over a
scripted transport and over the loopback interface. The tests in `src/test/peer_test.c3` run against the python-snap7
server when `S7_PEER=host:port` is set and are skipped otherwise (each prints `PEER-RUN <name>` or `PEER-SKIP <name>`);
with `S7_PEER_REQUIRED=1` a missing peer is a failure.

```sh
# python-snap7 must be installed for the interpreter; S7_PEER_PYTHON defaults to python3
"${S7_PEER_PYTHON:-python3}" scripts/run_peer.py 10102 &
S7_PEER=127.0.0.1:10102 S7_PEER_REQUIRED=1 c3c test
```

`c3c build peercheck` builds a small runner for the same cases (`S7_PEER=127.0.0.1:10102 build/peercheck`; `--capture`
prints every frame that goes over the wire). `scripts/check_yaml.py .github/workflows/ci.yml` checks the CI workflow.

## Known limits and unverified items

Limits of version 0.1:

* One job in flight per connection; no pipelining.
* S7comm-plus (the protocol of S7-1200/1500 with "secure" communication) is not supported. S7-1200/1500 need PUT/GET
  access enabled and non-optimised data blocks, otherwise the PLC answers `ACCESS_DENIED`.
* No block upload/download, CPU start/stop or setting the clock.
* TSAPs are 1 to 16 bytes; connection types PG, OP and basic.
* DATE_AND_TIME and DTL carry no time zone: they are the PLC's local time. STRING and CHAR are Latin-1.
* A framing error or timeout ends the connection; reconnecting is the caller's decision.

Checked only against the python-snap7 server and hand-derived frames, not against hardware:

* The continuation request for a fragmented SZL answer (the sequence number is echoed in the parameter); the peer never
  fragments.
* Timers and counters are written as octet strings (transport size 0x09).
* Whether a PLC keeps the connection open after an answer with a header error.
* INT, REAL and DINT items are read as bytes; their answers (transport sizes 0x05 and 0x07) are untested.
* The python-snap7 server answers SZL 0x001C with a record length of 0 (not like a real PLC), reads a bit as a whole byte
  and always negotiates 480 bytes; `cpu_info` refuses its 0x001C answer.
* macOS and Windows builds are checked by the compiler for the target but run only in CI.
