module s7;

import std::io, std::os::env, std::time;

// The cases that run against a real S7 server (the python-snap7 server, started with scripts/run_peer.py). They are
// plain functions so that a small executable can run them too; peer_test.c3 wraps each one in an @test that is
// skipped unless S7_PEER=host:port is set. With S7_PEER_REQUIRED=1 a missing peer is a failure instead of a skip.
// Every case prints PEER-RUN <name> or PEER-SKIP <name>.

alias PeerCaseFn = fn void(Client* c, Allocator allocator);

struct PeerCase
{
	String name;
	PeerCaseFn run;
	bool write;                  // the case needs SessionConfig.allow_write
}

// Records the bytes of every read and write when `log` is set (the executable prints them as captures).
struct CaptureTransport (Transport)
{
	TcpTransport* inner;
	bool log;
}

fn void print_capture(String direction, char[] bytes)
{
	io::printf("PEER-CAPTURE %s", direction);
	foreach (b : bytes) io::printf(" %02X", b);
	io::printn("");
}

fn usz? CaptureTransport.read(&self, char[] buf, time::Duration timeout) @dynamic
{
	usz n = self.inner.read(buf, timeout)!;
	if (self.log) print_capture("R", buf[:n]);
	return n;
}

fn void? CaptureTransport.write(&self, char[] data, time::Duration timeout) @dynamic
{
	if (self.log) print_capture("W", data);
	return self.inner.write(data, timeout);
}

fn void? CaptureTransport.close(&self) @dynamic
{
	return self.inner.close();
}

fn bool peer_required() => (env::tget_var("S7_PEER_REQUIRED") ?? "") == "1";

// Runs one case. Returns false when it was skipped.
fn bool peer_execute(PeerCase pc, bool capture)
{
	String? address = env::tget_var("S7_PEER");
	if (catch address)
	{
		io::printfn("PEER-SKIP %s", pc.name);
		assert(!peer_required(), "S7_PEER_REQUIRED is set but S7_PEER is not");
		return false;
	}
	usz colon = 0;
	foreach (i, c : address) if (c == ':') colon = (usz)i;
	String host = address[:colon];
	int port = address[colon + 1..].to_int()!!;
	io::printfn("PEER-RUN %s", pc.name);
	TcpTransport tcp = tcp_connect(host, port)!!;
	CaptureTransport cap = { &tcp, capture };
	SessionConfig cfg = default_config(tsaps_from_rack_slot(PG, 0, 2)!!);
	cfg.allow_write = pc.write;
	TrackingAllocator alloc;
	alloc.init(mem);
	Client client;
	client.open(&cap, cfg, &alloc)!!;
	io::printfn("PEER-INFO %s pdu %d", pc.name, (int)client.pdu_size());
	pc.run(&client, &alloc);
	client.close();
	assert(!alloc.has_leaks(), "the client leaked memory against the peer");
	alloc.free();
	return true;
}

// ---- the cases ----

fn void expect_bytes(char[] got, char[] want)
{
	assert(got.len == want.len, "length %d, wanted %d", (int)got.len, (int)want.len);
	foreach (i, b : want) assert(got[i] == b, "byte %d is %d, wanted %d", (int)i, (int)got[i], (int)b);
}

fn char[] read_free(Client* c, Allocator allocator, String text)
{
	return c.read_bytes(parse_address(text)!!, allocator)!!;
}

fn void case_read_range(Client* c, Allocator a)
{
	char[] data = read_free(c, a, "DB1.DBB0[16]");
	char[16] want;
	foreach (i, &b : want) *b = (char)i;
	expect_bytes(data, want[..]);
	alloc::free(a, data.ptr);
}

