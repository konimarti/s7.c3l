module s7;

import std::time;

// Tests for session.c3: the test code plays the PLC with hex fixtures. V* and M* are the IDs of the independent test
// vector set. Every test runs the session on a TrackingAllocator and checks that nothing leaks.

fn time::Clock at_ms(ulong ms) => (time::Clock)(ms * 1000000);

const String FX_SETUP_REQUEST_960 = "03 00 00 19 02 F0 80 32 01 00 00 00 01 00 08 00 00 F0 00 00 01 00 01 03 C0";
const String FX_DR_AFTER_V6 = "03 00 00 0B 06 80 00 01 00 01 80";

// The default configuration with an offer of 480 so that the setup request equals V11.
fn SessionConfig config_480()
{
	SessionConfig cfg = default_config(tsaps_from_rack_slot(PG, 0, 2)!!);
	cfg.limits.max_pdu = 480;
	return cfg;
}

struct Rig
{
	TrackingAllocator alloc;
	Session s;
}

fn void Rig.start(&self, SessionConfig cfg)
{
	self.alloc.init(mem);
	self.s.init(cfg, &self.alloc)!!;
}

// Frees the session and everything queued in it and requires that no allocation is left.
fn void Rig.finish(&self)
{
	self.s.free();
	assert(!self.alloc.has_leaks(), "the session leaked memory");
	self.alloc.free();
}

fn void Rig.feed_hex(&self, String hex, time::Clock now)
{
	Fixture f = fx(hex);
	self.s.feed(f.bytes(), now)!!;
}

fn fault Rig.feed_fault(&self, String hex, time::Clock now)
{
	Fixture f = fx(hex);
	return @catch(self.s.feed(f.bytes(), now));
}

// The pending output must equal the fixture; it is consumed.
fn void Rig.expect_output(&self, String hex)
{
	Fixture want = fx(hex);
	assert(same_bytes(self.s.pending_output(), want.bytes()), "pending output %s", hex);
	self.s.consume_output(want.len);
	assert(self.s.pending_output().len == 0);
}

fn Event Rig.event(&self)
{
	return self.s.next_event()!!;
}

fn void Rig.expect_no_event(&self)
{
	assert(@catch(self.s.next_event()) == NO_EVENT);
}

// Next event of the given kind; a completion is released.
fn Event Rig.expect(&self, EventKind kind)
{
	Event e = self.event();
	assert(e.kind == kind);
	return e;
}

// COTP and setup with the V6 confirm and a setup answer fixture; the answer is not checked.
fn void Rig.connect_with(&self, String cc, String answer)
{
	self.s.connect(at_ms(0))!!;
	self.expect_output(FX_V1);
	self.feed_hex(cc, at_ms(1));
	self.s.consume_output(self.s.pending_output().len);
	self.feed_hex(answer, at_ms(2));
}

// A connected session (pdu 480, peer reference 1).
fn void Rig.connect_480(&self)
{
	self.s.connect(at_ms(0))!!;
	self.expect_output(FX_V1);
	self.feed_hex(FX_V6, at_ms(1));
	self.expect_output(FX_V11);
	self.feed_hex(FX_V12, at_ms(2));
	Event e = self.expect(CONNECTED);
	assert(e.pdu_size == 480 && self.s.state == READY);
}

// Submits a read of one address; returns the id.
fn RequestId Rig.read(&self, String text, time::Clock now)
{
	Address[1] items = { addr(text) };
	return self.s.submit_read(items[..], now)!!;
}

// ---- handshake ----

fn void test_handshake_happy_path() @test
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(100))!!;
	assert(r.s.state == COTP_SENT);
	assert(r.s.next_deadline() == at_ms(100).add_duration(time::sec(5)));
	r.expect_output(FX_V1);                                  // V1
	r.feed_hex(FX_V6, at_ms(110));                           // V6
	assert(r.s.state == SETUP_SENT);
	r.expect_output(FX_V11);                                 // V11
	r.expect_no_event();
	r.feed_hex(FX_V12, at_ms(120));                          // V12
	Event e = r.expect(CONNECTED);
	assert(e.pdu_size == 480 && e.max_calling == 1 && e.max_called == 1);
	assert(r.s.state == READY && r.s.pdu_size == 480);
	assert(r.s.next_deadline() == (time::Clock)0);
	r.expect_no_event();
	r.finish();
}

fn void test_default_offer_is_960() @test
{
	Rig r;
	r.start(default_config(tsaps_from_rack_slot(PG, 0, 2)!!));
	r.s.connect(at_ms(0))!!;
	r.expect_output(FX_V1);
	r.feed_hex(FX_V6, at_ms(1));
	r.expect_output(FX_SETUP_REQUEST_960);
	r.feed_hex(FX_V14, at_ms(2));                            // the peer answers 960
	Event e = r.expect(CONNECTED);
	assert(e.pdu_size == 960);
	r.finish();
}

