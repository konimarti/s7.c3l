module s7;

import s7tool;

// Tests of the command line tool's pure parts (src/tool/cli.c3). No process is started and no connection is made.

fn s7tool::Options parse(String[] args)
{
	s7tool::Options o = s7tool::default_options();
	s7tool::parse_options(args, &o)!!;
	return o;
}

fn fault parse_fault(String[] args)
{
	s7tool::Options o = s7tool::default_options();
	return @catch(s7tool::parse_options(args, &o));
}

// ---- escape_for_terminal ----

fn void expect_escaped(char[] input, String want)
{
	TrackingAllocator t;
	t.init(mem);
	String got = s7tool::escape_for_terminal((String)input, &t);
	assert(got == want, "escaped %s", got);
	if (got.len > 0) alloc::free(&t, got.ptr);
	assert(!t.has_leaks());
	t.free();
}

fn void test_escape_for_terminal_fixture() @test
{
	Fixture f = fx("41 1B 5B 32 4A 00 7F 42");                    // A ESC [ 2 J NUL DEL B
	expect_escaped(f.bytes(), "A\\x1B[2J\\x00\\x7FB");
}

fn void test_escape_keeps_text_and_shows_everything_else() @test
{
	expect_escaped(fx("").bytes(), "");
	expect_escaped(fx("48 65 6C 6C 6F").bytes(), "Hello");
	expect_escaped(fx("41 0A 42 0D 09").bytes(), "A\\x0AB\\x0D\\x09");
	// valid UTF-8 passes: e-acute, euro sign, an emoji
	expect_escaped(fx("C3 A9 E2 82 AC F0 9F 98 80").bytes(), "é€\U0001F600");
	// bytes that are not UTF-8 are shown one by one
	expect_escaped(fx("FF 41 80 42").bytes(), "\\xFFA\\x80B");
	expect_escaped(fx("C3").bytes(), "\\xC3");                            // truncated sequence
	expect_escaped(fx("E2 82").bytes(), "\\xE2\\x82");
	expect_escaped(fx("C0 AF").bytes(), "\\xC0\\xAF");                    // overlong
	expect_escaped(fx("ED A0 80").bytes(), "\\xED\\xA0\\x80");            // a surrogate
	expect_escaped(fx("F4 90 80 80").bytes(), "\\xF4\\x90\\x80\\x80");    // above U+10FFFF
	// the C1 control U+009B (CSI) is a terminal escape too
	expect_escaped(fx("41 C2 9B 42").bytes(), "A\\xC2\\x9BB");
	expect_escaped(fx("C2 A0").bytes(), " ");                        // U+00A0 is fine
}

fn void test_escape_never_lets_a_control_byte_through() @test
{
	TrackingAllocator t;
	t.init(mem);
	for (uint b = 0; b < 256; b++)
	{
		char[3] in = { 0x41, (char)b, 0x42 };
		String out = s7tool::escape_for_terminal((String)in[..], &t);
		foreach (c : out) assert(c >= 0x20 && c != 0x7F, "byte %d leaked a control byte", (int)b);
		alloc::free(&t, out.ptr);
	}
	assert(!t.has_leaks());
	t.free();
}

// ---- options ----

fn void test_parse_a_read() @test
{
	s7tool::Options o = s7tool::default_options();
	String[5] ok = { "s7tool", "--host", "10.0.0.5", "read", "DB1.DBW2" };
	s7tool::parse_options(ok[..], &o)!!;
	assert(o.host == "10.0.0.5" && o.port == 102 && o.command == s7tool::Command.READ && o.address == "DB1.DBW2");
	assert(o.rack == 0 && o.slot == 2 && o.conn == PG && o.timeout_ms == 5000 && !o.has_type && !o.allow_write);
}

fn void test_parse_all_options() @test
{
	String[] args = {
		"s7tool", "--host", "plc", "--port", "1102", "--rack", "1", "--slot", "3", "--conn", "OP", "--timeout", "250",
		"--type", "int", "read", "DB1.DBW2"
	};
	s7tool::Options o = parse(args);
	assert(o.port == 1102 && o.rack == 1 && o.slot == 3 && o.conn == OP && o.timeout_ms == 250);
	assert(o.has_type && o.kind == INT);
	// options may come after the command
	String[] late = { "s7tool", "read", "DB1.DBW2", "--host", "plc", "--port", "5" };
	s7tool::Options l = parse(late);
	assert(l.host == "plc" && l.port == 5 && l.command == s7tool::Command.READ);
}

