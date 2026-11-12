module s7;

// Tests for value.c3. VT* are the IDs of the rows in the independent test vector set (hand derived).

fn Value dec(ValueKind kind, String hex, Allocator allocator)
{
	Fixture f = fx(hex);
	return decode_value(kind, f.bytes(), allocator)!!;
}

fn fault dec_fault(ValueKind kind, String hex)
{
	Fixture f = fx(hex);
	return @catch(decode_value(kind, f.bytes(), mem));
}

fn void expect_u(ValueKind kind, String hex, ulong want)
{
	Value v = dec(kind, hex, mem);
	assert(v.u == want, "u of %s", hex);
}

fn void expect_i(ValueKind kind, String hex, long want)
{
	Value v = dec(kind, hex, mem);
	assert(v.i == want, "i of %s", hex);
}

// The value encodes back to exactly the given bytes.
fn void expect_encodes_to(Value* v, uint max_len, String hex)
{
	Fixture want = fx(hex);
	char[600] out;
	usz n = encode_value(v, out[..], max_len)!!;
	assert(same_bytes(out[:n], want.bytes()), "encoding of %s", hex);
}

fn void expect_dtl(Dtl d, uint year, uint month, uint day, uint weekday, uint hour, uint minute, uint second, uint ns)
{
	assert(d.year == year && d.month == month && d.day == day && d.weekday == weekday);
	assert(d.hour == hour && d.minute == minute && d.second == second && d.nanosecond == ns);
}

// ---- VT1-VT10: numbers ----

fn void test_vt1_to_vt5_integers() @test
{
	expect_i(INT, "FF FE", -2);                        // VT1
	expect_i(INT, "80 00", -32768);                    // VT2
	expect_i(DINT, "FF FF FF FF", -1);                 // VT3
	expect_u(WORD, "AB CD", 43981);                    // VT4
	expect_u(DWORD, "01 02 03 04", 16909060);          // VT5
	expect_u(BYTE, "FF", 255);
	expect_i(INT, "7F FF", 32767);
	expect_i(DINT, "80 00 00 00", -2147483648);
	expect_u(DWORD, "FF FF FF FF", 4294967295);
}

fn void test_vt6_to_vt10_floats() @test
{
	Value one = dec(REAL, "3F 80 00 00", mem);                 // VT6
	assert(one.f == 1.0);
	expect_encodes_to(&one, 0, "3F 80 00 00");

	Value neg_zero = dec(REAL, "80 00 00 00", mem);            // VT7
	assert(neg_zero.f == 0.0);
	expect_encodes_to(&neg_zero, 0, "80 00 00 00");

	Value nan = dec(REAL, "7F C0 00 00", mem);                 // VT8
	assert(nan.f != nan.f);
	expect_encodes_to(&nan, 0, "7F C0 00 00");

	Value d1 = dec(LREAL, "3F F0 00 00 00 00 00 00", mem);     // VT9
	assert(d1.f == 1.0);
	expect_encodes_to(&d1, 0, "3F F0 00 00 00 00 00 00");

	Value pi = dec(LREAL, "40 09 21 FB 54 44 2D 18", mem);     // VT10
	assert(pi.f == 3.141592653589793);
	expect_encodes_to(&pi, 0, "40 09 21 FB 54 44 2D 18");

	Value r = dec(REAL, "C2 F6 E9 79", mem);
	assert(r.f > -123.4561 && r.f < -123.4559);
	Value pif = dec(REAL, "40 49 0F DB", mem);
	assert(pif.f > 3.14159 && pif.f < 3.1416);
}

fn void test_bool_and_bits() @test
{
	assert(dec(BOOL, "01", mem).b);
	assert(!dec(BOOL, "00", mem).b);
	assert(dec(BOOL, "03", mem).b);
	assert(!dec(BOOL, "02", mem).b);
	assert(decode_bool(0b00001000, 3) && !decode_bool(0b00001000, 2) && decode_bool(0x80, 7));
	Value t = { .kind = BOOL, .b = true };
	expect_encodes_to(&t, 0, "01");
}

// ---- VT11-VT16: strings and characters ----