fn void test_cc_variants_are_accepted() @test
{
	// V7: no parameters, V9: an unknown parameter, V8: DST-REF 0 (lenient by default)
	String[3] ccs = { FX_V7, FX_V9, FX_V8 };
	foreach (cc : ccs)
	{
		Rig r;
		r.start(config_480());
		r.s.connect(at_ms(0))!!;
		r.s.consume_output(r.s.pending_output().len);
		r.feed_hex(cc, at_ms(1));
		assert(r.s.state == SETUP_SENT, "CC %s", cc);
		r.expect_output(FX_V11);
		r.finish();
	}
}

fn void test_v8_strict_dst_ref_is_rejected() @test
{
	SessionConfig cfg = config_480();
	cfg.lenient_dst_ref = false;
	Rig r;
	r.start(cfg);
	r.s.connect(at_ms(0))!!;
	r.s.consume_output(r.s.pending_output().len);
	assert(r.feed_fault(FX_V8, at_ms(1)) == BAD_COTP);
	assert(r.s.state == FAILED);
	Event e = r.expect(DISCONNECTED);
	assert(e.error == BAD_COTP);
	r.finish();
	// the CC that echoes our reference passes in strict mode
	Rig ok;
	ok.start(cfg);
	ok.s.connect(at_ms(0))!!;
	ok.s.consume_output(ok.s.pending_output().len);
	ok.feed_hex(FX_V6, at_ms(1));
	assert(ok.s.state == SETUP_SENT);
	ok.finish();
}

fn void test_v10_disconnect_request_refuses_the_connection() @test
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.s.consume_output(r.s.pending_output().len);
	assert(r.feed_fault(FX_V10, at_ms(1)) == CONNECT_REFUSED);
	assert(r.s.state == FAILED);
	assert(r.expect(DISCONNECTED).error == CONNECT_REFUSED);
	r.expect_no_event();
	r.finish();
}

fn void test_m34_m35_wrong_tpdu_during_connect() @test
{
	Rig a;
	a.start(config_480());
	a.s.connect(at_ms(0))!!;
	assert(a.feed_fault(FX_M34, at_ms(1)) == UNEXPECTED_PDU);        // a DT where the CC was expected
	assert(a.s.state == FAILED);
	a.finish();
	Rig b;
	b.start(config_480());
	b.s.connect(at_ms(0))!!;
	assert(b.feed_fault(FX_M35, at_ms(1)) == UNEXPECTED_PDU);        // a CR from the server
	assert(b.s.state == FAILED);
	b.finish();
}

fn void test_setup_answer_policy() @test
{
	// V13: 240 is accepted
	Rig a;
	a.start(config_480());
	a.connect_with(FX_V6, FX_V13);
	assert(a.expect(CONNECTED).pdu_size == 240);
	a.finish();
	// V14: 960 although 480 was offered is clamped to the offer, not rejected
	Rig b;
	b.start(config_480());
	b.connect_with(FX_V6, FX_V14);
	assert(b.expect(CONNECTED).pdu_size == 480);
	b.finish();
	// V16: amq 0 is treated as 1
	Rig c;
	c.start(config_480());
	c.connect_with(FX_V6, FX_V16);
	Event e = c.expect(CONNECTED);
	assert(e.max_calling == 1 && e.max_called == 1 && e.pdu_size == 480);
	c.finish();
}

fn void test_setup_answer_failures() @test
{
	// V15: PDU size 0, M31: PDU size 10 below the floor
	String[2] bad = { FX_V15, FX_M31 };
	foreach (answer : bad)
	{
		Rig r;
		r.start(config_480());
		r.s.connect(at_ms(0))!!;
		r.s.consume_output(r.s.pending_output().len);
		r.feed_hex(FX_V6, at_ms(1));
		r.s.consume_output(r.s.pending_output().len);
		assert(r.feed_fault(answer, at_ms(2)) == NEGOTIATION_FAILED);
		assert(r.s.state == FAILED);
		assert(r.expect(DISCONNECTED).error == NEGOTIATION_FAILED);
		r.finish();
	}
	// V17: header error class 0x81 code 0x04
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V6, at_ms(1));
	r.s.consume_output(r.s.pending_output().len);
	assert(r.feed_fault(FX_V17, at_ms(2)) == S7_ERROR);
	assert(r.s.err_class == 0x81 && r.s.err_code == 0x04);
	assert(r.expect(DISCONNECTED).error == S7_ERROR);
	r.finish();
}

fn void test_setup_answer_with_wrong_reference() @test
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V6, at_ms(1));
	r.s.consume_output(r.s.pending_output().len);
	assert(r.feed_fault("03 00 00 1B 02 F0 80 32 03 00 00 00 07 00 08 00 00 00 00 F0 00 00 01 00 01 01 E0", at_ms(2)) == PDU_REF_MISMATCH);
	r.finish();
}

