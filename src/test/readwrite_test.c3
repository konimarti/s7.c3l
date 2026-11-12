module s7;

// Tests for the Read Var / Write Var codec (plan.c3). V* and M* are the IDs of the independent test vector set.

fn S7Header header_of(Fixture* f)
{
	CotpPdu p = decode_cotp(f.bytes())!!;
	return decode_s7_header(p.payload)!!;
}

// Request frame of the first PDU of a plan must equal the fixture.
fn void expect_read_request(Address[] items, ushort pdu_ref, String fixture)
{
	Plan plan = plan_read(items, 480, 20, 1 << 20, mem)!!;
	assert(plan.pdus.len == 1);
	char[600] out;
	usz n = encode_read_request(pdu_ref, items, &plan.pdus[0], out[..])!!;
	Fixture want = fx(fixture);
	assert(same_bytes(out[:n], want.bytes()), "read request %s", fixture);
	plan.free();
}

fn void expect_write_request(Address[] items, char[][] data, ushort pdu_ref, String fixture)
{
	Plan plan = plan_write(items, 480, 20, 1 << 20, mem)!!;
	assert(plan.pdus.len == 1);
	char[600] out;
	usz n = encode_write_request(pdu_ref, items, data, &plan.pdus[0], out[..])!!;
	Fixture want = fx(fixture);
	assert(same_bytes(out[:n], want.bytes()), "write request %s", fixture);
	plan.free();
}

// Decodes a read response against the plan of `items`; results are returned in `results`.
fn void? read_results(Address[] items, Fixture* response, ItemResult[] results)
{
	Plan plan = plan_read(items, 480, 20, 1 << 20, mem)!;
	defer plan.free();
	S7Header h = header_of(response);
	return decode_read_response(&h, &plan.pdus[0], results);
}

fn fault read_fault(Address[] items, String hex)
{
	Fixture f = fx(hex);
	ItemResult[8] results;
	return @catch(read_results(items, &f, results[..]));
}

// A frame (TPKT, DT) around an S7 payload given as hex: the lengths are computed, not typed.
fn Fixture s7_frame(String payload_hex)
{
	Fixture payload = fx(payload_hex);
	Fixture f;
	usz total = 7 + payload.len;
	f.buf[0] = 3;
	f.buf[2] = (char)(total >> 8);
	f.buf[3] = (char)total;
	f.buf[4] = 2;
	f.buf[5] = 0xF0;
	f.buf[6] = 0x80;
	f.buf[7:payload.len] = payload.bytes()[..];
	f.len = total;
	return f;
}

fn fault read_fault_payload(Address[] items, String payload_hex)
{
	Fixture f = s7_frame(payload_hex);
	ItemResult[8] results;
	return @catch(read_results(items, &f, results[..]));
}

fn void expect_data(ItemResult r, String hex)
{
	assert(!r.status && r.raw_code == 0xFF);
	Fixture want = fx(hex);
	assert(same_bytes(r.data, want.bytes()), "data %s", hex);
}

// ---- return codes ----

fn void test_rc_to_fault_map() @test
{
	assert(rc_to_fault(0x01) == HARDWARE_FAULT);
	assert(rc_to_fault(0x03) == ACCESS_DENIED);
	assert(rc_to_fault(0x05) == ADDRESS_OUT_OF_RANGE);
	assert(rc_to_fault(0x06) == DATA_TYPE_UNSUPPORTED);
	assert(rc_to_fault(0x07) == TYPE_MISMATCH);
	assert(rc_to_fault(0x0A) == OBJECT_DOES_NOT_EXIST);
	assert(rc_to_fault(0x77) == UNKNOWN_RETURN_CODE);
	assert(rc_to_fault(0x00) == UNKNOWN_RETURN_CODE);
	assert(rc_to_fault(0x02) == UNKNOWN_RETURN_CODE);
}

// ---- read requests: V20, V22, V24, V26, V28, V29 ----

fn void test_read_request_frames() @test
{
	Address[1] v20 = { addr("DB1.DBW2") };
	expect_read_request(v20[..], 2, FX_V20);
	Address[1] v22 = { addr("DB1.DBX0.3") };
	expect_read_request(v22[..], 3, FX_V22);
	Address[1] v24 = { addr("MD20") };
	expect_read_request(v24[..], 4, FX_V24);
	Address[1] v26 = { addr("T5") };
	expect_read_request(v26[..], 5, FX_V26);
	Address[1] v28 = { addr("C3") };
	expect_read_request(v28[..], 6, FX_V28);
	Address[2] v29 = { addr("DB1.DBB0:3"), addr("DB1.DBB10:2") };
	expect_read_request(v29[..], 7, FX_V29);
}

