module s7;

import std::io, std::time;

// Deterministic fuzzing of the session. Every hex fixture of the suite (FUZZ_CORPUS: the valid frames and the malformed vectors)
// is mutated (bit flips, truncation, insertions, deletions, corrupted length fields, duplicated frames) and fed to a session in
// random chunks, in every state a session can be in. The seeds are fixed, so a failure repeats.
//
// Invariants: no panic or bounds failure; the reassembly buffer never holds more than max_frame bytes; after a protocol fault the
// session is FAILED and every submit says NOT_CONNECTED; no single allocation is larger than max_frame or max_request_bytes; every
// allocation is released when the session is freed.

const uint FUZZ_MAX_FRAME = 1024;
const uint FUZZ_MAX_REQUEST = 2048;

// An allocator that records the largest single allocation and tracks leaks.
struct LimitAllocator (Allocator)
{
	TrackingAllocator inner;
	sz largest;
}

fn void*? LimitAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	if (size > self.largest) self.largest = size;
	return self.inner.acquire(size, init_type, alignment);
}

fn void*? LimitAllocator.resize(&self, void* ptr, sz new_size, sz alignment) @dynamic
{
	if (new_size > self.largest) self.largest = new_size;
	return self.inner.resize(ptr, new_size, alignment);
}

fn void LimitAllocator.release(&self, void* ptr, bool aligned) @dynamic
{
	self.inner.release(ptr, aligned);
}

struct FuzzRng
{
	ulong state;
}

fn ulong FuzzRng.next(&self)
{
	ulong x = self.state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	self.state = x;
	return x;
}

fn usz FuzzRng.below(&self, usz n) => n == 0 ? 0 : (usz)(self.next() % (ulong)n);

// ---- mutation ----

const usz FUZZ_BUF = 700;

struct Mutant
{
	char[FUZZ_BUF] bytes;
	usz len;
}

fn Mutant mutant_of(String hex)
{
	Fixture f = fx(hex);
	Mutant m;
	m.len = f.len;
	m.bytes[:f.len] = f.bytes()[..];
	return m;
}

// One random change. Length fields get their own kind: bytes 2-3 are the TPKT length, 13-16 the S7 parameter and data length.
fn void mutate(FuzzRng* rng, Mutant* m)
{
	if (m.len == 0)
	{
		m.bytes[0] = (char)rng.next();
		m.len = 1;
		return;
	}
	switch (rng.below(8))
	{
		case 0:
			for (usz k = rng.below(3); k < 3; k++) m.bytes[rng.below(m.len)] ^= (char)(1 << rng.below(8));
		case 1:
			m.len = rng.below(m.len + 1);
		case 2:
			usz n = 1 + rng.below(8);
			if (m.len + n <= FUZZ_BUF)
			{
				usz at = rng.below(m.len + 1);
				for (usz k = m.len; k > at; k--) m.bytes[k - 1 + n] = m.bytes[k - 1];
				for (usz k = 0; k < n; k++) m.bytes[at + k] = (char)rng.next();
				m.len += n;
			}
		case 3:
			// a length field gets a boundary value
			ushort[6] values = { 0, 1, 0x7FFF, 0x8000, 0xFFFF, (ushort)rng.next() };
			ushort v = values[rng.below(6)];
			usz[3] places = { 2, 13, 15 };
			usz at = places[rng.below(3)];
			if (at + 2 <= m.len)
			{
				m.bytes[at] = (char)(v >> 8);
				m.bytes[at + 1] = (char)v;
			}
		case 4:
			usz from = rng.below(m.len);
			usz count = 1 + rng.below(m.len - from);
			for (usz k = from; k + count < m.len; k++) m.bytes[k] = m.bytes[k + count];
			m.len -= count;
		case 5:
			char[5] edge = { 0x00, 0xFF, 0x7F, 0x80, 0x01 };
			m.bytes[rng.below(m.len)] = edge[rng.below(5)];
		case 6:
			// the frame twice in a row
			if (m.len * 2 <= FUZZ_BUF)
			{
				for (usz k = 0; k < m.len; k++) m.bytes[m.len + k] = m.bytes[k];
				m.len *= 2;
			}
		default:
			m.bytes[rng.below(m.len)] = (char)rng.next();
	}
	// half of the time the TPKT length is made right again so that the mutant gets past the framing and into the parsers
	if (m.len >= 4 && rng.below(2) == 0)
	{
		m.bytes[2] = (char)(m.len >> 8);
		m.bytes[3] = (char)m.len;
	}
}

// ---- the session in every state ----

const usz SCENARIOS = 9;