// ---- jobs ----

fn void test_read_job() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.read("DB1.DBW2", at_ms(1000));
	assert(r.s.state == JOB_IN_FLIGHT);
	assert(r.s.next_deadline() == at_ms(1000).add_duration(time::sec(5)));
	r.expect_output(FX_V20);                                 // V20: first job reference is 2
	r.feed_hex(FX_V21, at_ms(1010));                         // V21
	Event e = r.expect(JOB_DONE);
	assert(e.id == id && e.completion.id == id);
	assert(e.completion.results.len == 1 && !e.completion.results[0].status);
	Fixture want = fx("12 34");
	assert(same_bytes(e.completion.results[0].data, want.bytes()));
	assert(e.completion.items.len == 1 && e.completion.items[0].byte_off == 2);
	assert(r.s.state == READY && r.s.next_deadline() == (time::Clock)0);
	e.completion.free();
	r.finish();
}

fn void expect_item_fault_job(String response, fault want, char raw)
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(10));
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(response, at_ms(11));
	Event e = r.expect(JOB_DONE);
	assert(e.completion.results[0].status == want && e.completion.results[0].raw_code == raw);
	assert(e.completion.results[0].data.len == 0);
	e.completion.free();
	assert(r.s.state == READY);
	// the session is still usable: the next job gets the next reference
	r.read("DB1.DBW2", at_ms(12));
	assert(r.s.pending_output()[12] == 3);
	r.finish();
}

fn void test_per_item_faults_leave_the_session_ready() @test
{
	expect_item_fault_job(FX_V32, ACCESS_DENIED, 0x03);
	expect_item_fault_job(FX_V33, ADDRESS_OUT_OF_RANGE, 0x05);
	expect_item_fault_job(FX_V34, DATA_TYPE_UNSUPPORTED, 0x06);
	expect_item_fault_job(FX_V35, TYPE_MISMATCH, 0x07);
	expect_item_fault_job(FX_V36, OBJECT_DOES_NOT_EXIST, 0x0A);
	expect_item_fault_job(FX_V37, HARDWARE_FAULT, 0x01);
}

fn char[] read_response_frame(ushort ref, char[] data, char[] out)
{
	usz len = data.len;
	usz total = 7 + 12 + 2 + 4 + len;
	out[0] = 3;
	out[1] = 0;
	out[2] = (char)(total >> 8);
	out[3] = (char)total;
	out[4] = 2;
	out[5] = 0xF0;
	out[6] = 0x80;
	out[7] = 0x32;
	out[8] = 0x03;
	out[9] = 0;
	out[10] = 0;
	out[11] = (char)(ref >> 8);
	out[12] = (char)ref;
	out[13] = 0;
	out[14] = 2;
	out[15] = (char)((len + 4) >> 8);
	out[16] = (char)(len + 4);
	out[17] = 0;
	out[18] = 0;
	out[19] = 0x04;
	out[20] = 0x01;
	out[21] = 0xFF;
	out[22] = 0x04;
	out[23] = (char)((len * 8) >> 8);
	out[24] = (char)(len * 8);
	out[25:len] = data[..];
	return out[:total];
}

// ref of the request frame in the pending output
fn ushort pending_ref(Session* s) => (ushort)((s.pending_output()[11] << 8) | s.pending_output()[12]);

fn void test_split_read_sends_one_pdu_at_a_time() @test
{
	Rig r;
	r.start(config_480());
	r.connect_with(FX_V6, FX_V13);                           // pdu 240
	assert(r.expect(CONNECTED).pdu_size == 240);
	Address[1] items = { addr("DB1.DBB0:1000") };
	RequestId id = r.s.submit_read(items[..], at_ms(0))!!;
	usz[5] lengths = { 222, 222, 222, 222, 112 };
	usz offset = 0;
	for (usz k = 0; k < 5; k++)
	{
		// exactly one request is outstanding
		char[] out = r.s.pending_output();
		assert(out.len == 31, "request %d", (int)k);
		Address item = decode_item(out[19:12])!!;
		assert(item.byte_off == offset && item.count == lengths[k], "chunk %d", (int)k);
		ushort ref = pending_ref(&r.s);
		assert(ref == 2 + k);
		r.s.consume_output(out.len);
		r.expect_no_event();
		char[222] data;
		for (usz i = 0; i < lengths[k]; i++) data[i] = (char)((offset + i) % 251);
		char[300] frame;
		char[] reply = read_response_frame(ref, data[:lengths[k]], frame[..]);
		r.s.feed(reply, at_ms(k + 1))!!;
		offset += lengths[k];
	}
	Event e = r.expect(JOB_DONE);
	assert(e.completion.id == id && e.completion.results[0].data.len == 1000);
	foreach (i, b : e.completion.results[0].data) assert(b == (char)(i % 251));
	e.completion.free();
	assert(r.s.state == READY);
	r.finish();
}