fn void test_read_request_sends_words_as_bytes() @test
{
	// DB1.DBW2 goes out as BYTE with count 2, never as WORD (V20); a word range counts bytes too
	Address[1] w = { addr("DB1.DBW4:3") };
	Plan plan = plan_read(w[..], 480, 20, 1 << 20, mem)!!;
	char[64] out;
	usz n = encode_read_request(1, w[..], &plan.pdus[0], out[..])!!;
	assert(n == 31 && out[22] == 0x02 && out[23] == 0 && out[24] == 6);
	plan.free();
}

fn void test_read_request_encode_errors() @test
{
	Address[1] v20 = { addr("DB1.DBW2") };
	Plan plan = plan_read(v20[..], 480, 20, 1 << 20, mem)!!;
	char[64] out;
	assert(@catch(encode_read_request(2, v20[..], &plan.pdus[0], out[:30])) == BUFFER_TOO_SMALL);
	Pdu empty;
	assert(@catch(encode_read_request(2, v20[..], &empty, out[..])) == INVALID_ARGUMENT);
	Slice[1] stray = { { 5, 0, 1 } };
	Pdu bad = { stray[..] };
	assert(@catch(encode_read_request(2, v20[..], &bad, out[..])) == INVALID_ARGUMENT);
	plan.free();
}

// ---- read responses: V21, V23, V25, V27, V30, V31, V32-V37 ----

fn void test_read_responses_ok() @test
{
	ItemResult[4] r;
	Address[1] v20 = { addr("DB1.DBW2") };
	Fixture v21 = fx(FX_V21);
	read_results(v20[..], &v21, r[..])!!;
	expect_data(r[0], "12 34");
	Address[1] v22 = { addr("DB1.DBX0.3") };
	Fixture v23 = fx(FX_V23);
	read_results(v22[..], &v23, r[..])!!;
	expect_data(r[0], "01");
	Address[1] v24 = { addr("MD20") };
	Fixture v25 = fx(FX_V25);
	read_results(v24[..], &v25, r[..])!!;
	expect_data(r[0], "40 49 0F DB");
	Address[1] v26 = { addr("T5") };
	Fixture v27 = fx(FX_V27);
	read_results(v26[..], &v27, r[..])!!;
	expect_data(r[0], "01 23");
}

fn void test_v30_pad_byte_after_odd_item() @test
{
	Address[2] v29 = { addr("DB1.DBB0:3"), addr("DB1.DBB10:2") };
	Fixture f = fx(FX_V30);
	ItemResult[4] r;
	read_results(v29[..], &f, r[..])!!;
	expect_data(r[0], "0A 0B 0C");
	expect_data(r[1], "0D 0E");
}

fn void test_v31_one_item_fails_the_other_is_kept() @test
{
	Address[2] v29 = { addr("DB1.DBB0:3"), addr("DB1.DBB10:2") };
	Fixture f = fx(FX_V31);
	ItemResult[4] r;
	read_results(v29[..], &f, r[..])!!;
	expect_data(r[0], "0A 0B 0C");
	assert(r[1].status == OBJECT_DOES_NOT_EXIST && r[1].raw_code == 0x0A && r[1].data.len == 0);
}

fn void expect_item_fault(String hex, fault want, char raw)
{
	Address[1] v20 = { addr("DB1.DBW2") };
	Fixture f = fx(hex);
	ItemResult[4] r;
	read_results(v20[..], &f, r[..])!!;
	assert(r[0].status == want && r[0].raw_code == raw && r[0].data.len == 0, "item fault of %s", hex);
}

fn void test_v32_to_v37_return_codes() @test
{
	expect_item_fault(FX_V32, ACCESS_DENIED, 0x03);
	expect_item_fault(FX_V33, ADDRESS_OUT_OF_RANGE, 0x05);
	expect_item_fault(FX_V34, DATA_TYPE_UNSUPPORTED, 0x06);
	expect_item_fault(FX_V35, TYPE_MISMATCH, 0x07);
	expect_item_fault(FX_V36, OBJECT_DOES_NOT_EXIST, 0x0A);
	expect_item_fault(FX_V37, HARDWARE_FAULT, 0x01);
	expect_item_fault("03 00 00 19 02 F0 80 32 03 00 00 00 02 00 02 00 04 00 00 04 01 77 00 00 00", UNKNOWN_RETURN_CODE, 0x77);
}