fn void case_read_word_and_bits(Client* c, Allocator a)
{
	Value w = c.read_value(parse_address("DB1.DBW2")!!, WORD, a)!!;
	assert(w.u == 0x0203);
	Value d = c.read_value(parse_address("DB1.DBD4")!!, DWORD, a)!!;
	assert(d.u == 0x04050607);
	// byte 0 is 0 and byte 1 is 1. (The python-snap7 server answers a bit read with the whole byte, so only bits that
	// give the same answer for a real PLC are asserted.)
	assert(!c.read_value(parse_address("DB1.DBX0.0")!!, BOOL, a)!!.b);
	assert(c.read_value(parse_address("DB1.DBX1.0")!!, BOOL, a)!!.b);
}

fn void case_write_and_read_back(Client* c, Allocator a)
{
	char[2] value = { 0xBE, 0xEF };
	c.write_bytes(parse_address("DB2.DBW5000")!!, value[..])!!;
	Value back = c.read_value(parse_address("DB2.DBW5000")!!, WORD, a)!!;
	assert(back.u == 0xBEEF);
	char[4] dword = { 0x01, 0x02, 0x03, 0x04 };
	c.write_bytes(parse_address("DB2.DBD5004")!!, dword[..])!!;
	assert(c.read_value(parse_address("DB2.DBD5004")!!, DWORD, a)!!.u == 0x01020304);
}

fn void case_write_is_refused_without_allow_write(Client* c, Allocator a)
{
	char[2] value = { 1, 2 };
	assert(@catch(c.write_bytes(parse_address("DB2.DBW0")!!, value[..])) == WRITE_NOT_ALLOWED);
	// the connection is untouched
	char[] data = read_free(c, a, "DB1.DBB0[4]");
	assert(data.len == 4);
	alloc::free(a, data.ptr);
}

fn void case_read_4000_bytes_of_db2(Client* c, Allocator a)
{
	time::Clock start = time::clock::now();
	char[] data = read_free(c, a, "DB2.DBB0[4000]");
	io::printfn("PEER-INFO read 4000 bytes at pdu %d took %d ms", (int)c.pdu_size(), (int)time::clock::now().nano_diff(start).to_ms());
	assert(data.len == 4000);
	foreach (i, b : data) assert(b == (char)((i * 7 + 3) % 256), "byte %d", (int)i);
	alloc::free(a, data.ptr);
}

fn void case_multi_read_25_items(Client* c, Allocator a)
{
	Address[25] items;
	foreach (i, &item : items) *item = parse_address(string::tformat("DB1.DBB%d", (int)(i * 3)))!!;
	Completion done = c.read(items[..])!!;
	assert(done.results.len == 25);
	foreach (i, r : done.results)
	{
		assert(!r.status && r.data.len == 1 && r.data[0] == (char)(i * 3), "item %d", (int)i);
	}
	done.free();
}

fn void case_missing_db_is_object_does_not_exist(Client* c, Allocator a)
{
	assert(@catch(c.read_bytes(parse_address("DB99.DBB0")!!, a)) == OBJECT_DOES_NOT_EXIST);
	// outside the registered area
	assert(@catch(c.read_bytes(parse_address("DB1.DBB250[16]")!!, a)) == ADDRESS_OUT_OF_RANGE);
	// the connection is still good
	char[] data = read_free(c, a, "DB1.DBB0[2]");
	assert(data.len == 2);
	alloc::free(a, data.ptr);
}

fn void case_merker_inputs_outputs(Client* c, Allocator a)
{
	char[] m = read_free(c, a, "MB0[4]");
	char[4] want = { 16, 17, 18, 19 };
	expect_bytes(m, want[..]);
	alloc::free(a, m);
	char[] i = read_free(c, a, "IB2[2]");
	char[2] want_i = { 18, 19 };
	expect_bytes(i, want_i[..]);
	alloc::free(a, i);
	char[] q = read_free(c, a, "QB4");
	assert(q.len == 1 && q[0] == 20);
	alloc::free(a, q);
}

fn void case_timers_and_counters(Client* c, Allocator a)
{
	char[] t = read_free(c, a, "T1");
	io::printfn("PEER-INFO T1 -> %d bytes", (int)t.len);
	assert(t.len == 2);
	alloc::free(a, t.ptr);
	char[] k = read_free(c, a, "C2[2]");
	io::printfn("PEER-INFO C2[2] -> %d bytes", (int)k.len);
	assert(k.len == 4);
	alloc::free(a, k.ptr);
}