fn void test_failed_chunk_stops_the_remaining_chunks_of_that_item() @test
{
	Rig r;
	r.start(config_480());
	r.connect_with(FX_V6, FX_V13);
	r.expect(CONNECTED);
	Address[1] items = { addr("DB1.DBB0:1000") };
	r.s.submit_read(items[..], at_ms(0))!!;
	r.s.consume_output(r.s.pending_output().len);
	// the first chunk fails with 0x05: nothing else is requested for that item
	r.feed_hex("03 00 00 19 02 F0 80 32 03 00 00 00 02 00 02 00 04 00 00 04 01 05 00 00 00", at_ms(1));
	assert(r.s.pending_output().len == 0);
	Event e = r.expect(JOB_DONE);
	assert(e.completion.results[0].status == ADDRESS_OUT_OF_RANGE && e.completion.results[0].data.len == 0);
	e.completion.free();
	r.finish();
}

fn void test_write_job_and_the_write_guard() @test
{
	// the default configuration refuses writes before any byte is produced
	Rig r;
	r.start(config_480());
	r.connect_480();
	Address[1] items = { addr("DB1.DBW2") };
	char[2] value = { 0x12, 0x34 };
	char[][1] data = { value[..] };
	assert(@catch(r.s.submit_write(items[..], data[..], at_ms(5))) == WRITE_NOT_ALLOWED);
	assert(r.s.pending_output().len == 0 && r.s.state == READY);
	r.finish();

	SessionConfig cfg = config_480();
	cfg.allow_write = true;
	Rig w;
	w.start(cfg);
	w.connect_480();
	w.read("DB1.DBW2", at_ms(1));                            // takes reference 2
	w.s.consume_output(w.s.pending_output().len);
	w.feed_hex(FX_V21, at_ms(2));
	w.expect(JOB_DONE).completion.free();
	RequestId id = w.s.submit_write(items[..], data[..], at_ms(3))!!;
	w.expect_output(FX_V40);                                 // V40, reference 3
	w.feed_hex(FX_V41, at_ms(4));                            // V41
	Event e = w.expect(JOB_DONE);
	assert(e.id == id && !e.completion.results[0].status);
	e.completion.free();
	// wrong payload length
	char[1] short_value = { 1 };
	char[][1] short_data = { short_value[..] };
	assert(@catch(w.s.submit_write(items[..], short_data[..], at_ms(5))) == INVALID_ARGUMENT);
	assert(@catch(w.s.submit_write(items[..], data[:0], at_ms(5))) == INVALID_ARGUMENT);
	w.finish();
}

fn void test_write_response_with_a_failed_item() @test
{
	SessionConfig cfg = config_480();
	cfg.allow_write = true;
	Rig w;
	w.start(cfg);
	w.connect_480();
	Address[1] items = { addr("DB1.DBW2") };
	char[2] value = { 1, 2 };
	char[][1] data = { value[..] };
	w.s.submit_write(items[..], data[..], at_ms(3))!!;
	w.s.consume_output(w.s.pending_output().len);
	w.feed_hex("03 00 00 16 02 F0 80 32 03 00 00 00 02 00 02 00 01 00 00 05 01 03", at_ms(4));
	Event e = w.expect(JOB_DONE);
	assert(e.completion.results[0].status == ACCESS_DENIED);
	e.completion.free();
	assert(w.s.state == READY);
	w.finish();
}

fn void test_busy_and_not_connected() @test
{
	Rig r;
	r.start(config_480());
	Address[1] items = { addr("DB1.DBW2") };
	assert(@catch(r.s.submit_read(items[..], at_ms(0))) == NOT_CONNECTED);       // idle
	r.s.connect(at_ms(0))!!;
	assert(@catch(r.s.submit_read(items[..], at_ms(0))) == NOT_CONNECTED);       // connecting
	assert(@catch(r.s.connect(at_ms(0))) == BUSY);
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V6, at_ms(1));
	r.s.consume_output(r.s.pending_output().len);
	assert(@catch(r.s.submit_read(items[..], at_ms(0))) == NOT_CONNECTED);       // setup not answered
	r.feed_hex(FX_V12, at_ms(2));
	r.expect(CONNECTED);
	r.s.submit_read(items[..], at_ms(3))!!;
	assert(@catch(r.s.submit_read(items[..], at_ms(3))) == BUSY);                // one job at a time
	r.finish();
}

fn void test_submit_argument_errors_keep_the_session_ready() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	Address[1] items = { addr("DB1.DBW2") };
	assert(@catch(r.s.submit_read(items[:0], at_ms(0))) == INVALID_ARGUMENT);
	Address zero = { .area = DB, .db = 1, .tsize = BYTE, .count = 0 };
	Address[1] bad = { zero };
	assert(@catch(r.s.submit_read(bad[..], at_ms(0))) == INVALID_ARGUMENT);
	assert(r.s.state == READY && r.s.pending_output().len == 0);
	r.s.submit_read(items[..], at_ms(0))!!;
	r.finish();
}

