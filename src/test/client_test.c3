module s7;

import std::time;

// Tests for the blocking client (client.c3) over a scripted MemTransport. No test opens a socket. V* are the IDs of
// the independent test vector set; their frames are reused from the other test files.

// A clock the tests control: it stands still, and after `g_fake_jump_after` calls it jumps ten seconds ahead.
time::Clock g_fake_now;
usz g_fake_calls;
usz g_fake_jump_after;

fn time::Clock fake_clock()
{
	g_fake_calls++;
	if (g_fake_calls > g_fake_jump_after) return g_fake_now.add_duration(time::sec(10));
	return g_fake_now;
}

fn void fake_reset(usz jump_after)
{
	g_fake_now = at_ms(1000);
	g_fake_calls = 0;
	g_fake_jump_after = jump_after;
}

struct ClientRig
{
	TrackingAllocator alloc;
	MemTransport mt;
	Client c;
}

// Script the handshake: V6 after the Connection Request, `answer` after the Setup Communication.
fn void ClientRig.handshake(&self, String answer)
{
	self.mt.reply(FX_V6, 1);
	self.mt.reply(answer, 2);
}

fn void? ClientRig.open_with(&self, SessionConfig cfg)
{
	self.alloc.init(mem);
	return self.c.open(&self.mt, cfg, &self.alloc, &fake_clock);
}

fn void ClientRig.open_480(&self)
{
	self.open_with(config_480())!!;
}

fn void ClientRig.finish(&self)
{
	self.c.close();
	assert(!self.alloc.has_leaks(), "the client leaked memory");
	self.alloc.free();
}

// ---- open ----

fn void test_open_with_whole_replies() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.open_480();
	assert(r.c.pdu_size() == 480);
	assert(r.mt.write_calls == 2);
	Fixture cr = fx(FX_V1);                                          // V1
	assert(same_bytes(r.mt.write_at(0), cr.bytes()));
	Fixture setup = fx(FX_V11);                                      // V11
	assert(same_bytes(r.mt.write_at(1), setup.bytes()));
	r.finish();
}

fn void test_open_with_one_byte_reads() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.mt.chunk = 1;
	r.handshake(FX_V12);
	r.open_480();
	assert(r.c.pdu_size() == 480);
	assert(r.mt.read_calls >= FX_V6.len / 3);                        // many small reads, same result
	r.finish();
}

// ---- reading ----

fn void test_read_a_word() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.mt.reply(FX_V21, 3);
	r.open_480();
	Address[1] items = { addr("DB1.DBW2") };
	Completion c = r.c.read(items[..])!!;
	Fixture want = fx("12 34");
	assert(!c.results[0].status && same_bytes(c.results[0].data, want.bytes()));
	c.free();
	Fixture request = fx(FX_V20);                                    // V20
	assert(same_bytes(r.mt.write_at(2), request.bytes()));
	r.finish();
}

fn void test_read_helpers() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	Fixture second = with_ref(FX_V21, 3);
	r.mt.reply(FX_V21, 3);
	r.mt.reply_bytes(second.bytes(), 4);
	r.open_480();
	char[] bytes = r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)!!;
	Fixture want = fx("12 34");
	assert(same_bytes(bytes, want.bytes()));
	alloc::free(&r.alloc, bytes.ptr);
	Value v = r.c.read_value(addr("DB1.DBW2"), INT, &r.alloc)!!;
	assert(v.i == 0x1234);
	r.finish();
}

fn void test_read_helper_returns_the_item_fault() @test
{
	fake_reset(usz::max);
	SessionConfig cfg = config_480();
	cfg.lenient_pdu_ref = true;
	ClientRig r;
	r.handshake(FX_V12);
	r.mt.reply(FX_V32, 3);                                           // V32: access denied, reference 2
	r.mt.reply(FX_V36, 4);                                           // V36: object does not exist
	r.open_with(cfg)!!;
	assert(@catch(r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)) == ACCESS_DENIED);
	assert(@catch(r.c.read_value(addr("DB1.DBW2"), INT, &r.alloc)) == OBJECT_DOES_NOT_EXIST);
	r.finish();
}