fn void test_header_errors_in_read_responses() @test
{
	Address[1] v20 = { addr("DB1.DBW2") };
	// Ack_Data with error class 0x81 code 0x04
	assert(read_fault(v20[..], "03 00 00 19 02 F0 80 32 03 00 00 00 02 00 02 00 04 81 04 04 01 03 00 00 00") == S7_ERROR);
	// plain Ack: with an error class and code it is S7_ERROR, without it there is nothing to read
	assert(read_fault(v20[..], "03 00 00 13 02 F0 80 32 02 00 00 00 02 00 00 00 00 81 04") == S7_ERROR);
	assert(read_fault(v20[..], "03 00 00 13 02 F0 80 32 02 00 00 00 02 00 00 00 00 00 00") == BAD_RESPONSE);
	// a Job where an answer was expected
	assert(read_fault(v20[..], FX_V20) == BAD_RESPONSE);
}

// ---- read responses: malformed ----

fn void test_m19_m20_data_length_does_not_match() @test
{
	Address[1] v20 = { addr("DB1.DBW2") };
	assert(read_fault(v20[..], FX_M19) == BAD_RESPONSE);     // M19: 0x0100 bits claim 32 bytes
	assert(read_fault(v20[..], FX_M20) == BAD_RESPONSE);     // M20: 0xFFFF bits
}

fn void test_m21_m22_item_count_mismatch() @test
{
	Address[2] v29 = { addr("DB1.DBB0:3"), addr("DB1.DBB10:2") };
	assert(read_fault(v29[..], FX_M21) == BAD_RESPONSE);     // M21: response says 1 item, 2 requested
	Address[1] v20 = { addr("DB1.DBW2") };
	assert(read_fault(v20[..], FX_M22) == BAD_RESPONSE);     // M22: response says 3 items, 1 requested
}

fn void test_m23_wrong_function_code() @test
{
	Address[1] v20 = { addr("DB1.DBW2") };
	assert(read_fault(v20[..], FX_M23) == BAD_RESPONSE);
}

fn void test_m25_m26_m43_bad_item_lengths() @test
{
	Address[1] bit = { addr("DB1.DBX0.3") };
	assert(read_fault(bit[..], FX_M25) == BAD_RESPONSE);     // M25: BIT item of 9 bits
	Address[1] v20 = { addr("DB1.DBW2") };
	assert(read_fault(v20[..], FX_M26) == BAD_RESPONSE);     // M26: 12 bits for transport size 0x04
	assert(read_fault(v20[..], FX_M43) == BAD_RESPONSE);     // M43: success with transport size 0 and length 0
}

fn void test_read_response_structure_errors() @test
{
	Address[2] v29 = { addr("DB1.DBB0:3"), addr("DB1.DBB10:2") };
	// odd first item without its pad byte
	assert(read_fault_payload(v29[..], "32 03 00 00 00 07 00 02 00 0D 00 00 04 02 FF 04 00 18 0A 0B 0C FF 04 00 10 0D 0E") == BAD_RESPONSE);
	// one byte too many after the last item
	assert(read_fault_payload(v29[..], "32 03 00 00 00 07 00 02 00 0F 00 00 04 02 FF 04 00 18 0A 0B 0C 00 FF 04 00 10 0D 0E 00") == BAD_RESPONSE);
	// second item missing
	assert(read_fault_payload(v29[..], "32 03 00 00 00 07 00 02 00 08 00 00 04 02 FF 04 00 18 0A 0B 0C 00") == BAD_RESPONSE);
	// data cut inside an item header
	assert(read_fault_payload(v29[..], "32 03 00 00 00 07 00 02 00 03 00 00 04 02 FF 04 00") == BAD_RESPONSE);
	// unknown data transport size
	Address[1] v20 = { addr("DB1.DBW2") };
	assert(read_fault_payload(v20[..], "32 03 00 00 00 02 00 02 00 06 00 00 04 01 FF 0B 00 10 12 34") == BAD_RESPONSE);
	// parameter longer than function code and count
	assert(read_fault_payload(v20[..], "32 03 00 00 00 02 00 03 00 06 00 00 04 01 00 FF 04 00 10 12 34") == BAD_RESPONSE);
}