fn void test_vt11_string() @test
{
	TrackingAllocator t;
	t.init(mem);
	Value v = dec(STRING, "0A 02 48 69 00 00 00 00 00 00 00 00", &t);   // VT11
	assert(v.str == "Hi");
	expect_encodes_to(&v, 10, "0A 02 48 69 00 00 00 00 00 00 00 00");
	v.free(&t);
	assert(!t.has_leaks());
	t.free();
}

fn void test_vt12_string_current_above_max() @test
{
	assert(dec_fault(STRING, "02 03 41 42 43") == INVALID_VALUE);              // VT12
	assert(dec_fault(STRING, "0A 03 41 42") == VALUE_TOO_SHORT);
	assert(dec_fault(STRING, "0A") == VALUE_TOO_SHORT);
}

fn void test_vt13_string_max_254_empty() @test
{
	char[256] buf;
	buf[0] = 0xFE;
	Value v = decode_value(STRING, buf[..], mem)!!;                           // VT13
	assert(v.str.len == 0);
	char[256] out;
	assert(encode_value(&v, out[..], 254)!! == 256);
	assert(out[0] == 0xFE && out[1] == 0);
	v.free(mem);
}

fn void test_string_latin1_to_utf8() @test
{
	TrackingAllocator t;
	t.init(mem);
	Value v = dec(STRING, "04 03 41 E9 FF 00", &t);
	assert(v.str == "Aéÿ");
	char[16] out;
	assert(encode_value(&v, out[..], 4)!! == 6);
	assert(out[0] == 4 && out[1] == 3 && out[2] == 0x41 && out[3] == 0xE9 && out[4] == 0xFF && out[5] == 0);
	v.free(&t);
	assert(!t.has_leaks());
	t.free();
}

fn void test_vt14_wstring() @test
{
	TrackingAllocator t;
	t.init(mem);
	Value v = dec(WSTRING, "00 04 00 02 00 41 00 E9 00 00 00 00", &t);        // VT14
	assert(v.str == "Aé");
	expect_encodes_to(&v, 4, "00 04 00 02 00 41 00 E9 00 00 00 00");
	v.free(&t);
	Value ab = dec(WSTRING, "00 05 00 02 00 41 00 42 00 00 00 00 00 00", &t);
	assert(ab.str == "AB");
	ab.free(&t);
	assert(!t.has_leaks());
	t.free();
}

fn void test_vt15_wstring_current_above_max() @test
{
	assert(dec_fault(WSTRING, "00 01 00 02 00 41 00 42") == INVALID_VALUE);   // VT15
	assert(dec_fault(WSTRING, "00 05 00 02 00 41") == VALUE_TOO_SHORT);
	assert(dec_fault(WSTRING, "00 05 00") == VALUE_TOO_SHORT);
}

fn void test_wstring_surrogates() @test
{
	TrackingAllocator t;
	t.init(mem);
	Value v = dec(WSTRING, "00 04 00 02 D8 3D DE 00 00 00 00 00", &t);
	assert(v.str == "\U0001F600");
	expect_encodes_to(&v, 4, "00 04 00 02 D8 3D DE 00 00 00 00 00");
	v.free(&t);
	assert(!t.has_leaks());
	t.free();
	assert(dec_fault(WSTRING, "00 04 00 01 D8 3D 00 00 00 00 00 00") == INVALID_VALUE);        // lone high surrogate
	assert(dec_fault(WSTRING, "00 04 00 01 DE 00 00 00 00 00 00 00") == INVALID_VALUE);        // lone low surrogate
	assert(dec_fault(WSTRING, "00 04 00 02 D8 3D 00 41 00 00 00 00") == INVALID_VALUE);  // high surrogate without low
}

fn void test_vt16_char() @test
{
	Value v = dec(CHAR, "41", mem);                                            // VT16
	assert(v.str == "A");
	expect_encodes_to(&v, 0, "41");
	v.free(mem);
	Value e = dec(CHAR, "E9", mem);
	assert(e.str == "é");
	e.free(mem);
}

// ---- VT17-VT26: DATE, TIME, TOD ----

fn void test_vt17_to_vt20_date() @test
{
	expect_u(DATE, "00 00", 0);                          // VT17
	expect_u(DATE, "01 6D", 365);                        // VT18
	expect_u(DATE, "FF 62", 65378);                      // VT19
	assert(dec_fault(DATE, "FF 63") == INVALID_VALUE);   // VT20
	assert(dec_fault(DATE, "FF FF") == INVALID_VALUE);
}