fn void test_parse_commands() @test
{
	String[] info = { "s7tool", "--host", "h", "info" };
	assert(parse(info).command == s7tool::Command.INFO);
	String[] write = { "s7tool", "--host", "h", "write", "DB1.DBW0", "5", "--type", "INT", "--allow-write" };
	s7tool::Options w = parse(write);
	assert(w.command == s7tool::Command.WRITE && w.address == "DB1.DBW0" && w.value == "5" && w.allow_write);
	String[] dump = { "s7tool", "--host", "h", "dump", "DB1.DBB0", "16" };
	s7tool::Options d = parse(dump);
	assert(d.command == s7tool::Command.DUMP && d.dump_len == 16);
	String[] help = { "s7tool", "--help" };
	assert(parse(help).help);
}

fn void test_parse_errors_are_usage_errors() @test
{
	String[][] bad = {
		{ "s7tool" },
		{ "s7tool", "--host", "h" },                                  // no command
		{ "s7tool", "--host", "h", "frobnicate" },
		{ "s7tool", "--host", "h", "read" },                          // missing address
		{ "s7tool", "--host", "h", "read", "A", "B" },
		{ "s7tool", "--host", "h", "info", "extra" },
		{ "s7tool", "info" },                                         // no host
		{ "s7tool", "--host", "h", "--bogus", "1", "info" },
		{ "s7tool", "--host" },                                       // option without value
		{ "s7tool", "--host", "h", "--port", "0", "info" },
		{ "s7tool", "--host", "h", "--port", "65536", "info" },
		{ "s7tool", "--host", "h", "--port", "10x", "info" },
		{ "s7tool", "--host", "h", "--rack", "8", "info" },
		{ "s7tool", "--host", "h", "--slot", "32", "info" },
		{ "s7tool", "--host", "h", "--conn", "xx", "info" },
		{ "s7tool", "--host", "h", "--timeout", "0", "info" },
		{ "s7tool", "--host", "h", "--type", "FLOAT", "read", "MW0" },
		{ "s7tool", "--host", "h", "--model", "s7-9000", "info" },
		{ "s7tool", "--host", "h", "--tsap", "0100", "info" },
		{ "s7tool", "--host", "h", "--tsap", "010:0102", "info" },
		{ "s7tool", "--host", "h", "--tsap", "zz00:0102", "info" },
		{ "s7tool", "--host", "h", "dump", "DB1.DBB0", "0" },
		{ "s7tool", "--host", "h", "dump", "DB1.DBB0", "x" },
		{ "s7tool", "--host", "h", "--allow-write", "read", "MW0" },  // the flag belongs to write
	};
	foreach (i, args : bad)
	{
		assert(parse_fault(args) == s7tool::USAGE, "case %d", (int)i);
	}
}

fn void test_type_names_are_case_insensitive() @test
{
	assert(s7tool::kind_from_name("INT")!! == INT);
	assert(s7tool::kind_from_name("real")!! == REAL);
	assert(s7tool::kind_from_name("Date_And_Time")!! == DATE_AND_TIME);
	assert(s7tool::kind_from_name("counter")!! == COUNTER_BCD);
	assert(@catch(s7tool::kind_from_name("INTEGER")) == s7tool::USAGE);
}

// ---- --model presets and TSAPs ----

fn bool has_tsaps(Tsaps t, ushort local, ushort remote)
{
	return t.local.len == 2 && t.remote.len == 2 && t.local.bytes[0] == (char)(local >> 8) && t.local.bytes[1] == (char)local
		&& t.remote.bytes[0] == (char)(remote >> 8) && t.remote.bytes[1] == (char)remote;
}

fn Tsaps tsaps_of(String[] args)
{
	s7tool::Options o = parse(args);
	return s7tool::tsaps_for(&o)!!;
}

