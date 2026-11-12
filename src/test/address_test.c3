module s7;

// Tests for address.c3. Table rows follow section 4 of the independent test vector set; V* and S* are the IDs of
// its request frames and splitting cases.

fn bool same_addr(Address a, Address b)
{
	return a.area == b.area && a.db == b.db && a.byte_off == b.byte_off && a.bit == b.bit && a.tsize == b.tsize && a.count == b.count;
}

fn void expect_ok(String text, Area area, ushort db, uint off, char bit, Tsize ts, uint count)
{
	Address a = parse_address(text)!!;
	assert(a.area == area, "area of %s", text);
	assert(a.db == db, "db of %s", text);
	assert(a.byte_off == off, "offset of %s", text);
	assert(a.bit == bit, "bit of %s", text);
	assert(a.tsize == ts, "size of %s", text);
	assert(a.count == count, "count of %s", text);
}

fn void expect_fault(String text, fault f)
{
	Address? a = parse_address(text);
	assert(@catch(a) == f, "fault for %s", text);
}

fn void expect_canonical(String text, String canonical)
{
	Address a = parse_address(text)!!;
	@pool()
	{
		String s = a.to_string(tmem);
		assert(s == canonical, "canonical of %s", text);
	};
}

// ---- address table: accepted ----

fn void test_table_db_forms() @test
{
	expect_ok("DB1.DBX0.3", DB, 1, 0, 3, BIT, 1);
	expect_ok("db1.dbx0.3", DB, 1, 0, 3, BIT, 1);
	expect_ok("DB1.DBX0.7", DB, 1, 0, 7, BIT, 1);
	expect_ok("DB1.DBB0", DB, 1, 0, 0, BYTE, 1);
	expect_ok("DB1.DBW2", DB, 1, 2, 0, WORD, 1);
	expect_ok("DB1.DBD4", DB, 1, 4, 0, DWORD, 1);
	expect_ok("DB10.DBB0:16", DB, 10, 0, 0, BYTE, 16);
	expect_ok("DB10.DBB0[16]", DB, 10, 0, 0, BYTE, 16);
	expect_ok("DB65535.DBB0", DB, 65535, 0, 0, BYTE, 1);
	expect_ok("DB1.DBB2097151", DB, 1, 2097151, 0, BYTE, 1);
	expect_ok("DB1.DBB0:65535", DB, 1, 0, 0, BYTE, 65535);
}

fn void test_table_other_areas() @test
{
	expect_ok("MW20", MERKERS, 0, 20, 0, WORD, 1);
	expect_ok("M20.1", MERKERS, 0, 20, 1, BIT, 1);
	expect_ok("MB0", MERKERS, 0, 0, 0, BYTE, 1);
	expect_ok("MD100", MERKERS, 0, 100, 0, DWORD, 1);
	expect_ok("I0.1", INPUTS, 0, 0, 1, BIT, 1);
	expect_ok("E0.1", INPUTS, 0, 0, 1, BIT, 1);
	expect_ok("QB4", OUTPUTS, 0, 4, 0, BYTE, 1);
	expect_ok("A4.0", OUTPUTS, 0, 4, 0, BIT, 1);
	expect_ok("T5", TIMER, 0, 5, 0, TIMER, 1);
	expect_ok("C3", COUNTER, 0, 3, 0, COUNTER, 1);
}

fn void test_aliases_and_extra_spellings() @test
{
	expect_ok("Z3", COUNTER, 0, 3, 0, COUNTER, 1);
	expect_ok("AW10", OUTPUTS, 0, 10, 0, WORD, 1);
	expect_ok("EB7", INPUTS, 0, 7, 0, BYTE, 1);
	expect_ok("LB4", LOCAL, 0, 4, 0, BYTE, 1);
	expect_ok("L2.5", LOCAL, 0, 2, 5, BIT, 1);
	expect_ok("PIB4", PERIPHERY, 0, 4, 0, BYTE, 1);
	expect_ok("PIW4", PERIPHERY, 0, 4, 0, WORD, 1);
	expect_ok("PID8", PERIPHERY, 0, 8, 0, DWORD, 1);
	expect_ok("PQW8", PERIPHERY, 0, 8, 0, WORD, 1);
	expect_ok("pqb1", PERIPHERY, 0, 1, 0, BYTE, 1);
	expect_ok("DI2.DBW0", DI, 2, 0, 0, WORD, 1);
	expect_ok("DI2.DIW0", DI, 2, 0, 0, WORD, 1);
	expect_ok("DI2.DIX1.2", DI, 2, 1, 2, BIT, 1);
	expect_ok("di3.dib5", DI, 3, 5, 0, BYTE, 1);
	expect_ok("MW21", MERKERS, 0, 21, 0, WORD, 1);
	expect_ok("DB1.DBW3", DB, 1, 3, 0, WORD, 1);
	expect_ok("MB4:8", MERKERS, 0, 4, 0, BYTE, 8);
	expect_ok("T5[3]", TIMER, 0, 5, 0, TIMER, 3);
	expect_ok("C3:2", COUNTER, 0, 3, 0, COUNTER, 2);
	expect_ok("I0.1[1]", INPUTS, 0, 0, 1, BIT, 1);
	expect_ok("DB01.DBB007", DB, 1, 7, 0, BYTE, 1);
}