fn void test_multi_pdu_read() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V13);                                             // pdu 240
	usz[5] lengths = { 222, 222, 222, 222, 112 };
	usz offset = 0;
	for (usz k = 0; k < 5; k++)
	{
		char[222] data;
		for (usz i = 0; i < lengths[k]; i++) data[i] = (char)((offset + i) % 251);
		char[300] frame;
		r.mt.reply_bytes(read_response_frame((ushort)(2 + k), data[:lengths[k]], frame[..]), 3 + k);
		offset += lengths[k];
	}
	r.open_with(config_480())!!;
	assert(r.c.pdu_size() == 240);
	Address[1] items = { addr("DB1.DBB0:1000") };
	Completion c = r.c.read(items[..])!!;
	assert(c.results[0].data.len == 1000);
	foreach (i, b : c.results[0].data) assert(b == (char)(i % 251));
	c.free();
	assert(r.mt.write_calls == 2 + 5);
	r.finish();
}

// ---- writing ----

fn void test_write_is_refused_without_allow_write() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.open_480();
	char[2] value = { 0x12, 0x34 };
	assert(@catch(r.c.write_bytes(addr("DB1.DBW2"), value[..])) == WRITE_NOT_ALLOWED);
	assert(r.mt.write_calls == 2, "nothing but the handshake reached the transport");
	r.finish();
}

fn void test_write_with_allow_write() @test
{
	fake_reset(usz::max);
	SessionConfig cfg = config_480();
	cfg.allow_write = true;
	ClientRig r;
	r.handshake(FX_V12);
	r.mt.reply(FX_V21, 3);
	r.mt.reply(FX_V41, 4);                                           // V41
	r.open_with(cfg)!!;
	r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)!!.free_with(&r.alloc);
	char[2] value = { 0x12, 0x34 };
	r.c.write_bytes(addr("DB1.DBW2"), value[..])!!;
	Fixture request = fx(FX_V40);                                    // V40: the second job has reference 3
	assert(same_bytes(r.mt.write_at(3), request.bytes()));
	r.finish();
}

fn void char[].free_with(self, Allocator allocator)
{
	alloc::free(allocator, self.ptr);
}

// ---- clock and system status ----

fn void test_clock_and_cpu_status() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	Fixture clock = with_ref(FX_V58, 2);
	Fixture state = with_ref(FX_V56, 3);
	Fixture info = with_ref(FX_V53, 4);
	r.mt.reply_bytes(clock.bytes(), 3);
	r.mt.reply_bytes(state.bytes(), 4);
	r.mt.reply_bytes(info.bytes(), 5);
	r.open_480();
	Dtl d = r.c.read_clock()!!;
	assert(d.year == 2025 && d.month == 11 && d.day == 12 && d.hour == 14);
	assert(r.c.cpu_state()!! == RUN);
	CpuInfo ci = r.c.cpu_info(&r.alloc)!!;
	ci.free(&r.alloc);
	r.finish();
}

fn void test_read_szl_returns_the_records() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	Fixture frag1 = with_ref(FX_V53_FRAG1, 2);
	Fixture frag2 = with_ref(FX_V53_FRAG2, 3);
	r.mt.reply_bytes(frag1.bytes(), 3);
	r.mt.reply_bytes(frag2.bytes(), 4);                              // after the continuation request
	r.open_480();
	Completion c = r.c.read_szl(0x001C, 0)!!;
	assert(c.payload.len == 68 && c.rec_count == 2);
	c.free();
	r.finish();
}

// ---- timeouts, deadlines and the shape of the transport calls ----

fn void test_expired_deadline_never_reaches_the_transport_read() @test
{
	// the clock jumps past the 5 s deadline after the connect request went out
	fake_reset(2);
	ClientRig r;
	r.handshake(FX_V12);
	assert(@catch(r.open_with(config_480())) == TIMEOUT);
	assert(r.mt.read_calls == 0, "a read must not be started once the deadline has passed");
	r.alloc.free();
}

fn void test_the_transport_only_gets_positive_timeouts() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.mt.reply(FX_V21, 3);
	r.open_480();
	r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)!!.free_with(&r.alloc);
	assert(r.mt.read_calls >= 3 && r.mt.write_calls == 3);
	for (usz i = 0; i < r.mt.read_calls; i++)
	{
		assert((long)r.mt.read_timeouts[i] > 0 && (long)r.mt.read_timeouts[i] <= (long)time::sec(5), "read %d", (int)i);
	}
	for (usz i = 0; i < r.mt.write_calls; i++)
	{
		assert((long)r.mt.write_timeouts[i] > 0 && (long)r.mt.write_timeouts[i] <= (long)time::sec(5), "write %d", (int)i);
	}
	r.finish();
}