fn void test_models_map_to_tsaps() @test
{
	String[] none = { "s7tool", "--host", "h", "info" };
	assert(has_tsaps(tsaps_of(none), 0x0100, 0x0102));                           // rack 0 slot 2, PG
	String[] s300 = { "s7tool", "--host", "h", "--model", "s7-300", "info" };
	assert(has_tsaps(tsaps_of(s300), 0x0100, 0x0102));
	String[] s400 = { "s7tool", "--host", "h", "--model", "S7-400", "info" };
	assert(has_tsaps(tsaps_of(s400), 0x0100, 0x0102));
	String[] s1200 = { "s7tool", "--host", "h", "--model", "s7-1200", "info" };
	assert(has_tsaps(tsaps_of(s1200), 0x0100, 0x0101));                          // rack 0 slot 1
	String[] s1500 = { "s7tool", "--host", "h", "--model", "s7-1500", "info" };
	assert(has_tsaps(tsaps_of(s1500), 0x0100, 0x0101));
	String[] s200 = { "s7tool", "--host", "h", "--model", "s7-200", "info" };
	assert(has_tsaps(tsaps_of(s200), 0x1000, 0x1001));                           // raw TSAPs
	String[] logo = { "s7tool", "--host", "h", "--model", "logo", "info" };
	assert(has_tsaps(tsaps_of(logo), 0x0100, 0x0200));
}

fn void test_explicit_settings_beat_the_model() @test
{
	String[] slot = { "s7tool", "--host", "h", "--model", "s7-1200", "--slot", "4", "info" };
	assert(has_tsaps(tsaps_of(slot), 0x0100, 0x0104));
	String[] rack = { "s7tool", "--host", "h", "--rack", "1", "--slot", "2", "--conn", "basic", "info" };
	assert(has_tsaps(tsaps_of(rack), 0x0100, 0x0322));
	String[] raw = { "s7tool", "--host", "h", "--model", "s7-1200", "--tsap", "1000:1001", "info" };
	assert(has_tsaps(tsaps_of(raw), 0x1000, 0x1001));
	String[] long_tsap = { "s7tool", "--host", "h", "--tsap", "123456:0102", "info" };
	Tsaps t = tsaps_of(long_tsap);
	assert(t.local.len == 3 && t.local.bytes[2] == 0x56 && has_tsaps({ .local = tsap_from_u16(0x0102), .remote = tsap_from_u16(0x0102) }, 0x0102, 0x0102));
}

// ---- the write guard and exit codes ----

fn void test_write_is_refused_before_connecting() @test
{
	String[] refused = { "s7tool", "--host", "127.0.0.1", "--port", "1", "write", "DB1.DBW0", "5", "--type", "INT" };
	s7tool::Options o = parse(refused);
	assert(s7tool::write_guard(&o) == s7tool::EXIT_REFUSED);
	String[] allowed = { "s7tool", "--host", "h", "write", "DB1.DBW0", "5", "--type", "INT", "--allow-write" };
	s7tool::Options a = parse(allowed);
	assert(s7tool::write_guard(&a) == s7tool::EXIT_OK);
	String[] read = { "s7tool", "--host", "h", "read", "DB1.DBW0" };
	s7tool::Options r = parse(read);
	assert(s7tool::write_guard(&r) == s7tool::EXIT_OK);
}

fn void test_exit_codes() @test
{
	assert(s7tool::exit_code_for(WRITE_NOT_ALLOWED) == 2);
	assert(s7tool::exit_code_for(s7tool::USAGE) == 1 && s7tool::exit_code_for(INVALID_ADDRESS_TEXT) == 1);
	assert(s7tool::exit_code_for(ACCESS_DENIED) == 4 && s7tool::exit_code_for(OBJECT_DOES_NOT_EXIST) == 4);
	assert(s7tool::exit_code_for(ADDRESS_OUT_OF_RANGE) == 4 && s7tool::exit_code_for(NOT_SUPPORTED) == 4);
	assert(s7tool::exit_code_for(CONNECT_REFUSED) == 3 && s7tool::exit_code_for(TIMEOUT) == 3);
	assert(s7tool::exit_code_for(CLOSED) == 3 && s7tool::exit_code_for(BAD_RESPONSE) == 3);
	assert(s7tool::exit_code_for(NEGOTIATION_FAILED) == 3);
}