fn void test_read_response_arguments() @test
{
	Address[1] v20 = { addr("DB1.DBW2") };
	Plan plan = plan_read(v20[..], 480, 20, 1 << 20, mem)!!;
	Fixture f = fx(FX_V21);
	S7Header h = header_of(&f);
	ItemResult[1] one;
	ItemResult[1] none;
	assert(@catch(decode_read_response(null, &plan.pdus[0], one[..])) == INVALID_ARGUMENT);
	assert(@catch(decode_read_response(&h, null, one[..])) == INVALID_ARGUMENT);
	assert(@catch(decode_read_response(&h, &plan.pdus[0], none[:0])) == BUFFER_TOO_SMALL);
	assert(@ok(decode_read_response(&h, &plan.pdus[0], one[..])));
	plan.free();
}

// ---- write requests: V40, V42, V43 ----

fn void test_write_request_frames() @test
{
	Address[1] v40 = { addr("DB1.DBW2") };
	char[2] d40 = { 0x12, 0x34 };
	char[][1] data40 = { d40[..] };
	expect_write_request(v40[..], data40[..], 3, FX_V40);

	Address[1] v42 = { addr("DB1.DBX0.3") };
	char[1] d42 = { 0x01 };
	char[][1] data42 = { d42[..] };
	expect_write_request(v42[..], data42[..], 4, FX_V42);

	Address[2] v43 = { addr("DB1.DBB0"), addr("DB1.DBB4:2") };
	char[1] a = { 0xAA };
	char[2] b = { 0xBB, 0xCC };
	char[][2] data43 = { a[..], b[..] };
	expect_write_request(v43[..], data43[..], 5, FX_V43);
}

fn void test_write_request_timer_and_chunks() @test
{
	// timers go out as octet strings (transport size 0x09, length in bytes)
	Address[1] t = { addr("T5") };
	char[2] tv = { 0x01, 0x23 };
	char[][1] tdata = { tv[..] };
	Plan plan = plan_write(t[..], 480, 20, 1 << 20, mem)!!;
	char[64] out;
	usz n = encode_write_request(1, t[..], tdata[..], &plan.pdus[0], out[..])!!;
	Fixture want = fx("03 00 00 25 02 F0 80 32 01 00 00 00 01 00 0E 00 06 05 01 12 0A 10 1D 00 01 00 00 1D 00 00 05 00 09 00 02 01 23");
	assert(same_bytes(out[:n], want.bytes()));
	plan.free();

	// the second chunk of a large write starts at the right offset and carries the right data
	Address[1] big = { addr("DB1.DBB10:300") };
	char[300] payload;
	for (usz i = 0; i < 300; i++) payload[i] = (char)i;
	char[][1] bdata = { payload[..] };
	Plan chunks = plan_write(big[..], 240, 20, 1 << 20, mem)!!;
	assert(chunks.pdus.len == 2);
	char[300] frame;
	usz m = encode_write_request(9, big[..], bdata[..], &chunks.pdus[1], frame[..])!!;
	// item: byte offset 10 + 212 = 222 -> bit address 1776 = 0x0006F0, length 88
	Fixture item = fx("12 0A 10 02 00 58 00 01 84 00 06 F0");
	assert(same_bytes(frame[19:12], item.bytes()));
	assert(frame[31] == 0x00 && frame[32] == 0x04 && frame[33] == 0x02 && frame[34] == 0xC0);   // 88 * 8 = 704 = 0x02C0
	assert(frame[35] == 212 && frame[35 + 87] == (char)299);
	assert(m == 35 + 88);
	chunks.free();
}