fn void test_every_frame_is_one_write_call() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.mt.reply(FX_V21, 3);
	r.open_480();
	r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)!!.free_with(&r.alloc);
	r.c.close();
	assert(r.mt.write_calls == 4);                                   // CR, setup, read request, disconnect request
	for (usz k = 0; k < r.mt.write_calls; k++)
	{
		char[] w = r.mt.write_at(k);
		usz declared = ((usz)w[2] << 8) | w[3];
		assert(declared == w.len, "write %d is exactly one frame", (int)k);
	}
	r.finish();
}

fn void test_silent_plc_times_out() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);                                             // no reply to the read request
	r.open_480();
	assert(@catch(r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)) == TIMEOUT);
	assert(@catch(r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)) == NOT_CONNECTED);   // the session is down
	r.finish();
}

// ---- end of stream and failures ----

fn void test_end_of_stream_during_open() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.mt.eof_when_exhausted = true;
	r.mt.reply(FX_V6, 1);                                            // the setup answer never comes
	assert(@catch(r.open_with(config_480())) == CLOSED);
	r.alloc.free();
}

fn void test_end_of_stream_in_the_middle_of_a_job() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.mt.eof_when_exhausted = true;
	r.handshake(FX_V12);
	r.open_480();
	assert(@catch(r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)) == CLOSED);
	assert(@catch(r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)) == NOT_CONNECTED);   // unusable afterwards
	r.finish();
}

fn void test_write_failure_ends_the_connection() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.open_480();
	r.mt.fail_writes = true;
	assert(@catch(r.c.read_bytes(addr("DB1.DBW2"), &r.alloc)) == CLOSED);
	r.finish();
}

fn void test_a_failed_open_leaves_the_transport_to_the_caller() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.mt.reply(FX_V10, 1);                                           // V10: the PLC refuses the connection
	assert(@catch(r.open_with(config_480())) == CONNECT_REFUSED);
	assert(r.mt.close_calls == 0);
	r.alloc.free();
}

// ---- close ----

fn void test_close_sends_a_disconnect_request_and_closes_once() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	r.open_480();
	r.c.close();
	assert(r.mt.write_calls == 3);
	Fixture dr = fx(FX_DR_AFTER_V6);                                 // a V10-style disconnect request
	assert(same_bytes(r.mt.write_at(2), dr.bytes()));
	assert(r.mt.close_calls == 1);
	r.c.close();
	assert(r.mt.close_calls == 1 && r.mt.write_calls == 3);
	r.alloc.free();
}

// ---- another transport type through an explicit cast ----

// Same method shape as Transport, but the type does not declare the interface (as a type from another library).
struct OtherTransport
{
	MemTransport inner;
	usz calls;
}

fn usz? OtherTransport.read(&self, char[] buf, time::Duration timeout) @dynamic
{
	self.calls++;
	return self.inner.read(buf, timeout);
}

fn void? OtherTransport.write(&self, char[] data, time::Duration timeout) @dynamic
{
	self.calls++;
	return self.inner.write(data, timeout);
}

fn void? OtherTransport.close(&self) @dynamic
{
	self.calls++;
	return self.inner.close();
}

fn void test_a_transport_from_another_library_through_a_cast() @test
{
	fake_reset(usz::max);
	OtherTransport other;
	other.inner.reply(FX_V6, 1);
	other.inner.reply(FX_V12, 2);
	other.inner.reply(FX_V21, 3);
	TrackingAllocator t;
	t.init(mem);
	Client c;
	Transport as_transport = (Transport)&other;
	c.open(as_transport, config_480(), &t, &fake_clock)!!;
	char[] bytes = c.read_bytes(addr("DB1.DBW2"), &t)!!;
	Fixture want = fx("12 34");
	assert(same_bytes(bytes, want.bytes()));
	alloc::free(&t, bytes.ptr);
	c.close();
	assert(other.calls > 0 && other.inner.close_calls == 1);
	assert(!t.has_leaks());
	t.free();
}