fn void test_fault_names_and_hints() @test
{
	assert(s7tool::fault_name(OBJECT_DOES_NOT_EXIST) == "OBJECT_DOES_NOT_EXIST");
	assert(s7tool::fault_name(CONNECT_REFUSED) == "CONNECT_REFUSED");
	assert(s7tool::fault_name(s7tool::USAGE) == "USAGE");
	String hint = s7tool::hint_for(ACCESS_DENIED);
	assert(hint.len > 0);
	bool found = false;
	for (usz i = 0; i + 7 <= hint.len; i++)
	{
		if (hint[i:7] == "PUT/GET") found = true;
	}
	assert(found, "the access denied hint names PUT/GET");
	assert(s7tool::hint_for(TIMEOUT) == "");
}

// ---- output formatting ----

fn void test_hex_bytes_and_dump() @test
{
	TrackingAllocator t;
	t.init(mem);
	Fixture f = fx("12 34 0A");
	String hex = s7tool::hex_bytes(f.bytes(), &t);
	assert(hex == "12 34 0A");
	alloc::free(&t, hex.ptr);
	assert(s7tool::hex_bytes(fx("").bytes(), &t) == "");

	char[20] data;
	foreach (i, &b : data) *b = (char)i;
	data[3] = 'A';
	data[19] = 0xFF;
	String dump = s7tool::format_dump(data[..], 0x100, &t);
	String want = "0100  00 01 02 41 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  |...A............|\n0110  10 11 12 FF                                      |...  |\n";
	assert(dump.len > 0);
	assert(dump[:74] == want[:74], "first line of the dump: %s", dump);
	// the second line: offset, four bytes, padding, the ASCII column of four characters
	assert(dump[74:4] == "0110" && dump[80:11] == "10 11 12 FF");
	assert(dump[dump.len - 1] == '\n');
	alloc::free(&t, dump.ptr);
	assert(!t.has_leaks());
	t.free();
}

fn void test_dump_of_sixteen_bytes_starts_like_the_peer_example() @test
{
	TrackingAllocator t;
	t.init(mem);
	char[16] data;
	foreach (i, &b : data) *b = (char)i;
	String dump = s7tool::format_dump(data[..], 0, &t);
	assert(dump == "0000  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  |................|\n");
	alloc::free(&t, dump.ptr);
	t.free();
}

fn void test_date_and_value_formatting() @test
{
	assert(s7tool::format_date(0) == "1990-01-01");
	assert(s7tool::format_date(365) == "1991-01-01");
	assert(s7tool::format_date(59) == "1990-03-01");
	assert(s7tool::format_date(65378) == "2168-12-31");
	Value i = { .kind = INT, .i = -2 };
	assert(s7tool::format_value(&i) == "-2");
	Value b = { .kind = BOOL, .b = true };
	assert(s7tool::format_value(&b) == "true");
	Value w = { .kind = WORD, .u = 515 };
	assert(s7tool::format_value(&w) == "515");
	Value tod = { .kind = TOD, .u = 3723004 };
	assert(s7tool::format_value(&tod) == "01:02:03.004");
	Value s = { .kind = STRING, .str = "a\x1B[2Jb" };
	assert(s7tool::format_value(&s) == "a\\x1B[2Jb", "a string from the PLC is escaped");
}

// ---- write payloads ----