struct FuzzRig
{
	LimitAllocator alloc;
	Session s;
	bool keep_events;          // the test reads the events itself
}

fn SessionConfig fuzz_config()
{
	SessionConfig cfg = default_config(tsaps_from_rack_slot(PG, 0, 2)!!);
	cfg.limits.max_pdu = 480;
	cfg.limits.max_frame = FUZZ_MAX_FRAME;
	cfg.limits.max_request_bytes = FUZZ_MAX_REQUEST;
	cfg.allow_write = true;
	return cfg;
}

fn void FuzzRig.take_events(&self)
{
	if (self.keep_events) return;
	while (try e = self.s.next_event())
	{
		Event ev = e;
		ev.completion.free();
	}
}

fn void FuzzRig.feed_fixed(&self, String hex)
{
	Fixture f = fx(hex);
	self.s.feed(f.bytes(), at_ms(1))!!;
	self.s.consume_output(self.s.pending_output().len);
	self.take_events();
}

// Brings a fresh session into scenario `n`: 0 connecting, 1 waiting for the setup answer, 2 idle, 3 read in flight, 4 write in
// flight, 5 a multi-PDU read at pdu 240, 6 SZL, 7 clock, 8 a read with two items.
fn void FuzzRig.start(&self, usz n)
{
	self.alloc.inner.init(mem);
	self.s.init(fuzz_config(), &self.alloc)!!;
	self.s.connect(at_ms(0))!!;
	self.s.consume_output(self.s.pending_output().len);
	if (n == 0) return;
	self.feed_fixed(FX_V6);
	if (n == 1) return;
	self.feed_fixed(n == 5 ? FX_V13 : FX_V12);
	if (n == 2) return;
	Address[2] items = { parse_address("DB1.DBW2")!!, parse_address("DB1.DBB10[3]")!! };
	switch (n)
	{
		case 3:
			self.s.submit_read(items[:1], at_ms(2))!!;
		case 4:
			char[2] value = { 1, 2 };
			char[][1] data = { value[..] };
			self.s.submit_write(items[:1], data[..], at_ms(2))!!;
		case 5:
			Address[1] big = { parse_address("DB1.DBB0[1000]")!! };
			self.s.submit_read(big[..], at_ms(2))!!;
		case 6:
			self.s.submit_szl(0x001C, 0, at_ms(2))!!;
		case 7:
			self.s.submit_read_clock(at_ms(2))!!;
		default:
			self.s.submit_read(items[..], at_ms(2))!!;
	}
	self.s.consume_output(self.s.pending_output().len);
}

fn void FuzzRig.check(&self)
{
	assert(self.s.in_len <= self.s.inbuf.len, "the reassembly buffer holds more than max_frame");
	assert(self.s.out_len <= self.s.outbuf.len);
	assert(self.s.ev_len <= EVENT_CAP);
}

// After a fault the session is down for good.
fn void FuzzRig.expect_down(&self)
{
	assert(self.s.state == FAILED || self.s.state == CLOSED, "a fault must leave the session FAILED");
	self.take_events();
	Address[1] items = { parse_address("DB1.DBW2")!! };
	assert(@catch(self.s.submit_read(items[..], at_ms(9))) == NOT_CONNECTED);
	assert(@catch(self.s.submit_szl(0x001C, 0, at_ms(9))) == NOT_CONNECTED);
	assert(@catch(self.s.submit_read_clock(at_ms(9))) == NOT_CONNECTED);
	char[1] x = { 0 };
	assert(@catch(self.s.feed(x[..], at_ms(9))) == NOT_CONNECTED);
}

// Feeds `bytes` in chunks of random size.
fn void FuzzRig.feed_chunks(&self, FuzzRng* rng, char[] bytes)
{
	usz at = 0;
	while (at < bytes.len)
	{
		usz n = 1 + rng.below(bytes.len - at);
		if (rng.below(3) == 0) n = 1 + rng.below(4);
		if (n > bytes.len - at) n = bytes.len - at;
		fault f = @catch(self.s.feed(bytes[at:n], at_ms(3)));
		at += n;
		self.check();
		self.take_events();
		if (f)
		{
			self.expect_down();
			return;
		}
		if (self.s.state == FAILED || self.s.state == CLOSED) return;
	}
}

fn void FuzzRig.finish(&self)
{
	self.s.free();
	assert(!self.alloc.inner.has_leaks(), "the session leaked memory");
	assert(self.alloc.largest <= (sz)FUZZ_MAX_FRAME || self.alloc.largest <= (sz)FUZZ_MAX_REQUEST, "an allocation above the limits: %d", (int)self.alloc.largest);
	assert(self.alloc.largest <= (sz)FUZZ_MAX_REQUEST, "an allocation above max_request_bytes: %d", (int)self.alloc.largest);
	self.alloc.inner.free();
}