// ---- reference numbers ----

fn void test_reference_wraps_and_skips_zero() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.s.next_ref = 0xFFFF;
	r.read("DB1.DBW2", at_ms(0));
	assert(pending_ref(&r.s) == 0xFFFF);
	r.s.consume_output(r.s.pending_output().len);
	char[2] data = { 0, 0 };
	char[300] frame;
	r.s.feed(read_response_frame(0xFFFF, data[..], frame[..]), at_ms(1))!!;
	r.expect(JOB_DONE).completion.free();
	r.read("DB1.DBW2", at_ms(2));
	assert(pending_ref(&r.s) == 1, "the reference after 0xFFFF is 1, never 0");
	r.finish();
}

// ---- chunking independence ----

// handshake and one read job, fed in pieces of `chunk` bytes (0 = whole frames)
fn void scenario(usz chunk)
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.expect_output(FX_V1);
	r.feed_in_pieces(FX_V6, chunk);
	r.expect_output(FX_V11);
	r.feed_in_pieces(FX_V12, chunk);
	r.expect_no_event_after_connected();
	r.read("DB1.DBW2", at_ms(5));
	r.expect_output(FX_V20);
	r.feed_in_pieces(FX_V21, chunk);
	Event e = r.expect(JOB_DONE);
	Fixture want = fx("12 34");
	assert(same_bytes(e.completion.results[0].data, want.bytes()));
	e.completion.free();
	r.expect_no_event();
	r.finish();
}

fn void Rig.feed_in_pieces(&self, String hex, usz chunk)
{
	Fixture f = fx(hex);
	if (chunk == 0)
	{
		self.s.feed(f.bytes(), at_ms(1))!!;
		return;
	}
	for (usz i = 0; i < f.len; i += chunk)
	{
		usz n = f.len - i < chunk ? f.len - i : chunk;
		self.s.feed(f.bytes()[i:n], at_ms(1))!!;
	}
}

fn void Rig.expect_no_event_after_connected(&self)
{
	Event e = self.expect(CONNECTED);
	assert(e.pdu_size == 480);
	self.expect_no_event();
}

fn void test_chunking_does_not_change_the_result() @test
{
	scenario(0);
	scenario(1);
	scenario(2);
	scenario(3);
	scenario(7);
}

fn void test_two_frames_in_one_feed() @test
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.s.consume_output(r.s.pending_output().len);
	// the confirm and the setup answer arrive together
	@pool()
	{
		String both = string::tformat("%s %s", FX_V6, FX_V12);
		r.feed_hex(both, at_ms(1));
	};
	assert(r.expect(CONNECTED).pdu_size == 480);
	r.finish();
}

fn void test_m5_m7_incomplete_input_is_not_an_error() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.feed_hex(FX_M7, at_ms(5));                              // M7: 3 bytes of a header
	assert(r.s.state == READY && r.s.in_len == 3);
	r.expect_no_event();
	r.finish();
	Rig q;
	q.start(config_480());
	q.connect_480();
	q.feed_hex(FX_M5, at_ms(5));                              // M5: the frame says 0x29 bytes and has fewer
	assert(q.s.state == READY && q.s.in_len == 31);
	q.expect_no_event();
	q.finish();
}

fn void test_m8_every_prefix_of_a_response_waits_for_more() @test
{
	Fixture reply = fx(FX_V21);
	for (usz k = 0; k < reply.len; k++)
	{
		Rig r;
		r.start(config_480());
		r.connect_480();
		r.read("DB1.DBW2", at_ms(5));
		r.s.consume_output(r.s.pending_output().len);
		r.s.feed(reply.bytes()[:k], at_ms(6))!!;
		r.expect_no_event();
		assert(r.s.state == JOB_IN_FLIGHT, "prefix of %d bytes", (int)k);
		r.s.feed(reply.bytes()[k..], at_ms(7))!!;
		r.expect(JOB_DONE).completion.free();
		r.finish();
	}
}

// ---- framing policy ----

fn void test_m6_oversized_frames_are_refused_before_buffering() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	assert(r.feed_fault(FX_M6, at_ms(5)) == FRAME_TOO_LARGE);   // M6: length 0xFFFF
	assert(r.s.state == FAILED && r.s.in_len == 0);
	assert(r.expect(DISCONNECTED).error == FRAME_TOO_LARGE);
	r.finish();
	// 8193 bytes is one too many for the default limit and is refused on the 4 header bytes alone
	Rig q;
	q.start(config_480());
	q.connect_480();
	assert(q.feed_fault("03 00 20 01", at_ms(5)) == FRAME_TOO_LARGE);
	q.finish();
}