fn void test_vt21_to_vt23_time() @test
{
	expect_i(TIME, "00 00 03 E8", 1000);                 // VT21
	expect_i(TIME, "80 00 00 00", -2147483648);          // VT22
	expect_i(TIME, "7F FF FF FF", 2147483647);           // VT23
	expect_i(TIME, "FF FF FF FF", -1);
}

fn void test_vt24_to_vt26_tod() @test
{
	expect_u(TOD, "00 00 03 E8", 1000);                  // VT24
	assert(dec_fault(TOD, "05 26 5C 00") == INVALID_VALUE);   // VT25
	expect_u(TOD, "05 26 5B FF", 86399999);              // VT26
}

// ---- VT27-VT32: DATE_AND_TIME ----

fn void test_vt27_date_and_time() @test
{
	Value v = dec(DATE_AND_TIME, "25 11 12 14 30 45 12 34", mem);             // VT27
	expect_dtl(v.dtl, 2025, 11, 12, 4, 14, 30, 45, 123000000);
	expect_encodes_to(&v, 0, "25 11 12 14 30 45 12 34");
	Value w = dec(DATE_AND_TIME, "24 11 12 13 45 30 12 33", mem);
	expect_dtl(w.dtl, 2024, 11, 12, 3, 13, 45, 30, 123000000);
}

fn void test_vt28_vt29_year_pivot() @test
{
	Value a = dec(DATE_AND_TIME, "90 01 01 00 00 00 00 02", mem);             // VT28
	expect_dtl(a.dtl, 1990, 1, 1, 2, 0, 0, 0, 0);
	Value b = dec(DATE_AND_TIME, "89 12 31 23 59 59 99 96", mem);             // VT29
	expect_dtl(b.dtl, 2089, 12, 31, 6, 23, 59, 59, 999000000);
	Value c = dec(DATE_AND_TIME, "99 12 31 23 59 59 99 96", mem);
	expect_dtl(c.dtl, 1999, 12, 31, 6, 23, 59, 59, 999000000);
	expect_encodes_to(&b, 0, "89 12 31 23 59 59 99 96");
	expect_encodes_to(&c, 0, "99 12 31 23 59 59 99 96");
}

fn void test_vt30_to_vt32_date_and_time_invalid() @test
{
	assert(dec_fault(DATE_AND_TIME, "25 1A 12 14 30 45 00 04") == INVALID_VALUE);   // VT30
	assert(dec_fault(DATE_AND_TIME, "25 00 12 14 30 45 00 04") == INVALID_VALUE);   // VT31
	assert(dec_fault(DATE_AND_TIME, "25 11 12 14 30 45 00 00") == INVALID_VALUE);   // VT32
	assert(dec_fault(DATE_AND_TIME, "9A 11 12 14 30 45 00 04") == INVALID_VALUE);
	assert(dec_fault(DATE_AND_TIME, "25 11 32 14 30 45 00 04") == INVALID_VALUE);
	assert(dec_fault(DATE_AND_TIME, "25 02 30 14 30 45 00 04") == INVALID_VALUE);
	assert(dec_fault(DATE_AND_TIME, "25 11 12 24 30 45 00 04") == INVALID_VALUE);
	assert(dec_fault(DATE_AND_TIME, "25 11 12 14 60 45 00 04") == INVALID_VALUE);
	assert(dec_fault(DATE_AND_TIME, "25 11 12 14 30 60 00 04") == INVALID_VALUE);
	assert(dec_fault(DATE_AND_TIME, "25 11 12 14 30 45 0A 04") == INVALID_VALUE);
}

// ---- VT33-VT37: DTL ----

fn void test_vt33_dtl() @test
{
	Value v = dec(DTL, "07 E9 0B 0C 04 0E 1E 2D 1D CD 65 00", mem);                 // VT33
	expect_dtl(v.dtl, 2025, 11, 12, 4, 14, 30, 45, 500000000);
	expect_encodes_to(&v, 0, "07 E9 0B 0C 04 0E 1E 2D 1D CD 65 00");
	Value w = dec(DTL, "07 E8 0B 0C 03 0D 2D 1E 07 5B CD 15", mem);
	expect_dtl(w.dtl, 2024, 11, 12, 3, 13, 45, 30, 123456789);
}

