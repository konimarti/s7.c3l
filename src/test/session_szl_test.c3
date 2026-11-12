module s7;

import std::time;

// Session tests for the SZL and clock jobs. The frames are the SZL fixtures of szl_test.c3 (V* and M* are the IDs of
// the independent test vector set) with the reference number patched to the one the session used.

// The fixture with its pdu_ref set.
fn Fixture with_ref(String hex, ushort ref)
{
	Fixture f = fx(hex);
	f.buf[11] = (char)(ref >> 8);
	f.buf[12] = (char)ref;
	return f;
}

// The fixture with its pdu_ref and its userdata sequence number set.
fn Fixture with_ref_seq(String hex, ushort ref, char seq)
{
	Fixture f = with_ref(hex, ref);
	f.buf[24] = seq;
	return f;
}

fn void Rig.feed_ref(&self, String hex, ushort ref, time::Clock now)
{
	Fixture f = with_ref(hex, ref);
	self.s.feed(f.bytes(), now)!!;
}

fn void Rig.expect_output_ref(&self, String hex, ushort ref)
{
	Fixture want = with_ref(hex, ref);
	assert(same_bytes(self.s.pending_output(), want.bytes()), "pending output %s", hex);
	self.s.consume_output(want.len);
}

fn void test_szl_read_in_one_fragment() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.s.submit_szl(0x001C, 0, at_ms(10))!!;
	assert(r.s.state == JOB_IN_FLIGHT && r.s.next_deadline() == at_ms(10).add_duration(time::sec(5)));
	r.expect_output_ref(FX_V51, 2);                                // the request of V51 with the session's reference
	r.feed_ref(FX_V53, 2, at_ms(11));                              // V53: two records of 34 bytes
	Event e = r.expect(JOB_DONE);
	assert(e.id == id && e.completion.kind == SZL);
	assert(e.completion.szl_id == 0x001C && e.completion.szl_index == 0);
	assert(e.completion.rec_len == 34 && e.completion.rec_count == 2 && e.completion.payload.len == 68);
	assert(e.completion.payload[0] == 0x00 && e.completion.payload[1] == 0x01);     // record 1: index 0001
	CpuInfo info = decode_component_id(e.completion.payload, e.completion.rec_len, &r.alloc)!!;
	info.free(&r.alloc);
	e.completion.free();
	assert(r.s.state == READY && r.s.next_deadline() == (time::Clock)0);
	r.finish();
}

fn void test_szl_read_in_two_fragments() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.s.submit_szl(0x001C, 0, at_ms(10))!!;
	r.expect_output_ref(FX_V51, 2);
	r.feed_ref(FX_V53_FRAG1, 2, at_ms(11));                        // "more" with sequence number 1
	r.expect_no_event();
	// the continuation request echoes the sequence number, has its own reference and re-arms the deadline
	Fixture cont = with_ref_seq(FX_V51, 3, 1);
	assert(same_bytes(r.s.pending_output(), cont.bytes()));
	r.s.consume_output(cont.len);
	assert(r.s.state == JOB_IN_FLIGHT && r.s.next_deadline() == at_ms(11).add_duration(time::sec(5)));
	r.feed_ref(FX_V53_FRAG2, 3, at_ms(12));                        // the last fragment
	Event e = r.expect(JOB_DONE);
	assert(e.id == id && e.completion.kind == SZL);
	assert(e.completion.rec_len == 34 && e.completion.rec_count == 2 && e.completion.payload.len == 68);
	Fixture whole = fx(FX_V53);
	assert(same_bytes(e.completion.payload, whole.bytes()[41..]));
	e.completion.free();
	assert(r.s.state == READY);
	r.finish();
}

fn void test_szl_fragment_cap_fails_the_job() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.s.submit_szl(0x001C, 0, at_ms(10))!!;
	usz requests = 1;
	char seq = 1;
	fault failure;
	usz guard = 0;
	while (!failure && guard < 200)
	{
		guard++;
		ushort ref = pending_ref(&r.s);
		r.s.consume_output(r.s.pending_output().len);
		Fixture f = with_ref_seq(FX_M38, ref, seq);              // "more" forever
		r.s.feed(f.bytes(), at_ms(11))!!;
		seq++;
		Event? e = r.s.next_event();
		if (try ev = e)
		{
			assert(ev.kind == JOB_FAILED && ev.id == id);
			failure = ev.error;
		}
		else
		{
			requests++;
		}
	}
	assert(failure == BAD_RESPONSE);
	assert(requests == 65, "the first request and 64 continuations, then the cap");
	assert(r.s.state == READY && r.s.pending_output().len == 0);
	r.finish();
}

fn void test_szl_size_cap_fails_the_job() @test
{
	SessionConfig cfg = config_480();
	cfg.limits.max_request_bytes = 60;                             // a fragment of 68 record bytes is too much
	Rig r;
	r.start(cfg);
	r.connect_480();
	r.s.submit_szl(0x001C, 0, at_ms(10))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_ref(FX_V53, 2, at_ms(11));
	assert(r.expect(JOB_FAILED).error == INVALID_ARGUMENT);
	assert(r.s.state == READY);
	r.finish();
}

fn void test_szl_sequence_mismatch_fails_the_job() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.s.submit_szl(0x001C, 0, at_ms(10))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_ref(FX_V53_FRAG1, 2, at_ms(11));
	r.s.consume_output(r.s.pending_output().len);
	Fixture wrong = with_ref_seq(FX_V53_FRAG2, 3, 7);              // sequence number 7 instead of 2
	r.s.feed(wrong.bytes(), at_ms(12))!!;
	assert(r.expect(JOB_FAILED).error == UNEXPECTED_PDU);
	assert(r.s.state == READY);
	r.finish();                                                    // the fragment collected so far is released
}