fn void test_m2_reserved_byte_is_strict_by_default() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(5));
	r.s.consume_output(r.s.pending_output().len);
	assert(r.feed_fault("03 01 00 1B 02 F0 80 32 03 00 00 00 02 00 02 00 06 00 00 04 01 FF 04 00 10 12 34", at_ms(6)) == BAD_TPKT);
	assert(r.s.state == FAILED);
	assert(r.expect(JOB_FAILED).error == BAD_TPKT);
	assert(r.expect(DISCONNECTED).error == BAD_TPKT);
	r.finish();

	SessionConfig cfg = config_480();
	cfg.lenient_reserved = true;
	Rig l;
	l.start(cfg);
	l.connect_480();
	l.read("DB1.DBW2", at_ms(5));
	l.s.consume_output(l.s.pending_output().len);
	l.feed_hex("03 01 00 1B 02 F0 80 32 03 00 00 00 02 00 02 00 06 00 00 04 01 FF 04 00 10 12 34", at_ms(6));
	l.expect(JOB_DONE).completion.free();
	l.finish();
	// M2 itself is a request frame: with the lenient flag it gets past the TPKT header and is refused as unexpected
	Rig m;
	m.start(cfg);
	m.connect_480();
	assert(m.feed_fault("03 01 00 1F 02 F0 80 32 01 00 00 00 02 00 0E 00 00 04 01 12 0A 10 02 00 02 00 01 84 00 00 10", at_ms(5)) == UNEXPECTED_PDU);
	m.finish();
}

fn void test_m24_pdu_reference_mismatch() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(5));
	r.s.consume_output(r.s.pending_output().len);
	assert(r.feed_fault(FX_M24, at_ms(6)) == PDU_REF_MISMATCH);
	assert(r.s.state == FAILED);
	assert(r.expect(JOB_FAILED).error == PDU_REF_MISMATCH);
	assert(r.expect(DISCONNECTED).error == PDU_REF_MISMATCH);
	r.finish();

	SessionConfig cfg = config_480();
	cfg.lenient_pdu_ref = true;
	Rig l;
	l.start(cfg);
	l.connect_480();
	l.read("DB1.DBW2", at_ms(5));
	l.s.consume_output(l.s.pending_output().len);
	l.feed_hex(FX_M24, at_ms(6));
	Event e = l.expect(JOB_DONE);
	Fixture want = fx("12 34");
	assert(same_bytes(e.completion.results[0].data, want.bytes()));
	e.completion.free();
	l.finish();
}

fn void test_unsolicited_frames_fail_the_session() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	assert(r.feed_fault(FX_V21, at_ms(5)) == UNEXPECTED_PDU);     // an answer nobody asked for
	assert(r.s.state == FAILED);
	r.finish();
	Rig g;
	g.start(config_480());
	g.connect_480();
	assert(g.feed_fault("03 00 00 07 02 F0 00", at_ms(5)) == UNEXPECTED_PDU);   // DT without EOT
	g.finish();
}

// ---- job level failures ----

fn void test_v59_header_error_fails_the_job_only() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.read("DB1.DBW2", at_ms(5));
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V59, at_ms(6));
	Event e = r.expect(JOB_FAILED);
	assert(e.id == id && e.error == S7_ERROR);
	assert(r.s.err_class == 0x85 && r.s.err_code == 0x00);
	assert(r.s.state == READY && r.s.next_deadline() == (time::Clock)0);
	r.expect_no_event();
	r.read("DB1.DBW2", at_ms(7));                                 // still usable
	r.finish();
}

fn void test_job_answers_that_do_not_fit_the_request() @test
{
	// an Ack without data and without an error class
	Rig a;
	a.start(config_480());
	a.connect_480();
	a.read("DB1.DBW2", at_ms(5));
	a.s.consume_output(a.s.pending_output().len);
	a.feed_hex("03 00 00 13 02 F0 80 32 02 00 00 00 02 00 00 00 00 00 00", at_ms(6));
	assert(a.expect(JOB_FAILED).error == BAD_RESPONSE);
	assert(a.s.state == READY);
	a.finish();
	// M23: a Write Var answer to a read
	Fixture m23 = fx("03 00 00 1B 02 F0 80 32 03 00 00 00 02 00 02 00 06 00 00 05 01 FF 04 00 10 12 34");
	Rig b;
	b.start(config_480());
	b.connect_480();
	b.read("DB1.DBW2", at_ms(5));
	b.s.consume_output(b.s.pending_output().len);
	b.s.feed(m23.bytes(), at_ms(6))!!;
	assert(b.expect(JOB_FAILED).error == BAD_RESPONSE);
	assert(b.s.state == READY);
	b.finish();
}

// ---- end of stream, close, timeouts ----

fn void test_on_closed_during_connect() @test
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.s.on_closed(CLOSED, at_ms(1));
	assert(r.s.state == CLOSED);
	Event e = r.expect(DISCONNECTED);
	assert(e.error == CLOSED);
	r.expect_no_event();
	r.finish();
}