fn void test_vt34_to_vt37_dtl_limits() @test
{
	Value max = dec(DTL, "08 D6 0C 1F 06 17 3B 3B 3B 9A C9 FF", mem);               // VT34
	expect_dtl(max.dtl, 2262, 12, 31, 6, 23, 59, 59, 999999999);
	assert(dec_fault(DTL, "07 B1 01 01 05 00 00 00 00 00 00 00") == INVALID_VALUE);  // VT35
	assert(dec_fault(DTL, "07 E9 01 01 05 00 00 00 3B 9A CA 00") == INVALID_VALUE); // VT36
	assert(dec_fault(DTL, "07 E9 02 1E 01 00 00 00 00 00 00 00") == INVALID_VALUE);  // VT37
	assert(dec_fault(DTL, "08 D7 01 01 05 00 00 00 00 00 00 00") == INVALID_VALUE);  // year 2263
	assert(dec_fault(DTL, "07 E9 02 1D 01 00 00 00 00 00 00 00") == INVALID_VALUE);  // 2025 is not a leap year
	Value leap = dec(DTL, "07 E8 02 1D 05 00 00 00 00 00 00 00", mem);               // 2024-02-29
	expect_dtl(leap.dtl, 2024, 2, 29, 5, 0, 0, 0, 0);
	assert(dec_fault(DTL, "07 E9 01 01 00 00 00 00 00 00 00 00") == INVALID_VALUE);  // weekday 0
	assert(dec_fault(DTL, "07 E9 01 01 08 00 00 00 00 00 00 00") == INVALID_VALUE);  // weekday 8
	assert(dec_fault(DTL, "07 E9 01 01 05 18 00 00 00 00 00 00") == INVALID_VALUE);  // hour 24
}

// ---- VT38-VT40: S5TIME and BCD counters ----

fn void test_vt38_vt39_s5time() @test
{
	expect_u(S5TIME, "01 23", 1230);                     // VT38
	expect_u(S5TIME, "29 99", 999000);                   // VT39
	expect_u(S5TIME, "11 23", 12300);                    // base 100 ms
	expect_u(S5TIME, "31 23", 1230000);                  // base 10 s
	expect_u(S5TIME, "00 00", 0);
	assert(dec_fault(S5TIME, "01 2A") == INVALID_VALUE);
	assert(dec_fault(S5TIME, "0A 23") == INVALID_VALUE);
}

fn void test_vt40_counter() @test
{
	expect_u(COUNTER_BCD, "01 23", 123);                 // VT40
	expect_u(COUNTER_BCD, "09 99", 999);
	assert(dec_fault(COUNTER_BCD, "01 2A") == INVALID_VALUE);
}

// ---- sizes, short buffers, encode errors ----

fn void test_wire_sizes_and_short_buffers() @test
{
	assert(ValueKind.BOOL.wire_size() == 1 && ValueKind.BYTE.wire_size() == 1 && ValueKind.CHAR.wire_size() == 1);
	assert(ValueKind.WORD.wire_size() == 2 && ValueKind.INT.wire_size() == 2 && ValueKind.DATE.wire_size() == 2);
	assert(ValueKind.S5TIME.wire_size() == 2 && ValueKind.COUNTER_BCD.wire_size() == 2);
	assert(ValueKind.DWORD.wire_size() == 4 && ValueKind.DINT.wire_size() == 4 && ValueKind.REAL.wire_size() == 4);
	assert(ValueKind.TIME.wire_size() == 4 && ValueKind.TOD.wire_size() == 4);
	assert(ValueKind.LREAL.wire_size() == 8 && ValueKind.DATE_AND_TIME.wire_size() == 8 && ValueKind.DTL.wire_size() == 12);
	assert(ValueKind.STRING.wire_size() == 0 && ValueKind.WSTRING.wire_size() == 0);
	assert(dec_fault(WORD, "01") == VALUE_TOO_SHORT);
	assert(dec_fault(DWORD, "01 02 03") == VALUE_TOO_SHORT);
	assert(dec_fault(LREAL, "3F F0 00 00 00 00 00") == VALUE_TOO_SHORT);
	assert(dec_fault(DATE_AND_TIME, "25 11 12 14 30 45 00") == VALUE_TOO_SHORT);
	assert(dec_fault(DTL, "07 E9 0B 0C 04 0E 1E 2D 1D CD 65") == VALUE_TOO_SHORT);
	assert(dec_fault(BYTE, "") == VALUE_TOO_SHORT);
	expect_u(WORD, "12 34 56", 0x1234);   // extra bytes are ignored
}

