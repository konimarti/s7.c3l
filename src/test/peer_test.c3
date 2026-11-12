module s7;

import std::time;

// The peer cases of peer_cases.c3 as tests. Each prints PEER-RUN or PEER-SKIP; they run against the python-snap7 server
// when S7_PEER=host:port is set (see scripts/run_peer.py) and are skipped otherwise. With S7_PEER_REQUIRED=1 a missing
// peer fails them, so the pass count proves the cases ran even when the test output is not shown.

fn void test_peer_read_range() @test
{
	peer_execute(PEER_CASES[0], false);
}

fn void test_peer_read_word_and_bits() @test
{
	peer_execute(PEER_CASES[1], false);
}

fn void test_peer_write_and_read_back() @test
{
	peer_execute(PEER_CASES[2], false);
}

fn void test_peer_write_refused_without_allow_write() @test
{
	peer_execute(PEER_CASES[3], false);
}

fn void test_peer_read_4000_bytes_of_db2() @test
{
	peer_execute(PEER_CASES[4], false);
}

fn void test_peer_multi_read_of_25_items() @test
{
	peer_execute(PEER_CASES[5], false);
}

fn void test_peer_missing_db_and_range_errors() @test
{
	peer_execute(PEER_CASES[6], false);
}

fn void test_peer_merker_inputs_outputs() @test
{
	peer_execute(PEER_CASES[7], false);
}

fn void test_peer_timers_and_counters() @test
{
	peer_execute(PEER_CASES[8], false);
}

fn void test_peer_cpu_state_info_and_clock() @test
{
	peer_execute(PEER_CASES[9], false);
}

fn void test_peer_module_identification() @test
{
	peer_execute(PEER_CASES[10], false);
}

fn void test_peer_unavailable_list_keeps_the_connection_usable() @test
{
	peer_execute(PEER_CASES[11], false);
}

fn void test_peer_exchanges_kept_as_fixtures() @test
{
	peer_execute(PEER_CASES[12], false);
}

// ---- the captured conversation, without a peer ----

fn void expect_same_frame(String a, String b)
{
	Fixture x = fx(a);
	Fixture y = fx(b);
	assert(same_bytes(x.bytes(), y.bytes()), "captured %s", a);
}

// The frames the real server exchanged are the frames derived by hand.
fn void test_captured_frames_equal_the_derived_vectors() @test
{
	expect_same_frame(FXP_W0, FX_V1);                        // connection request
	expect_same_frame(FXP_R0, FX_V6);                        // connection confirm
	expect_same_frame(FXP_R1, FX_V12);                       // setup answer: 480
	expect_same_frame(FXP_W2, FX_V20);                       // read of DB1.DBW2
	expect_same_frame(FXP_W3, FX_V40);                       // write of DB1.DBW2 := 0x1234
	expect_same_frame(FXP_R3, FX_V41);                       // its answer
	Fixture fourth = with_ref(FXP_R4, 2);                    // the read after the write: 12 34
	Fixture v21 = fx(FX_V21);
	assert(same_bytes(fourth.bytes(), v21.bytes()), "the captured read answer equals V21 apart from its reference");
	// the setup request of a default configuration offers 960; the captured one is exactly that
	char[32] out;
	usz n = encode_setup_request(1, 960, out[..])!!;
	Fixture setup = fx(FXP_W1);
	assert(same_bytes(out[:n], setup.bytes()));
}

// A client driven by the captured answers sends exactly the captured requests.
fn void test_the_client_replays_the_captured_conversation() @test
{
	time::Clock t0 = at_ms(1000);
	g_fake_now = t0;
	g_fake_calls = 0;
	g_fake_jump_after = usz::max;
	TrackingAllocator t;
	t.init(mem);
	MemTransport mt;
	mt.reply(FXP_R0, 1);
	mt.reply(FXP_R1, 2);
	mt.reply(FXP_R2, 3);
	mt.reply(FXP_R3, 4);
	mt.reply(FXP_R4, 5);
	mt.reply(FXP_R5, 6);
	mt.reply(FXP_R6, 7);
	SessionConfig cfg = default_config(tsaps_from_rack_slot(PG, 0, 2)!!);
	cfg.allow_write = true;
	Client c;
	c.open(&mt, cfg, &t, &fake_clock)!!;
	assert(c.pdu_size() == 480);
	Value before = c.read_value(addr("DB1.DBW2"), WORD, &t)!!;
	assert(before.u == 0x0203);
	char[2] value = { 0x12, 0x34 };
	c.write_bytes(addr("DB1.DBW2"), value[..])!!;
	assert(c.read_value(addr("DB1.DBW2"), WORD, &t)!!.u == 0x1234);
	char[2] original = { 0x02, 0x03 };
	c.write_bytes(addr("DB1.DBW2"), original[..])!!;
	assert(c.read_value(addr("DB1.DBW2"), WORD, &t)!!.u == 0x0203);
	c.close();
	String[8] sent = { FXP_W0, FXP_W1, FXP_W2, FXP_W3, FXP_W4, FXP_W5, FXP_W6, FXP_W7 };
	assert(mt.write_calls == 8);
	foreach (k, frame : sent)
	{
		Fixture want = fx(frame);
		assert(same_bytes(mt.write_at((usz)k), want.bytes()), "frame %d the client sent", (int)k);
	}
	assert(!t.has_leaks());
	t.free();
}