fn void test_write_request_encode_errors() @test
{
	Address[1] w = { addr("DB1.DBW2") };
	Plan plan = plan_write(w[..], 480, 20, 1 << 20, mem)!!;
	char[64] out;
	char[2] two = { 1, 2 };
	char[1] one = { 1 };
	char[][1] good = { two[..] };
	char[][1] short_data = { one[..] };
	assert(@catch(encode_write_request(1, w[..], short_data[..], &plan.pdus[0], out[..])) == INVALID_ARGUMENT);
	assert(@catch(encode_write_request(1, w[..], good[:0], &plan.pdus[0], out[..])) == INVALID_ARGUMENT);
	assert(@catch(encode_write_request(1, w[..], good[..], &plan.pdus[0], out[:36])) == BUFFER_TOO_SMALL);
	assert(@ok(encode_write_request(1, w[..], good[..], &plan.pdus[0], out[..])));
	plan.free();

	Address[1] bit = { addr("DB1.DBX0.3") };
	Plan bp = plan_write(bit[..], 480, 20, 1 << 20, mem)!!;
	char[1] two_value = { 2 };
	char[][1] bad_bit = { two_value[..] };
	assert(@catch(encode_write_request(1, bit[..], bad_bit[..], &bp.pdus[0], out[..])) == INVALID_ARGUMENT);
	bp.free();
}

// ---- write responses: V41, V44, M27, M28 ----

fn fault write_fault(Address[] items, String hex, ItemResult[] results)
{
	Plan plan = plan_write(items, 480, 20, 1 << 20, mem)!!;
	defer plan.free();
	Fixture f = fx(hex);
	S7Header h = header_of(&f);
	return @catch(decode_write_response(&h, &plan.pdus[0], results));
}

fn void test_v41_v44_write_responses() @test
{
	ItemResult[4] r;
	Address[1] one = { addr("DB1.DBW2") };
	assert(!write_fault(one[..], FX_V41, r[..]));
	assert(!r[0].status && r[0].raw_code == 0xFF);
	Address[2] two = { addr("DB1.DBB0"), addr("DB1.DBB4:2") };
	assert(!write_fault(two[..], FX_V44, r[..]));
	assert(!r[0].status);
	assert(r[1].status == ACCESS_DENIED && r[1].raw_code == 0x03);
}

fn void test_m27_m28_write_response_counts() @test
{
	ItemResult[4] r;
	Address[1] one = { addr("DB1.DBW2") };
	assert(write_fault(one[..], FX_M27, r[..]) == BAD_RESPONSE);     // M27: no return code
	assert(write_fault(one[..], FX_M28, r[..]) == BAD_RESPONSE);     // M28: two return codes
}

fn void test_write_response_errors() @test
{
	ItemResult[4] r;
	Address[1] one = { addr("DB1.DBW2") };
	// a read response where a write response is expected
	assert(write_fault(one[..], FX_V21, r[..]) == BAD_RESPONSE);
	// header error
	assert(write_fault(one[..], "03 00 00 16 02 F0 80 32 03 00 00 00 03 00 02 00 01 85 00 05 01 FF", r[..]) == S7_ERROR);
	// results too small
	ItemResult[1] tiny;
	Address[2] two = { addr("DB1.DBB0"), addr("DB1.DBB4:2") };
	assert(write_fault(two[..], FX_V44, tiny[..]) == BUFFER_TOO_SMALL);
	// codes of the other kinds
	assert(!write_fault(one[..], "03 00 00 16 02 F0 80 32 03 00 00 00 03 00 02 00 01 00 00 05 01 0A", r[..]));
	assert(r[0].status == OBJECT_DOES_NOT_EXIST);
}

fn void test_bit_responses_must_be_exactly_one_bit() @test
{
	Address[1] bit = { addr("DB1.DBX0.3") };
	// transport size 0x03 with a length of 0, 2, 8 or 9 bits is not the single bit that was asked for
	assert(read_fault_payload(bit[..], "32 03 00 00 00 02 00 02 00 05 00 00 04 01 FF 03 00 00 01") == BAD_RESPONSE);
	assert(read_fault_payload(bit[..], "32 03 00 00 00 02 00 02 00 05 00 00 04 01 FF 03 00 02 01") == BAD_RESPONSE);
	assert(read_fault_payload(bit[..], "32 03 00 00 00 02 00 02 00 05 00 00 04 01 FF 03 00 08 01") == BAD_RESPONSE);
	assert(read_fault_payload(bit[..], "32 03 00 00 00 02 00 02 00 05 00 00 04 01 FF 03 00 09 01") == BAD_RESPONSE);
	// the single bit is fine
	Fixture ok = s7_frame("32 03 00 00 00 02 00 02 00 05 00 00 04 01 FF 03 00 01 01");
	ItemResult[2] r;
	read_results(bit[..], &ok, r[..])!!;
	expect_data(r[0], "01");
}