fn void test_encode_range_errors() @test
{
	char[600] out;
	Value v = { .kind = INT, .i = 40000 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = INT, .i = -32769 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = BYTE, .u = 256 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = WORD, .u = 65536 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = DWORD, .u = 4294967296 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = DINT, .i = 2147483648 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = DATE, .u = 65379 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = TOD, .u = 86400000 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = COUNTER_BCD, .u = 1000 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = S5TIME, .u = 5 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = S5TIME, .u = 9990001 };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = CHAR, .str = "€" };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = CHAR, .str = "AB" };
	assert(@catch(encode_value(&v, out[..], 0)) == INVALID_VALUE);
	v = { .kind = STRING, .str = "abcdef" };
	assert(@catch(encode_value(&v, out[..], 5)) == INVALID_VALUE);
	v = { .kind = STRING, .str = "€" };
	assert(@catch(encode_value(&v, out[..], 5)) == INVALID_VALUE);
	v = { .kind = STRING, .str = "ab" };
	assert(@catch(encode_value(&v, out[..], 256)) == INVALID_VALUE);
	assert(@catch(encode_value(&v, out[:6], 5)) == BUFFER_TOO_SMALL);
	v = { .kind = WSTRING, .str = "abc" };
	assert(@catch(encode_value(&v, out[..], 2)) == INVALID_VALUE);
	assert(@catch(encode_value(&v, out[:9], 3)) == BUFFER_TOO_SMALL);
	v = { .kind = WORD, .u = 1 };
	assert(@catch(encode_value(&v, out[:1], 0)) == BUFFER_TOO_SMALL);
	// a string that is not valid UTF-8
	String bad = (String)(char[2]){ 0xC3, 0x28 }[..];
	v = { .kind = STRING, .str = bad };
	assert(@catch(encode_value(&v, out[..], 5)) == INVALID_VALUE);
}

fn void test_encode_s5time_picks_a_base() @test
{
	Value a = { .kind = S5TIME, .u = 1230 };
	expect_encodes_to(&a, 0, "01 23");
	Value b = { .kind = S5TIME, .u = 12300 };
	expect_encodes_to(&b, 0, "11 23");       // 12300 ms = 1230 * 10 ms does not fit 999, so base 100 ms: 123
	Value c = { .kind = S5TIME, .u = 999000 };
	expect_encodes_to(&c, 0, "29 99");
}

// ---- round trips with a deterministic PRNG ----

fn bool same_value(Value a, Value b)
{
	if (a.kind != b.kind) return false;
	switch (a.kind)
	{
		case BOOL:
			return a.b == b.b;
		case BYTE:
		case WORD:
		case DWORD:
		case DATE:
		case TOD:
		case S5TIME:
		case COUNTER_BCD:
			return a.u == b.u;
		case INT:
		case DINT:
		case TIME:
			return a.i == b.i;
		case REAL:
		case LREAL:
			return a.f == b.f;
		case CHAR:
		case STRING:
		case WSTRING:
			return a.str == b.str;
		default:
			return a.dtl.year == b.dtl.year && a.dtl.month == b.dtl.month && a.dtl.day == b.dtl.day
				&& a.dtl.weekday == b.dtl.weekday && a.dtl.hour == b.dtl.hour && a.dtl.minute == b.dtl.minute
				&& a.dtl.second == b.dtl.second && a.dtl.nanosecond == b.dtl.nanosecond;
	}
}

// A random string of code points in [lo, hi] (astral planes when `astral`), allocated from tmem.
fn String random_text(Rng* rng, usz max_chars, uint hi, bool astral)
{
	char[256] buf;
	usz at = 0;
	usz n = rng.below(max_chars + 1);
	for (usz i = 0; i < n; i++)
	{
		uint cp = (uint)rng.below((usz)hi + 1);
		if (astral && rng.below(4) == 0) cp = 0x10000 + (uint)rng.below(0x1000);
		if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0x41;
		at = put_utf8(buf[..], at, cp);
	}
	return ((String)buf[:at]).copy(tmem);
}