fn void test_on_closed_with_a_job_in_flight() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.read("DB1.DBW2", at_ms(5));
	r.s.on_closed(CLOSED, at_ms(6));
	Event failed = r.expect(JOB_FAILED);
	assert(failed.id == id && failed.error == CLOSED);
	assert(r.expect(DISCONNECTED).error == CLOSED);
	assert(r.s.state == CLOSED);
	// idempotent: no second pair of events
	r.s.on_closed(CLOSED, at_ms(7));
	r.expect_no_event();
	// nothing works afterwards
	Address[1] items = { addr("DB1.DBW2") };
	assert(@catch(r.s.submit_read(items[..], at_ms(8))) == NOT_CONNECTED);
	Fixture f = fx(FX_V21);
	assert(@catch(r.s.feed(f.bytes(), at_ms(8))) == NOT_CONNECTED);
	r.finish();
}

fn void test_on_closed_when_idle_and_ready() @test
{
	Rig r;
	r.start(config_480());
	r.s.on_closed(CLOSED, at_ms(0));
	assert(r.s.state == IDLE);
	r.expect_no_event();
	r.finish();
	Rig q;
	q.start(config_480());
	q.connect_480();
	q.s.on_closed(TIMEOUT, at_ms(1));
	assert(q.expect(DISCONNECTED).error == TIMEOUT && q.s.state == CLOSED);
	q.finish();
}

fn void test_peer_disconnect_request_closes_the_session() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(5));
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V10, at_ms(6));
	assert(r.expect(JOB_FAILED).error == CLOSED);
	assert(r.expect(DISCONNECTED).error == CLOSED);
	assert(r.s.state == CLOSED);
	r.finish();
}

fn void test_close_sends_a_disconnect_request() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.s.close(at_ms(5));
	r.expect_output(FX_DR_AFTER_V6);
	assert(r.s.state == CLOSED);
	r.expect_no_event();
	r.s.close(at_ms(6));                                           // idempotent
	assert(r.s.pending_output().len == 0);
	r.finish();
	// with a job in flight: the unsent request is dropped and the job fails
	Rig j;
	j.start(config_480());
	j.connect_480();
	RequestId id = j.read("DB1.DBW2", at_ms(5));
	j.s.close(at_ms(6));
	j.expect_output(FX_DR_AFTER_V6);
	Event e = j.expect(JOB_FAILED);
	assert(e.id == id && e.error == CLOSED);
	j.finish();
}

fn void test_timeouts() @test
{
	// during connect
	Rig a;
	a.start(config_480());
	a.s.connect(at_ms(0))!!;
	a.s.on_timeout(at_ms(5000));
	assert(a.s.state == FAILED && a.expect(DISCONNECTED).error == TIMEOUT);
	a.finish();
	// with a job in flight
	Rig b;
	b.start(config_480());
	b.connect_480();
	RequestId id = b.read("DB1.DBW2", at_ms(100));
	assert(b.s.next_deadline() == at_ms(100).add_duration(time::sec(5)));
	b.s.on_timeout(at_ms(5100));
	Event failed = b.expect(JOB_FAILED);
	assert(failed.id == id && failed.error == TIMEOUT);
	assert(b.expect(DISCONNECTED).error == TIMEOUT);
	assert(b.s.state == FAILED && b.s.next_deadline() == (time::Clock)0);
	b.finish();
	// nothing pending: ignored
	Rig c;
	c.start(config_480());
	c.connect_480();
	c.s.on_timeout(at_ms(99999));
	assert(c.s.state == READY);
	c.expect_no_event();
	c.finish();
}

fn void test_response_timeout_is_configurable() @test
{
	SessionConfig cfg = config_480();
	cfg.response_timeout = time::ms(250);
	Rig r;
	r.start(cfg);
	r.connect_480();
	r.read("DB1.DBW2", at_ms(1000));
	assert(r.s.next_deadline() == at_ms(1250));
	r.finish();
}

// ---- init ----

fn void test_init_rejects_impossible_limits() @test
{
	TrackingAllocator t;
	t.init(mem);
	Session s;
	SessionConfig cfg = config_480();
	cfg.limits.max_pdu = 8190;                      // 8190 + 7 > 8192
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg = config_480();
	cfg.limits.min_pdu = 500;                       // above max_pdu
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg = config_480();
	cfg.limits.max_items = 0;
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg = config_480();
	cfg.limits.max_pdu = 20;
	cfg.limits.min_pdu = 10;
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	assert(t.allocation_count() == 0, "a rejected configuration allocates nothing");
	cfg = config_480();
	cfg.limits.max_pdu = 8185;                      // exactly fits
	assert(@ok(s.init(cfg, &t)));
	s.free();
	assert(!t.has_leaks());
	t.free();
}