// ---- address table: rejected ----

fn void test_table_rejected_ranges() @test
{
	expect_fault("DB1.DBX0.8", ADDRESS_RANGE);
	expect_fault("DB10.DBB0:0", ADDRESS_RANGE);
	expect_fault("DB10.DBB0[0]", ADDRESS_RANGE);
	expect_fault("DB10.DBB0:65536", ADDRESS_RANGE);
	expect_fault("DB10.DBB0[65536]", ADDRESS_RANGE);
	expect_fault("DB65536.DBB0", ADDRESS_RANGE);
	expect_fault("DB0.DBB0", ADDRESS_RANGE);
	expect_fault("DB1.DBB2097152", ADDRESS_RANGE);
	expect_fault("MW99999999999999999999", ADDRESS_RANGE);
	expect_fault("MW4294967296", ADDRESS_RANGE);
	expect_fault("T65536", ADDRESS_RANGE);
	expect_fault("M20.9", ADDRESS_RANGE);
}

fn void test_table_rejected_syntax() @test
{
	expect_fault("DB1.DBX0", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBW2.1", INVALID_ADDRESS_TEXT);
	expect_fault("T", INVALID_ADDRESS_TEXT);
	expect_fault("T-1", INVALID_ADDRESS_TEXT);
	expect_fault("MW", INVALID_ADDRESS_TEXT);
	expect_fault("MW 20", INVALID_ADDRESS_TEXT);
	expect_fault("MW20 ", INVALID_ADDRESS_TEXT);
	expect_fault(" MW20", INVALID_ADDRESS_TEXT);
	expect_fault("MW0x14", INVALID_ADDRESS_TEXT);
	expect_fault("MW+20", INVALID_ADDRESS_TEXT);
	expect_fault("MW20abc", INVALID_ADDRESS_TEXT);
	expect_fault("", INVALID_ADDRESS_TEXT);
	expect_fault("DB1", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBX", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBQ0", INVALID_ADDRESS_TEXT);
	expect_fault("MW20\x00", INVALID_ADDRESS_TEXT);
	expect_fault("٤", INVALID_ADDRESS_TEXT);
	expect_fault("MW٤", INVALID_ADDRESS_TEXT);
}

fn void test_rejected_extras() @test
{
	expect_fault("I0.1[4]", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBX0.1:2", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBB0[16", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBB0[16]x", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBB0:", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBB0[]", INVALID_ADDRESS_TEXT);
	expect_fault("DBX0.1", INVALID_ADDRESS_TEXT);
	expect_fault("DB.DBB0", INVALID_ADDRESS_TEXT);
	expect_fault("DB1DBB0", INVALID_ADDRESS_TEXT);
	expect_fault("DB1 .DBB0", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBB 0", INVALID_ADDRESS_TEXT);
	expect_fault("X0.1", INVALID_ADDRESS_TEXT);
	expect_fault("IX0.1", INVALID_ADDRESS_TEXT);
	expect_fault("P0", INVALID_ADDRESS_TEXT);
	expect_fault("PX1", INVALID_ADDRESS_TEXT);
	expect_fault("PIX1", INVALID_ADDRESS_TEXT);
	expect_fault("M20.", INVALID_ADDRESS_TEXT);
	expect_fault("DB1.DBB-1", INVALID_ADDRESS_TEXT);
}

// ---- canonical text ----

fn void test_to_string_canonical() @test
{
	expect_canonical("DB1.DBX0.3", "DB1.DBX0.3");
	expect_canonical("db1.dbx0.3", "DB1.DBX0.3");
	expect_canonical("DB1.DBB0", "DB1.DBB0");
	expect_canonical("DB1.DBW2", "DB1.DBW2");
	expect_canonical("DB1.DBD4", "DB1.DBD4");
	expect_canonical("DB10.DBB0:16", "DB10.DBB0[16]");
	expect_canonical("DB10.DBB0[16]", "DB10.DBB0[16]");
	expect_canonical("DB1.DBB0[1]", "DB1.DBB0");
	expect_canonical("DI2.DBW0", "DI2.DIW0");
	expect_canonical("DI2.DIX1.2", "DI2.DIX1.2");
	expect_canonical("MW20", "MW20");
	expect_canonical("M20.1", "M20.1");
	expect_canonical("MD100", "MD100");
	expect_canonical("E0.1", "I0.1");
	expect_canonical("QB4", "QB4");
	expect_canonical("A4.0", "Q4.0");
	expect_canonical("L2.5", "L2.5");
	expect_canonical("PQW8", "PIW8");
	expect_canonical("PIB4[4]", "PIB4[4]");
	expect_canonical("T5", "T5");
	expect_canonical("z3", "C3");
	expect_canonical("T5[3]", "T5[3]");
}

fn void test_round_trip_accepted_inputs() @test
{
	String[] inputs = {
		"DB1.DBX0.3", "DB1.DBB0", "DB1.DBW2", "DB1.DBD4", "DB10.DBB0:16", "DB65535.DBB0", "DB1.DBB2097151",
		"MW20", "M20.1", "MB0", "MD100", "I0.1", "E0.1", "QB4", "A4.0", "T5", "C3", "Z3", "PIW4", "PQD8", "DI2.DBW0", "LB1",
	};
	foreach (text : inputs)
	{
		Address a = parse_address(text)!!;
		@pool()
		{
			String s = a.to_string(tmem);
			Address b = parse_address(s)!!;
			assert(same_addr(a, b), "round trip of %s", text);
		};
	}
}

fn void test_payload_bytes() @test
{
	assert(parse_address("DB1.DBW2")!!.payload_bytes() == 2);
	assert(parse_address("DB1.DBD4")!!.payload_bytes() == 4);
	assert(parse_address("DB1.DBX0.1")!!.payload_bytes() == 1);
	assert(parse_address("DB1.DBB0:100")!!.payload_bytes() == 100);
	assert(parse_address("DB1.DBW0:100")!!.payload_bytes() == 200);
	assert(parse_address("T5:3")!!.payload_bytes() == 6);
	Address big = { .area = DB, .db = 1, .tsize = DWORD, .count = 0xFFFFFFFF };
	assert(big.payload_bytes() == 0xFFFFFFFF);
}

// ---- S7ANY items: request items of V20, V22, V24, V26, V28, V29 and S6 ----

fn void expect_item(String text, String frame, usz item_offset)
{
	Address a = parse_address(text)!!;
	char[16] out;
	usz n = encode_item(&a, out[..])!!;
	assert(n == 12);
	Fixture f = fx(frame);
	assert(same_bytes(out[:12], f.bytes()[item_offset:12]), "item bytes of %s", text);
}

fn void test_item_bytes_of_request_frames() @test
{
	expect_item("DB1.DBW2", FX_V20, 19);
	expect_item("DB1.DBX0.3", FX_V22, 19);
	expect_item("MD20", FX_V24, 19);
	expect_item("T5", FX_V26, 19);
	expect_item("C3", FX_V28, 19);
	expect_item("DB1.DBB0:3", FX_V29, 19);
	expect_item("DB1.DBB10:2", FX_V29, 31);
}

fn void test_item_s6_offset_70000() @test
{
	Address a = parse_address("DB1.DBB70000")!!;
	char[12] out;
	encode_item(&a, out[..])!!;
	assert(out[9] == 0x08 && out[10] == 0x8B && out[11] == 0x80);
	Address max = parse_address("DB1.DBB2097151")!!;
	encode_item(&max, out[..])!!;
	assert(out[9] == 0xFF && out[10] == 0xFF && out[11] == 0xF8);
}

fn void test_item_other_areas_and_sizes() @test
{
	char[12] out;
	Address p = parse_address("PIW4")!!;
	encode_item(&p, out[..])!!;
	Fixture want = fx("12 0A 10 02 00 02 00 00 80 00 00 20");
	assert(same_bytes(out[..], want.bytes()));
	Address b = parse_address("Q4.7")!!;
	encode_item(&b, out[..])!!;
	Fixture want2 = fx("12 0A 10 01 00 01 00 00 82 00 00 27");
	assert(same_bytes(out[..], want2.bytes()));
	Address r = parse_address("DB10.DBB0[16]")!!;
	encode_item(&r, out[..])!!;
	Fixture want3 = fx("12 0A 10 02 00 10 00 0A 84 00 00 00");
	assert(same_bytes(out[..], want3.bytes()));
	Address w = parse_address("DB1.DBW0:4")!!;
	encode_item(&w, out[..])!!;
	Fixture want4 = fx("12 0A 10 02 00 08 00 01 84 00 00 00");
	assert(same_bytes(out[..], want4.bytes()), "word ranges go out as bytes");
	Address t = parse_address("T5:3")!!;
	encode_item(&t, out[..])!!;
	Fixture want5 = fx("12 0A 10 1D 00 03 00 00 1D 00 00 05");
	assert(same_bytes(out[..], want5.bytes()));
}

fn void test_item_encode_errors() @test
{
	char[12] out;
	Address zero = { .area = DB, .db = 1, .tsize = BYTE, .count = 0 };
	assert(@catch(encode_item(&zero, out[..])) == INVALID_ARGUMENT);
	Address bits = { .area = DB, .db = 1, .tsize = BIT, .count = 2 };
	assert(@catch(encode_item(&bits, out[..])) == INVALID_ARGUMENT);
	Address bit8 = { .area = DB, .db = 1, .tsize = BIT, .bit = 8, .count = 1 };
	assert(@catch(encode_item(&bit8, out[..])) == ADDRESS_RANGE);
	Address far = { .area = DB, .db = 1, .byte_off = 2097152, .tsize = BYTE, .count = 1 };
	assert(@catch(encode_item(&far, out[..])) == ADDRESS_RANGE);
	Address huge = { .area = DB, .db = 1, .tsize = BYTE, .count = 65536 };
	assert(@catch(encode_item(&huge, out[..])) == INVALID_ARGUMENT);
	Address ok = { .area = DB, .db = 1, .tsize = BYTE, .count = 65535 };
	assert(encode_item(&ok, out[..])!! == 12);
	Address timer = { .area = TIMER, .byte_off = 65536, .tsize = TIMER, .count = 1 };
	assert(@catch(encode_item(&timer, out[..])) == ADDRESS_RANGE);
	assert(@catch(encode_item(&ok, out[:11])) == BUFFER_TOO_SMALL);
}

fn void test_item_decode() @test
{
	Fixture f = fx(FX_V20);
	Address a = decode_item(f.bytes()[19:12])!!;
	assert(same_addr(a, { .area = DB, .db = 1, .byte_off = 2, .tsize = BYTE, .count = 2 }));
	Fixture g = fx(FX_V22);
	Address b = decode_item(g.bytes()[19:12])!!;
	assert(same_addr(b, { .area = DB, .db = 1, .byte_off = 0, .bit = 3, .tsize = BIT, .count = 1 }));
	Fixture h = fx(FX_V26);
	Address t = decode_item(h.bytes()[19:12])!!;
	assert(same_addr(t, { .area = TIMER, .byte_off = 5, .tsize = TIMER, .count = 1 }));
	Fixture i = fx(FX_V24);
	Address m = decode_item(i.bytes()[19:12])!!;
	assert(same_addr(m, { .area = MERKERS, .byte_off = 20, .tsize = BYTE, .count = 4 }));
}

fn void test_item_decode_errors() @test
{
	Fixture f = fx(FX_V20);
	assert(@catch(decode_item(f.bytes()[19:11])) == TRUNCATED);
	Fixture bad_prefix = fx("13 0A 10 02 00 02 00 01 84 00 00 10");
	assert(@catch(decode_item(bad_prefix.bytes())) == BAD_RESPONSE);
	Fixture bad_syntax = fx("12 0A 11 02 00 02 00 01 84 00 00 10");
	assert(@catch(decode_item(bad_syntax.bytes())) == BAD_RESPONSE);
	Fixture bad_size = fx("12 0A 10 09 00 02 00 01 84 00 00 10");
	assert(@catch(decode_item(bad_size.bytes())) == BAD_RESPONSE);
	Fixture bad_area = fx("12 0A 10 02 00 02 00 01 87 00 00 10");
	assert(@catch(decode_item(bad_area.bytes())) == BAD_RESPONSE);
	Fixture odd = fx("12 0A 10 02 00 02 00 01 84 00 00 11");
	assert(@catch(decode_item(odd.bytes())) == BAD_RESPONSE);
}

fn void test_item_round_trip() @test
{
	String[] inputs = { "DB1.DBX0.3", "DB10.DBB0[16]", "MD20", "I0.1", "QB4", "PIW4", "T5", "C3", "DI2.DIW6", "L4.2", "DB1.DBB70000" };
	foreach (text : inputs)
	{
		Address a = parse_address(text)!!;
		char[12] out;
		encode_item(&a, out[..])!!;
		Address b = decode_item(out[..])!!;
		assert(b.area == a.area && b.db == a.db && b.byte_off == a.byte_off && b.bit == a.bit, "round trip of %s", text);
		assert(b.tsize == a.tsize.wire(), "wire size of %s", text);
	}
}

// ---- deterministic fuzz ----

struct Rng
{
	ulong state;
}

fn ulong Rng.next(&self)
{
	ulong x = self.state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	self.state = x;
	return x;
}

fn usz Rng.below(&self, usz n) => (usz)(self.next() % (ulong)n);

// Every accepted text must survive a canonical round trip and must stop being accepted once junk is appended.
fn bool check_accepted_or_rejected(String text)
{
	Address? a = parse_address(text);
	if (catch err = a)
	{
		assert(err == INVALID_ADDRESS_TEXT || err == ADDRESS_RANGE);
		return false;
	}
	@pool()
	{
		String canonical = a.to_string(tmem);
		Address b = parse_address(canonical)!!;
		assert(same_addr(a, b), "round trip of %s", text);
		assert(a.count >= 1 && a.bit <= 7 && a.byte_off <= MAX_BYTE_OFFSET || a.area == TIMER || a.area == COUNTER);
		String junk = string::tformat("%s!", text);
		assert(!@ok(parse_address(junk)), "junk accepted after %s", text);
		String spaced = string::tformat("%s ", text);
		assert(!@ok(parse_address(spaced)), "space accepted after %s", text);
	};
	return true;
}

fn void test_fuzz_random_strings() @test
{
	String alphabet = "DBIQMTCWXEAZLP0123456789.[]:";
	Rng rng = { 0x9E3779B97F4A7C15 };
	char[16] buf;
	int accepted = 0;
	for (int n = 0; n < 20000; n++)
	{
		usz len = rng.below(13);
		for (usz i = 0; i < len; i++)
		{
			buf[i] = alphabet[rng.below(alphabet.len)];
		}
		if (check_accepted_or_rejected((String)buf[:len])) accepted++;
	}
	assert(accepted > 100, "the random strings must hit valid addresses too");
}

fn void test_fuzz_mutated_valid_addresses() @test
{
	String[] seeds = {
		"DB1.DBX0.3", "DB1.DBW2", "DB1.DBD4", "DB10.DBB0:16", "DB10.DBB0[16]", "MW20", "M20.1", "MD100", "I0.1", "QB4",
		"T5", "C3", "PIW4", "DI2.DIW0", "DB65535.DBB2097151", "LB4",
	};
	String extras = " \x00x-+![]:.0123456789DBWQ٤";
	Rng rng = { 0xD1B54A32D192ED03 };
	char[40] buf;
	int accepted = 0;
	for (int n = 0; n < 20000; n++)
	{
		String seed = seeds[rng.below(seeds.len)];
		usz len = seed.len;
		buf[:len] = seed[..];
		int edits = (int)rng.below(3) + 1;
		for (int e = 0; e < edits; e++)
		{
			usz kind = rng.below(3);
			char c = extras[rng.below(extras.len)];
			if (kind == 0 && len > 0)
			{
				buf[rng.below(len)] = c;
			}
			else if (kind == 1 && len < 30)
			{
				usz at = rng.below((len + 1));
				for (usz k = len; k > at; k--) buf[k] = buf[k - 1];
				buf[at] = c;
				len++;
			}
			else if (len > 0)
			{
				usz at = rng.below(len);
				for (usz k = at; k + 1 < len; k++) buf[k] = buf[k + 1];
				len--;
			}
		}
		if (check_accepted_or_rejected((String)buf[:len])) accepted++;
	}
	assert(accepted > 1000 && accepted < 20000);
}