fn void test_write_payloads() @test
{
	TrackingAllocator t;
	t.init(mem);
	String[] int_write = { "s7tool", "--host", "h", "write", "DB1.DBW0", "5", "--type", "INT", "--allow-write" };
	s7tool::Options o = parse(int_write);
	Address a = parse_address("DB1.DBW0")!!;
	char[] p = s7tool::payload_for_write(&o, &a, &t)!!;
	assert(p.len == 2 && p[0] == 0 && p[1] == 5);
	alloc::free(&t, p.ptr);

	String[] neg = { "s7tool", "--host", "h", "write", "DB1.DBW0", "-2", "--type", "INT", "--allow-write" };
	s7tool::Options n = parse(neg);
	char[] np = s7tool::payload_for_write(&n, &a, &t)!!;
	assert(np[0] == 0xFF && np[1] == 0xFE);
	alloc::free(&t, np.ptr);

	String[] out_of_range = { "s7tool", "--host", "h", "write", "DB1.DBW0", "40000", "--type", "INT", "--allow-write" };
	s7tool::Options r = parse(out_of_range);
	assert(@catch(s7tool::payload_for_write(&r, &a, &t)) == INVALID_VALUE);

	// without --type the value is hex bytes of the size of the address
	String[] hex = { "s7tool", "--host", "h", "write", "DB1.DBW0", "12AB", "--allow-write" };
	s7tool::Options h = parse(hex);
	char[] hp = s7tool::payload_for_write(&h, &a, &t)!!;
	assert(hp[0] == 0x12 && hp[1] == 0xAB);
	alloc::free(&t, hp.ptr);
	String[] short_hex = { "s7tool", "--host", "h", "write", "DB1.DBW0", "12", "--allow-write" };
	s7tool::Options sh = parse(short_hex);
	assert(@catch(s7tool::payload_for_write(&sh, &a, &t)) == s7tool::USAGE);
	String[] bad_hex = { "s7tool", "--host", "h", "write", "DB1.DBW0", "12GG", "--allow-write" };
	s7tool::Options bh = parse(bad_hex);
	assert(@catch(s7tool::payload_for_write(&bh, &a, &t)) == s7tool::USAGE);

	// a string takes its capacity from the address
	String[] text = { "s7tool", "--host", "h", "write", "DB1.DBB0[6]", "'ab'", "--type", "STRING", "--allow-write" };
	s7tool::Options s = parse(text);
	Address sa = parse_address("DB1.DBB0[6]")!!;
	char[] sp = s7tool::payload_for_write(&s, &sa, &t)!!;
	Fixture want = fx("04 02 61 62 00 00");
	assert(same_bytes(sp, want.bytes()));
	alloc::free(&t, sp.ptr);
	assert(!t.has_leaks());
	t.free();
}

// ---- info on a lost connection ----

fn void test_info_fails_with_exit_code_3_when_the_connection_is_lost() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.mt.eof_when_exhausted = true;                         // the PLC goes away after the handshake
	r.handshake(FX_V12);
	r.open_480();
	assert(s7tool::cmd_info(&r.c) == s7tool::EXIT_CONNECTION);
	r.finish();
}

fn void test_info_stays_ok_when_the_plc_just_does_not_know_a_list() @test
{
	fake_reset(usz::max);
	ClientRig r;
	r.handshake(FX_V12);
	Fixture first = with_ref(FX_PEER_SZL_UNAVAILABLE, 2);      // module identification: not provided
	Fixture second = with_ref(FX_PEER_SZL_UNAVAILABLE, 3);     // CPU state: not provided
	Fixture third = with_ref(FX_M42, 4);                       // a clock answer that is too short
	r.mt.reply_bytes(first.bytes(), 3);
	r.mt.reply_bytes(second.bytes(), 4);
	r.mt.reply_bytes(third.bytes(), 5);
	r.open_480();
	assert(s7tool::cmd_info(&r.c) == s7tool::EXIT_OK);
	r.finish();
}

fn void test_dump_offsets_are_not_cut_at_four_digits() @test
{
	TrackingAllocator t;
	t.init(mem);
	char[2] data = { 1, 2 };
	String high = s7tool::format_dump(data[..], 0x12340, &t);
	assert(high[:7] == "12340  ", "offset column: %s", high);
	alloc::free(&t, high.ptr);
	String low = s7tool::format_dump(data[..], 0x0100, &t);
	assert(low[:6] == "0100  ");
	alloc::free(&t, low.ptr);
	// a dump that crosses 0xFFFF prints every offset with the same width
	char[32] big;
	String across = s7tool::format_dump(big[..], 0xFFF0, &t);
	assert(across[:7] == "FFF0   " || across[:7] == "0FFF0  ", "first offset: %s", across);
	String line2 = across[(across.len / 2)..];
	assert(line2[:5] == "10000" || line2[:6] == "010000", "second line: %s", line2);
	alloc::free(&t, across.ptr);
	assert(!t.has_leaks());
	t.free();
}