fn Value random_value(Rng* rng, ValueKind kind, uint* max_len)
{
	Value v = { .kind = kind };
	*max_len = 254;
	switch (kind)
	{
		case BOOL:
			v.b = rng.below(2) == 1;
		case BYTE:
			v.u = rng.below(256);
		case WORD:
			v.u = rng.below(65536);
		case DWORD:
			v.u = rng.next() & 0xFFFFFFFF;
		case INT:
			v.i = (long)rng.below(65536) - 32768;
		case DINT:
		case TIME:
			v.i = (long)(int)(rng.next() & 0xFFFFFFFF);
		case REAL:
			uint bits = (uint)(rng.next() & 0xFFFFFFFF);
			if ((bits & 0x7F800000) == 0x7F800000) bits &= 0x007FFFFF;
			v.f = bitcast(bits, float);
		case LREAL:
			ulong bits = rng.next();
			if ((bits & 0x7FF0000000000000) == 0x7FF0000000000000) bits &= 0x000FFFFFFFFFFFFF;
			v.f = bitcast(bits, double);
		case CHAR:
			char[4] c;
			usz n = put_utf8(c[..], 0, (uint)rng.below(256));
			v.str = ((String)c[:n]).copy(tmem);
		case STRING:
			v.str = random_text(rng, 20, 0xFF, false);
			*max_len = 20 + (uint)rng.below(5);
		case WSTRING:
			v.str = random_text(rng, 15, 0xFFFF, true);
			*max_len = 40;
		case DATE:
			v.u = rng.below(MAX_DATE_DAYS + 1);
		case TOD:
			v.u = rng.below(MS_PER_DAY);
		case S5TIME:
			v.u = (ulong)rng.below(1000) * S5_BASE_MS[rng.below(4)];
		case COUNTER_BCD:
			v.u = rng.below(1000);
		case DATE_AND_TIME:
			uint year = 1990 + (uint)rng.below(100);
			uint month = 1 + (uint)rng.below(12);
			v.dtl = {
				.year = (ushort)year, .month = (char)month, .day = (char)(1 + rng.below(days_in_month(year, month))),
				.weekday = (char)(1 + rng.below(7)), .hour = (char)rng.below(24), .minute = (char)rng.below(60),
				.second = (char)rng.below(60), .nanosecond = (uint)rng.below(1000) * 1000000
			};
		case DTL:
			uint year = MIN_DTL_YEAR + (uint)rng.below(MAX_DTL_YEAR - MIN_DTL_YEAR + 1);
			uint month = 1 + (uint)rng.below(12);
			v.dtl = {
				.year = (ushort)year, .month = (char)month, .day = (char)(1 + rng.below(days_in_month(year, month))),
				.weekday = (char)(1 + rng.below(7)), .hour = (char)rng.below(24), .minute = (char)rng.below(60),
				.second = (char)rng.below(60), .nanosecond = (uint)rng.below(1000000000)
			};
	}
	return v;
}

fn void test_round_trip_every_kind() @test
{
	ValueKind[] kinds = { BOOL, BYTE, WORD, DWORD, INT, DINT, REAL, LREAL, CHAR, STRING, WSTRING, DATE, TIME, TOD, DATE_AND_TIME, DTL, S5TIME, COUNTER_BCD };
	Rng rng = { 0x2545F4914F6CDD1D };
	TrackingAllocator t;
	t.init(mem);
	foreach (kind : kinds)
	{
		for (int n = 0; n < 1000; n++)
		{
			@pool()
			{
				uint max_len;
				Value v = random_value(&rng, kind, &max_len);
				char[600] out;
				usz len = encode_value(&v, out[..], max_len)!!;
				Value d = decode_value(kind, out[:len], &t)!!;
				assert(same_value(v, d), "round trip of kind %d", (int)kind);
				// encoding the decoded value gives the same bytes
				char[600] again;
				usz len2 = encode_value(&d, again[..], max_len)!!;
				assert(len2 == len && same_bytes(out[:len], again[:len2]));
				d.free(&t);
			};
		}
	}
	assert(!t.has_leaks());
	t.free();
}

// ---- parse_value ----