fn void test_free_releases_queued_completions() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(5));
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V21, at_ms(6));
	// the completion is never taken from the queue: free must release it
	r.finish();
}

fn void test_a_job_in_flight_is_released_by_free() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	Address[1] items = { addr("DB1.DBB0:1000") };
	r.s.submit_read(items[..], at_ms(5))!!;
	r.finish();
}

// Negative control for the leak checks above: a completion that is taken from the queue and not released shows up.
fn void test_leak_check_detects_a_forgotten_completion() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(5));
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V21, at_ms(6));
	Event e = r.expect(JOB_DONE);
	r.s.free();
	assert(r.alloc.has_leaks(), "the checks must notice a completion that was never released");
	e.completion.free();
	assert(!r.alloc.has_leaks());
	r.alloc.free();
}

fn void test_a_job_is_refused_while_a_completion_is_still_queued() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.read("DB1.DBW2", at_ms(10));
	r.s.consume_output(r.s.pending_output().len);
	r.feed_hex(FX_V21, at_ms(11));                       // the job is done, its completion is not taken
	Address[1] items = { addr("DB1.DBW2") };
	assert(@catch(r.s.submit_read(items[..], at_ms(12))) == BUSY);
	assert(r.s.state == READY && r.s.pending_output().len == 0);
	r.expect(JOB_DONE).completion.free();
	// nine jobs in a row, every completion taken: none is lost
	for (usz i = 0; i < 9; i++)
	{
		r.read("DB1.DBW2", at_ms(20 + i));
		r.s.consume_output(r.s.pending_output().len);
		Fixture reply = with_ref(FX_V21, (ushort)(3 + i));
		r.s.feed(reply.bytes(), at_ms(30 + i))!!;
		r.expect(JOB_DONE).completion.free();
	}
	r.finish();
}

fn void test_min_pdu_below_what_the_planner_can_use_is_rejected_at_init() @test
{
	TrackingAllocator t;
	t.init(mem);
	Session s;
	SessionConfig cfg = config_480();
	cfg.limits.min_pdu = 10;                        // a peer answer of 10 would connect and then fail every job
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg.limits.min_pdu = 29;
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg.limits.min_pdu = 30;
	assert(@ok(s.init(cfg, &t)));
	s.free();
	assert(!t.has_leaks());
	t.free();
}

fn void test_an_early_timeout_report_does_not_kill_a_healthy_session() @test
{
	Rig r;
	r.start(config_480());
	r.s.connect(at_ms(0))!!;
	r.s.on_timeout(at_ms(1));                           // the deadline is at 5000 ms
	assert(r.s.state == COTP_SENT);
	r.expect_no_event();
	r.s.on_timeout(at_ms(4999));
	assert(r.s.state == COTP_SENT);
	r.s.on_timeout(at_ms(5000));
	assert(r.s.state == FAILED && r.expect(DISCONNECTED).error == TIMEOUT);
	r.finish();

	Rig j;
	j.start(config_480());
	j.connect_480();
	j.read("DB1.DBW2", at_ms(100));                     // deadline 5100 ms
	j.s.on_timeout(at_ms(5099));
	assert(j.s.state == JOB_IN_FLIGHT);
	j.expect_no_event();
	j.s.on_timeout(at_ms(5100));
	assert(j.expect(JOB_FAILED).error == TIMEOUT && j.s.state == FAILED);
	j.finish();
}

fn void test_init_rejects_timeouts_that_are_not_positive() @test
{
	TrackingAllocator t;
	t.init(mem);
	Session s;
	SessionConfig cfg = config_480();
	cfg.response_timeout = time::ms(0);
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg.response_timeout = (time::Duration)-5;
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg = config_480();
	cfg.connect_timeout = time::ms(0);
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	cfg.connect_timeout = (time::Duration)-1;
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	assert(t.allocation_count() == 0);
	cfg = config_480();
	cfg.response_timeout = time::ms(1);
	assert(@ok(s.init(cfg, &t)));
	s.free();
	t.free();
}

fn void test_a_rejected_init_leaves_a_session_that_is_safe_to_free() @test
{
	TrackingAllocator t;
	t.init(mem);
	Session s;
	// garbage in the struct, as in an uninitialised variable
	s.state = READY;
	s.in_len = 99;
	s.out_len = 7;
	s.ev_len = 3;
	s.job.active = true;
	SessionConfig cfg = config_480();
	cfg.limits.max_items = 0;
	assert(@catch(s.init(cfg, &t)) == INVALID_ARGUMENT);
	assert(s.state == IDLE && s.in_len == 0 && s.out_len == 0 && s.ev_len == 0 && !s.job.active);
	assert(s.inbuf.len == 0 && s.outbuf.len == 0);
	s.free();                                           // must not touch memory it does not own
	assert(t.allocation_count() == 0);
	t.free();
}