fn void case_cpu_state_info_and_clock(Client* c, Allocator a)
{
	assert(c.cpu_state()!! == RUN);
	// The python-snap7 server answers SZL 0x001C with a record length and count of 0 and a raw 210 byte body, which a real
	// PLC does not do; the client refuses such an answer. A server with proper records gives the names.
	CpuInfo? info = c.cpu_info(a);
	if (try i = info)
	{
		io::printfn("PEER-INFO module '%s' name '%s' serial '%s' type '%s'", i.module_name, i.plant_id, i.serial, i.module_type_name);
		assert(i.module_name.len > 0 || i.module_type_name.len > 0);
		i.free(a);
	}
	else
	{
		io::printn("PEER-INFO cpu_info refused the answer of this peer");
		assert(@catch(info) == BAD_RESPONSE);
	}
	assert(c.cpu_state()!! == RUN);
	Dtl clock = c.read_clock()!!;
	io::printfn("PEER-INFO clock %d-%d-%d %d:%d:%d", (int)clock.year, (int)clock.month, (int)clock.day, (int)clock.hour, (int)clock.minute, (int)clock.second);
	assert(clock.year >= 2020);
}

fn void case_module_identification(Client* c, Allocator a)
{
	Completion szl = c.read_szl(0x0011, 0)!!;
	io::printfn("PEER-INFO SZL 0011: %d records of %d bytes", (int)szl.rec_count, (int)szl.rec_len);
	assert(szl.payload.len > 0 && szl.rec_len > 0);
	szl.free();
}

fn void case_an_unavailable_list_keeps_the_connection_usable(Client* c, Allocator a)
{
	assert(@catch(c.read_szl(0x0999, 0)) == NOT_SUPPORTED);
	char[] data = read_free(c, a, "DB1.DBB0[2]");
	assert(data.len == 2);
	alloc::free(a, data.ptr);
	assert(c.cpu_state()!! == RUN);
}

// The exchanges whose frames are kept as fixtures (peer_fixtures.c3): a read, a write of 0x1234 and the restore of the word.
fn void case_exchanges_kept_as_fixtures(Client* c, Allocator a)
{
	Value before = c.read_value(parse_address("DB1.DBW2")!!, WORD, a)!!;
	assert(before.u == 0x0203);
	char[2] value = { 0x12, 0x34 };
	c.write_bytes(parse_address("DB1.DBW2")!!, value[..])!!;
	assert(c.read_value(parse_address("DB1.DBW2")!!, WORD, a)!!.u == 0x1234);
	char[2] original = { 0x02, 0x03 };
	c.write_bytes(parse_address("DB1.DBW2")!!, original[..])!!;
	assert(c.read_value(parse_address("DB1.DBW2")!!, WORD, a)!!.u == 0x0203);
}

const PeerCase[] PEER_CASES = {
	{ "read range", &case_read_range, false },
	{ "read word and bits", &case_read_word_and_bits, false },
	{ "write and read back", &case_write_and_read_back, true },
	{ "write refused without allow_write", &case_write_is_refused_without_allow_write, false },
	{ "read 4000 bytes of DB2", &case_read_4000_bytes_of_db2, false },
	{ "multi read of 25 items", &case_multi_read_25_items, false },
	{ "missing DB and range errors", &case_missing_db_is_object_does_not_exist, false },
	{ "merker inputs outputs", &case_merker_inputs_outputs, false },
	{ "timers and counters", &case_timers_and_counters, false },
	{ "cpu state info and clock", &case_cpu_state_info_and_clock, false },
	{ "module identification", &case_module_identification, false },
	{ "unavailable list keeps the connection usable", &case_an_unavailable_list_keeps_the_connection_usable, false },
	{ "exchanges kept as fixtures", &case_exchanges_kept_as_fixtures, true },
};