fn void test_parse_value_numbers_and_bool() @test
{
	assert(parse_value(BOOL, "true", mem)!!.b);
	assert(parse_value(BOOL, "TRUE", mem)!!.b);
	assert(parse_value(BOOL, "1", mem)!!.b);
	assert(!parse_value(BOOL, "false", mem)!!.b);
	assert(!parse_value(BOOL, "0", mem)!!.b);
	assert(@catch(parse_value(BOOL, "yes", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(BOOL, "", mem)) == INVALID_VALUE);

	assert(parse_value(BYTE, "255", mem)!!.u == 255);
	assert(parse_value(BYTE, "0xFF", mem)!!.u == 255);
	assert(@catch(parse_value(BYTE, "256", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(BYTE, "-1", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(BYTE, "+1", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(BYTE, " 1", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(BYTE, "0x", mem)) == INVALID_VALUE);
	assert(parse_value(WORD, "65535", mem)!!.u == 65535);
	assert(@catch(parse_value(WORD, "65536", mem)) == INVALID_VALUE);
	assert(parse_value(DWORD, "4294967295", mem)!!.u == 4294967295);
	assert(@catch(parse_value(DWORD, "4294967296", mem)) == INVALID_VALUE);

	assert(parse_value(INT, "-32768", mem)!!.i == -32768);
	assert(parse_value(INT, "+7", mem)!!.i == 7);
	assert(@catch(parse_value(INT, "32768", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(INT, "12a", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(INT, "-", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(INT, "99999999999999999999", mem)) == INVALID_VALUE);
	assert(parse_value(DINT, "-2147483648", mem)!!.i == -2147483648);
	assert(@catch(parse_value(DINT, "2147483648", mem)) == INVALID_VALUE);

	assert(parse_value(REAL, "1.5", mem)!!.f == 1.5);
	assert(parse_value(REAL, "-2e3", mem)!!.f == -2000.0);
	assert(parse_value(LREAL, "3.141592653589793", mem)!!.f == 3.141592653589793);
	assert(@catch(parse_value(REAL, "abc", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(REAL, "nan", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(REAL, "inf", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(REAL, "", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(REAL, ".", mem)) == INVALID_VALUE);
}

fn void test_parse_value_text() @test
{
	TrackingAllocator t;
	t.init(mem);
	Value a = parse_value(STRING, "'abc'", &t)!!;
	assert(a.str == "abc");
	a.free(&t);
	Value b = parse_value(STRING, "\"abc\"", &t)!!;
	assert(b.str == "abc");
	b.free(&t);
	Value e = parse_value(STRING, "''", &t)!!;
	assert(e.str == "");
	e.free(&t);
	Value c = parse_value(CHAR, "'A'", &t)!!;
	assert(c.str == "A");
	c.free(&t);
	Value w = parse_value(WSTRING, "'€'", &t)!!;
	assert(w.str == "€");
	w.free(&t);
	assert(@catch(parse_value(STRING, "abc", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(STRING, "'abc", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(STRING, "'abc\"", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(STRING, "'", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(CHAR, "'AB'", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(CHAR, "''", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(CHAR, "'€'", &t)) == INVALID_VALUE);
	assert(@catch(parse_value(STRING, "'€'", &t)) == INVALID_VALUE);
	char[300] long_text;
	long_text[..] = 'a';
	long_text[0] = '\'';
	long_text[299] = '\'';
	assert(@catch(parse_value(STRING, (String)long_text[..], &t)) == INVALID_VALUE);
	assert(!t.has_leaks());
	t.free();
}

fn void test_parse_value_time_kinds() @test
{
	assert(parse_value(DATE, "100", mem)!!.u == 100);
	assert(@catch(parse_value(DATE, "65379", mem)) == INVALID_VALUE);
	assert(parse_value(TIME, "-1000", mem)!!.i == -1000);
	assert(@catch(parse_value(TIME, "2147483648", mem)) == INVALID_VALUE);
	assert(parse_value(TOD, "1000", mem)!!.u == 1000);
	assert(@catch(parse_value(TOD, "86400000", mem)) == INVALID_VALUE);
	assert(parse_value(S5TIME, "1230", mem)!!.u == 1230);
	assert(@catch(parse_value(S5TIME, "1234", mem)) == INVALID_VALUE);
	assert(parse_value(COUNTER_BCD, "999", mem)!!.u == 999);
	assert(@catch(parse_value(COUNTER_BCD, "1000", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(DTL, "2024-11-12", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(DATE_AND_TIME, "2024-11-12", mem)) == INVALID_VALUE);
}

fn void test_signalling_nan_survives_a_read_and_write_back() @test
{
	// 7F A0 00 01 is a signalling NaN; converting it through a double would quiet it
	Value v = dec(REAL, "7F A0 00 01", mem);
	assert(v.f != v.f);
	expect_encodes_to(&v, 0, "7F A0 00 01");
	Value neg = dec(REAL, "FF A0 00 01", mem);
	expect_encodes_to(&neg, 0, "FF A0 00 01");
	// a caller who assigns a new number gets that number, not the decoded bits
	v.f = 2.0;
	expect_encodes_to(&v, 0, "40 00 00 00");
	Value d = dec(LREAL, "7F F4 00 00 00 00 00 01", mem);
	expect_encodes_to(&d, 0, "7F F4 00 00 00 00 00 01");
}

fn void test_integer_literals_that_overflow_are_rejected() @test
{
	// 2^64 wraps to 0 in 64 bit arithmetic and must not turn into a valid value
	assert(@catch(parse_value(BYTE, "18446744073709551616", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(DWORD, "18446744073709551616", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(DWORD, "18446744073709551617", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(WORD, "36893488147419103232", mem)) == INVALID_VALUE);   // 2^65
	assert(@catch(parse_value(INT, "18446744073709551616", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(INT, "-18446744073709551616", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(DINT, "9223372036854775808", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(BYTE, "0x10000000000000000", mem)) == INVALID_VALUE);    // 2^64 in hex
	assert(@catch(parse_value(DWORD, "0x10000000000000001", mem)) == INVALID_VALUE);
	assert(@catch(parse_value(DWORD, "0xFFFFFFFFFFFFFFFFFF", mem)) == INVALID_VALUE);
	assert(parse_value(DWORD, "0xFFFFFFFF", mem)!!.u == 4294967295);
	assert(parse_value(DINT, "-2147483648", mem)!!.i == -2147483648);
}

fn void test_strings_need_their_declared_capacity() @test
{
	// the header declares 12 bytes (max 10), only 4 are there
	assert(dec_fault(STRING, "0A 02 41 42") == VALUE_TOO_SHORT);
	assert(dec_fault(STRING, "0A 00") == VALUE_TOO_SHORT);
	assert(dec_fault(STRING, "0A 02 41 42 00 00 00 00 00 00 00") == VALUE_TOO_SHORT);   // one byte missing
	Value ok = dec(STRING, "0A 02 41 42 00 00 00 00 00 00 00 00", mem);
	assert(ok.str == "AB");
	ok.free(mem);
	// WSTRING max 5 declares 4 + 10 bytes
	assert(dec_fault(WSTRING, "00 05 00 00") == VALUE_TOO_SHORT);
	assert(dec_fault(WSTRING, "00 05 00 02 00 41 00 42") == VALUE_TOO_SHORT);
	assert(dec_fault(WSTRING, "00 05 00 02 00 41 00 42 00 00 00 00 00") == VALUE_TOO_SHORT);   // one byte missing
	Value w = dec(WSTRING, "00 05 00 02 00 41 00 42 00 00 00 00 00 00", mem);
	assert(w.str == "AB");
	w.free(mem);
}

fn void test_wstring_capacity_is_limited_to_16382_characters() @test
{
	// declared capacity 16383 and 65535 are refused outright, 16382 only lacks its data
	assert(dec_fault(WSTRING, "3F FF 00 00") == INVALID_VALUE);
	assert(dec_fault(WSTRING, "FF FF 00 00") == INVALID_VALUE);
	assert(dec_fault(WSTRING, "3F FE 00 00") == VALUE_TOO_SHORT);
	char[600] out;
	Value v = { .kind = WSTRING, .str = "ab" };
	assert(@catch(encode_value(&v, out[..], 16383)) == INVALID_VALUE);
	assert(@catch(encode_value(&v, out[..], 65535)) == INVALID_VALUE);
	assert(@catch(encode_value(&v, out[..], 16382)) == BUFFER_TOO_SMALL);
	// a full-size buffer is accepted
	char[] big = mem::new_array(char, 4 + 2 * 16382);
	defer mem::free(big.ptr);
	assert(encode_value(&v, big, 16382)!! == 4 + 2 * 16382);
	Value back = decode_value(WSTRING, big, mem)!!;
	assert(back.str == "ab");
	back.free(mem);
}