fn void test_szl_not_available_maps_to_not_supported() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.s.submit_szl(0x0424, 0, at_ms(10))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_ref(FX_V54, 2, at_ms(11));                              // V54: parameter error D401 and return code 0A
	assert(r.expect(JOB_FAILED).error == NOT_SUPPORTED);
	assert(r.s.state == READY);
	// the session is still usable
	r.s.submit_szl(0x0424, 0, at_ms(12))!!;
	assert(pending_ref(&r.s) == 3);
	r.finish();
}

fn void test_szl_other_records_decode() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.s.submit_szl(0x0424, 0, at_ms(10))!!;
	r.expect_output_ref(FX_V52, 2);
	r.feed_ref(FX_V56, 2, at_ms(11));                              // V56: the CPU state record
	Event e = r.expect(JOB_DONE);
	assert(e.completion.szl_id == 0x0424 && e.completion.payload.len == (usz)e.completion.rec_len * (usz)e.completion.rec_count);
	assert(decode_cpu_state(e.completion.payload, e.completion.rec_len)!! == RUN);
	e.completion.free();
	r.finish();
}

fn void test_read_clock_job() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	RequestId id = r.s.submit_read_clock(at_ms(10))!!;
	assert(r.s.next_deadline() == at_ms(10).add_duration(time::sec(5)));
	r.expect_output_ref(FX_V57, 2);
	r.feed_ref(FX_V58, 2, at_ms(11));                              // V58: 2025-11-12 14:30:45
	Event e = r.expect(JOB_DONE);
	assert(e.id == id && e.completion.kind == CLOCK);
	Dtl d = e.completion.clock;
	assert(d.year == 2025 && d.month == 11 && d.day == 12 && d.hour == 14 && d.minute == 30 && d.second == 45);
	assert(r.s.state == READY);
	r.finish();
}

fn void test_read_clock_answers_that_do_not_decode() @test
{
	Rig r;
	r.start(config_480());
	r.connect_480();
	r.s.submit_read_clock(at_ms(10))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_ref(FX_M40, 2, at_ms(11));                              // M40: BCD nibble A
	assert(r.expect(JOB_FAILED).error == INVALID_VALUE);
	assert(r.s.state == READY);
	r.s.submit_read_clock(at_ms(12))!!;
	r.s.consume_output(r.s.pending_output().len);
	r.feed_ref(FX_M42, 3, at_ms(13));                              // M42: short data
	assert(r.expect(JOB_FAILED).error == BAD_RESPONSE);
	assert(r.s.state == READY);
	r.finish();
}

fn void test_userdata_jobs_share_the_job_rules() @test
{
	Rig r;
	r.start(config_480());
	assert(@catch(r.s.submit_szl(0x001C, 0, at_ms(0))) == NOT_CONNECTED);
	assert(@catch(r.s.submit_read_clock(at_ms(0))) == NOT_CONNECTED);
	r.connect_480();
	r.s.submit_szl(0x001C, 0, at_ms(10))!!;
	assert(@catch(r.s.submit_szl(0x001C, 0, at_ms(10))) == BUSY);
	assert(@catch(r.s.submit_read_clock(at_ms(10))) == BUSY);
	Address[1] items = { addr("DB1.DBW2") };
	assert(@catch(r.s.submit_read(items[..], at_ms(10))) == BUSY);
	r.finish();
}

fn void test_userdata_answers_with_the_wrong_reference_or_kind() @test
{
	Rig a;
	a.start(config_480());
	a.connect_480();
	a.s.submit_read_clock(at_ms(10))!!;
	a.s.consume_output(a.s.pending_output().len);
	Fixture wrong_ref = with_ref(FX_V58, 99);
	assert(@catch(a.s.feed(wrong_ref.bytes(), at_ms(11))) == PDU_REF_MISMATCH);
	assert(a.s.state == FAILED);
	a.finish();
	// a read answer for an SZL request is not a userdata answer
	Rig b;
	b.start(config_480());
	b.connect_480();
	b.s.submit_szl(0x001C, 0, at_ms(10))!!;
	b.s.consume_output(b.s.pending_output().len);
	b.feed_hex(FX_V21, at_ms(11));
	assert(b.expect(JOB_FAILED).error == BAD_RESPONSE);
	assert(b.s.state == READY);
	b.finish();
}

fn void test_userdata_jobs_end_with_the_connection() @test
{
	// end of stream between two fragments: the collected records are released
	Rig a;
	a.start(config_480());
	a.connect_480();
	a.s.submit_szl(0x001C, 0, at_ms(10))!!;
	a.s.consume_output(a.s.pending_output().len);
	a.feed_ref(FX_V53_FRAG1, 2, at_ms(11));
	a.s.on_closed(CLOSED, at_ms(12));
	assert(a.expect(JOB_FAILED).error == CLOSED);
	assert(a.expect(DISCONNECTED).error == CLOSED);
	a.finish();
	// timeout while waiting for the continuation
	Rig b;
	b.start(config_480());
	b.connect_480();
	b.s.submit_szl(0x001C, 0, at_ms(10))!!;
	b.s.consume_output(b.s.pending_output().len);
	b.feed_ref(FX_V53_FRAG1, 2, at_ms(11));
	assert(b.s.next_deadline() == at_ms(11).add_duration(time::sec(5)));
	b.s.on_timeout(at_ms(6000));
	assert(b.expect(JOB_FAILED).error == TIMEOUT);
	b.finish();
	// close() fails the job
	Rig c;
	c.start(config_480());
	c.connect_480();
	c.s.submit_read_clock(at_ms(10))!!;
	c.s.close(at_ms(11));
	assert(c.expect(JOB_FAILED).error == CLOSED);
	c.finish();
}