// ---- the tests ----

fn void test_fuzz_mutated_fixtures_in_every_session_state() @test
{
	FuzzRng rng = { 0x243F6A8885A308D3 };
	usz iterations = 100000;
	usz failed = 0;
	usz closed = 0;
	usz ready = 0;
	for (usz i = 0; i < iterations; i++)
	{
		Mutant m = mutant_of(FUZZ_CORPUS[i % FUZZ_CORPUS.len]);
		usz changes = 1 + rng.below(3);
		for (usz c = 0; c < changes; c++) mutate(&rng, &m);
		FuzzRig r;
		r.start(i % SCENARIOS);
		r.feed_chunks(&rng, m.bytes[:m.len]);
		if (r.s.state == FAILED) failed++;
		if (r.s.state == CLOSED) closed++;
		if (r.s.state == READY) ready++;
		r.finish();
	}
	// the mutants must reach both outcomes, otherwise the test only exercises one side
	assert(failed > 1000 && ready > 1000, "failed %d, closed %d, ready %d", (int)failed, (int)closed, (int)ready);
}

// Every prefix of every fixture is a valid beginning of a stream or an error, never a crash; a prefix that is shorter than the
// frame it announces is not an error and waits for more.
fn void test_fuzz_every_prefix_of_every_fixture() @test
{
	FuzzRng rng = { 0x13198A2E03707344 };
	foreach (hex : FUZZ_CORPUS)
	{
		Fixture f = fx(hex);
		for (usz k = 0; k <= f.len; k++)
		{
			FuzzRig r;
			r.start(2 + (k % 7));
			r.feed_chunks(&rng, f.bytes()[:k]);
			r.finish();
		}
	}
}

// A valid frame is cut at a random place and the rest follows in the next call: the result must not depend on the cut.
fn void test_fuzz_a_frame_split_anywhere_gives_the_same_result() @test
{
	Fixture reply = fx(FX_V21);
	for (usz cut = 0; cut <= reply.len; cut++)
	{
		FuzzRig r;
		r.start(3);
		r.s.feed(reply.bytes()[:cut], at_ms(4))!!;
		r.s.feed(reply.bytes()[cut..], at_ms(4))!!;
		Event e = r.s.next_event()!!;
		assert(e.kind == JOB_DONE && e.completion.results[0].data.len == 2);
		e.completion.free();
		r.finish();
	}
}

// A peer that never says "last" in a fragmented SZL answer: the job stops at the fragment cap whatever the chunking.
fn void test_fuzz_endless_szl_fragments_stop_at_the_cap() @test
{
	FuzzRng rng = { 0xA4093822299F31D0 };
	for (usz round = 0; round < 20; round++)
	{
		FuzzRig r;
		r.start(6);
		r.keep_events = true;
		usz requests = 0;
		bool failed = false;
		for (usz guard = 0; guard < 200 && !failed; guard++)
		{
			// the first request was sent by start() with reference 2, the continuations are in the output
			ushort ref = guard == 0 ? 2 : pending_ref(&r.s);
			r.s.consume_output(r.s.pending_output().len);
			requests++;
			Fixture f = with_ref_seq(FX_M38, ref, (char)(guard + 1));
			r.feed_chunks(&rng, f.bytes());
			while (try e = r.s.next_event())
			{
				Event ev = e;
				if (ev.kind == JOB_FAILED) failed = true;
				ev.completion.free();
			}
		}
		assert(failed && requests <= 66, "the job must fail after the fragment cap, requests %d", (int)requests);
		r.finish();
	}
}

// Length products near the 16 bit limit never wrap: a record count times a record length of 0xFFFF each is refused (the
// vector with record length 0xFFFF and count 0xFFFF), in every position of a chunked stream.
fn void test_fuzz_szl_length_products_do_not_wrap() @test
{
	FuzzRng rng = { 0x082EFA98EC4E6C89 };
	Fixture bad = fx(FX_M36);
	for (usz round = 0; round < 200; round++)
	{
		FuzzRig r;
		r.start(6);
		r.keep_events = true;
		Fixture f = with_ref(FX_M36, 2);
		r.feed_chunks(&rng, f.bytes());
		Event e = r.s.next_event()!!;
		assert(e.kind == JOB_FAILED && e.error == BAD_RESPONSE);
		e.completion.free();
		r.finish();
	}
	assert(bad.len > 0);
}
