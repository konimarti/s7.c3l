module s7;

// Tests for wire.c3. Fixture names FX_V* / FX_M* are the IDs of the independent test vector set.

fn bool tsap_is(Tsap t, ushort v) => t.len == 2 && t.bytes[0] == (char)(v >> 8) && t.bytes[1] == (char)v;

fn S7Header? s7_of(Fixture* f)
{
	CotpPdu p = decode_cotp(f.bytes())!;
	return decode_s7_header(p.payload);
}

// Encoding a Connection Request must equal the fixture byte for byte.
fn void expect_cr(Tsaps t, ushort src_ref, String fixture)
{
	char[64] out;
	usz n = encode_cr(t, src_ref, out[..])!!;
	Fixture want = fx(fixture);
	assert(same_bytes(out[:n], want.bytes()));
}

// ---- helpers and TSAPs ----

fn void test_be_helpers() @test
{
	char[8] b;
	put_be16(b[..], 1, 0x1234)!!;
	put_be32(b[..], 3, 0xDEADBEEF)!!;
	assert(b[1] == 0x12 && b[2] == 0x34);
	assert(get_be16(b[..], 1)!! == 0x1234);
	assert(get_be32(b[..], 3)!! == 0xDEADBEEF);
	assert(@catch(get_be16(b[..], 7)) == TRUNCATED);
	assert(@catch(get_be32(b[..], 5)) == TRUNCATED);
	assert(@catch(put_be16(b[..], 7, 1)) == BUFFER_TOO_SMALL);
	assert(@catch(put_be32(b[..], 5, 1)) == BUFFER_TOO_SMALL);
}

fn void test_tsaps_from_rack_slot() @test
{
	Tsaps a = tsaps_from_rack_slot(PG, 0, 2)!!;
	assert(tsap_is(a.local, 0x0100) && tsap_is(a.remote, 0x0102));
	Tsaps b = tsaps_from_rack_slot(BASIC, 1, 2)!!;
	assert(tsap_is(b.remote, 0x0322));
	Tsaps c = tsaps_from_rack_slot(OP, 7, 31)!!;
	assert(tsap_is(c.remote, 0x02FF));
	assert(@catch(tsaps_from_rack_slot(PG, 8, 0)) == INVALID_ARGUMENT);
	assert(@catch(tsaps_from_rack_slot(PG, 0, 32)) == INVALID_ARGUMENT);
}

fn void test_tsap_from_bytes() @test
{
	char[3] three = { 0x12, 0x34, 0x56 };
	Tsap t = tsap_from_bytes(three[..])!!;
	assert(t.len == 3 && t.bytes[2] == 0x56);
	char[17] too_long;
	assert(@catch(tsap_from_bytes(too_long[..])) == INVALID_ARGUMENT);
	assert(@catch(tsap_from_bytes(too_long[:0])) == INVALID_ARGUMENT);
}

// ---- COTP connect phase: V1-V10 ----

fn void test_v1_cr_rack0_slot2_pg() @test
{
	Tsaps t = tsaps_from_rack_slot(PG, 0, 2)!!;
	expect_cr(t, 1, FX_V1);
	Fixture f = fx(FX_V1);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == CR && p.dst_ref == 0 && p.src_ref == 1);
	assert(p.tpdu_size == 0x0A);
	assert(p.has_local_tsap && p.has_remote_tsap);
	assert(tsap_is(p.tsaps.local, 0x0100) && tsap_is(p.tsaps.remote, 0x0102));
}

fn void test_v2_cr_s7_1200() @test
{
	Tsaps t = tsaps_from_rack_slot(PG, 0, 1)!!;
	expect_cr(t, 1, FX_V2);
}

fn void test_v3_cr_rack1_slot2_basic() @test
{
	Tsaps t = tsaps_from_rack_slot(BASIC, 1, 2)!!;
	expect_cr(t, 1, FX_V3);
}

fn void test_v4_cr_raw_tsaps() @test
{
	Tsaps t;
	t.local = tsap_from_u16(0x1000);
	t.remote = tsap_from_u16(0x1001);
	expect_cr(t, 1, FX_V4);
}

fn void test_v5_cr_three_byte_tsap() @test
{
	char[3] three = { 0x12, 0x34, 0x56 };
	Tsaps t;
	t.local = tsap_from_bytes(three[..])!!;
	t.remote = tsap_from_u16(0x0102);
	expect_cr(t, 1, FX_V5);
	Fixture f = fx(FX_V5);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.tsaps.local.len == 3 && p.tsaps.local.bytes[0] == 0x12 && p.tsaps.local.bytes[2] == 0x56);
	assert(tsap_is(p.tsaps.remote, 0x0102));
}

fn void test_encode_cr_buffer_and_arguments() @test
{
	Tsaps t = tsaps_from_rack_slot(PG, 0, 2)!!;
	char[21] small;
	assert(@catch(encode_cr(t, 1, small[..])) == BUFFER_TOO_SMALL);
	Tsaps empty;
	char[64] out;
	assert(@catch(encode_cr(empty, 1, out[..])) == INVALID_ARGUMENT);
}

fn void test_v6_cc_normal() @test
{
	Fixture f = fx(FX_V6);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == CC && p.dst_ref == 1 && p.src_ref == 1);
	assert(tsap_is(p.tsaps.local, 0x0100) && tsap_is(p.tsaps.remote, 0x0102));
	assert(p.tpdu_size == 0x0A);
}

fn void test_v7_cc_without_parameters() @test
{
	Fixture f = fx(FX_V7);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == CC && !p.has_local_tsap && !p.has_remote_tsap && p.tpdu_size == 0);
}

fn void test_v8_cc_dst_ref_zero_is_decoded() @test
{
	// The codec does not judge DST-REF; the session policy does.
	Fixture f = fx(FX_V8);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == CC && p.dst_ref == 0 && p.src_ref == 1);
}

fn void test_v9_cc_unknown_parameter_skipped() @test
{
	Fixture f = fx(FX_V9);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == CC && p.has_local_tsap && p.has_remote_tsap);
	assert(tsap_is(p.tsaps.remote, 0x0102));
}

fn void test_v10_disconnect_request() @test
{
	Fixture f = fx(FX_V10);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == DR && p.dst_ref == 1 && p.src_ref == 1 && p.reason == 0);
}

fn void test_encode_dr_roundtrip() @test
{
	char[16] out;
	usz n = encode_dr(1, 2, out[..])!!;
	Fixture want = fx("03 00 00 0B 06 80 00 01 00 02 80");
	assert(same_bytes(out[:n], want.bytes()));
	CotpPdu p = decode_cotp(out[:n])!!;
	assert(p.kind == DR && p.dst_ref == 1 && p.src_ref == 2);
	assert(@catch(encode_dr(1, 2, out[:10])) == BUFFER_TOO_SMALL);
}

fn void test_error_tpdu_decodes() @test
{
	Fixture f = fx("03 00 00 09 04 70 00 01 03");
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == ER && p.dst_ref == 1 && p.reason == 3);
}

// ---- COTP malformed ----

fn void test_m32_tlv_overruns_tpdu() @test
{
	Fixture f = fx(FX_M32_FIXED);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_m32_original_li_exceeds_frame() @test
{
	Fixture f = fx(FX_M32);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_m33_cc_class_2() @test
{
	Fixture f = fx(FX_M33);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_m34_dt_where_cc_expected_decodes_as_dt() @test
{
	// Rejecting it during connect is the session's job.
	Fixture f = fx(FX_M34);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == DT && p.payload.len == 0);
}

fn void test_m35_cr_from_server_decodes_as_cr() @test
{
	Fixture f = fx(FX_M35);
	CotpPdu p = decode_cotp(f.bytes())!!;
	assert(p.kind == CR);
}

fn void test_m9_li_exceeds_frame() @test
{
	Fixture f = fx(FX_M9);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_m10_li_zero() @test
{
	Fixture f = fx(FX_M10);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_m11_li_255() @test
{
	Fixture f = fx(FX_M11);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_m12_dt_without_eot() @test
{
	Fixture f = fx(FX_M12);
	assert(@catch(decode_cotp(f.bytes())) == UNEXPECTED_PDU);
}

fn void test_m13_unknown_tpdu_code() @test
{
	Fixture f = fx(FX_M13);
	assert(@catch(decode_cotp(f.bytes())) == BAD_COTP);
}

fn void test_cotp_frame_length_mismatch() @test
{
	Fixture f = fx(FX_V1);
	assert(@catch(decode_cotp(f.bytes()[:21])) == TRUNCATED);
	assert(@catch(decode_cotp(f.bytes()[:3])) == TRUNCATED);
	Fixture g = fx("03 00 00 16 11 E0 00 00 00 01 00 C0 01 0A C1 02 01 00 C2 02 01 02 00");
	assert(@catch(decode_cotp(g.bytes())) == BAD_TPKT);
}

fn void test_cotp_tlv_edge_cases() @test
{
	// parameter header cut after its code byte
	Fixture a = fx("03 00 00 0C 07 D0 00 01 00 01 00 C1");
	assert(@catch(decode_cotp(a.bytes())) == BAD_COTP);
	// zero-length TSAP
	Fixture b = fx("03 00 00 0D 08 D0 00 01 00 01 00 C1 00");
	assert(@catch(decode_cotp(b.bytes())) == BAD_COTP);
	// 17-byte TSAP
	Fixture c = fx("03 00 00 1E 19 D0 00 01 00 01 00 C1 11 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10");
	assert(@catch(decode_cotp(c.bytes())) == BAD_COTP);
	// CC fixed part too short
	Fixture d = fx("03 00 00 0A 05 D0 00 01 00 01");
	assert(@catch(decode_cotp(d.bytes())) == BAD_COTP);
	// DT with a wrong length indicator
	Fixture e = fx("03 00 00 08 03 F0 80 32");
	assert(@catch(decode_cotp(e.bytes())) == BAD_COTP);
}

// ---- TPKT header: M1, M2, M3, M4, M6 ----

fn void test_tpkt_header_valid() @test
{
	Fixture f = fx(FX_V1);
	assert(decode_tpkt_header(f.bytes()[:4], 8192, true)!! == 22);
	Fixture g = fx("03 00 00 1F");
	assert(decode_tpkt_header(g.bytes(), 8192, true)!! == 31);
}

fn void test_m1_tpkt_version_2() @test
{
	Fixture f = fx(FX_M1);
	assert(@catch(decode_tpkt_header(f.bytes()[:4], 8192, true)) == BAD_TPKT);
	assert(@catch(decode_tpkt_header(f.bytes()[:4], 8192, false)) == BAD_TPKT);
	assert(@catch(decode_cotp(f.bytes())) == BAD_TPKT);
}

fn void test_m2_reserved_byte() @test
{
	Fixture f = fx(FX_M2);
	assert(@catch(decode_tpkt_header(f.bytes()[:4], 8192, true)) == BAD_TPKT);
	assert(decode_tpkt_header(f.bytes()[:4], 8192, false)!! == 31);
}

fn void test_m3_length_3() @test
{
	Fixture f = fx(FX_M3);
	assert(@catch(decode_tpkt_header(f.bytes()[:4], 8192, true)) == BAD_TPKT);
}

fn void test_m4_length_6() @test
{
	Fixture f = fx(FX_M4);
	assert(@catch(decode_tpkt_header(f.bytes()[:4], 8192, true)) == BAD_TPKT);
}

fn void test_m6_length_ffff_rejected_before_buffering() @test
{
	Fixture f = fx(FX_M6);
	assert(@catch(decode_tpkt_header(f.bytes()[:4], 8192, true)) == FRAME_TOO_LARGE);
	Fixture g = fx("03 00 20 00");
	assert(decode_tpkt_header(g.bytes(), 8192, true)!! == 8192);
	Fixture h = fx("03 00 20 01");
	assert(@catch(decode_tpkt_header(h.bytes(), 8192, true)) == FRAME_TOO_LARGE);
}

fn void test_tpkt_header_incomplete() @test
{
	Fixture f = fx("03 00 00");
	assert(@catch(decode_tpkt_header(f.bytes(), 8192, true)) == TRUNCATED);
	assert(@catch(decode_tpkt_header(f.bytes()[:0], 8192, true)) == TRUNCATED);
}

// ---- DT header ----

fn void test_encode_dt_header() @test
{
	char[16] out;
	out[7] = 0xAA;
	out[8] = 0xBB;
	out[9] = 0xCC;
	usz n = encode_dt_header(out[..], 3)!!;
	Fixture want = fx("03 00 00 0A 02 F0 80 AA BB CC");
	assert(n == 10 && same_bytes(out[:n], want.bytes()));
	CotpPdu p = decode_cotp(out[:n])!!;
	assert(p.kind == DT && p.payload.len == 3 && p.payload[0] == 0xAA);
	assert(@catch(encode_dt_header(out[:9], 3)) == BUFFER_TOO_SMALL);
	assert(@catch(encode_dt_header(out[..], 70000)) == INVALID_ARGUMENT);
}

// ---- S7 header and Setup Communication: V11-V17 ----

fn void test_v11_setup_request() @test
{
	char[32] out;
	usz n = encode_setup_request(1, 480, out[..])!!;
	Fixture want = fx(FX_V11);
	assert(n == 25 && same_bytes(out[:n], want.bytes()));
	S7Header h = s7_of(&want)!!;
	assert(h.rosctr == JOB && h.pdu_ref == 1 && h.param.len == 8 && h.data.len == 0);
	assert(@catch(encode_setup_request(1, 480, out[:24])) == BUFFER_TOO_SMALL);
}

fn void test_setup_request_default_offer_960() @test
{
	char[32] out;
	usz n = encode_setup_request(1, 960, out[..])!!;
	Fixture want = fx("03 00 00 19 02 F0 80 32 01 00 00 00 01 00 08 00 00 F0 00 00 01 00 01 03 C0");
	assert(same_bytes(out[:n], want.bytes()));
}

fn void test_v12_setup_response_480() @test
{
	Fixture f = fx(FX_V12);
	S7Header h = s7_of(&f)!!;
	assert(h.rosctr == ACK_DATA && h.pdu_ref == 1 && h.err_class == 0 && h.err_code == 0);
	SetupParams p = decode_setup_response(&h)!!;
	assert(p.amq_calling == 1 && p.amq_called == 1 && p.pdu == 480);
}

fn void test_v13_setup_response_240() @test
{
	Fixture f = fx(FX_V13);
	S7Header h = s7_of(&f)!!;
	assert(decode_setup_response(&h)!!.pdu == 240);
}

fn void test_v14_setup_response_larger_than_offer_decodes() @test
{
	// Clamping to our offer is the session's policy; the codec reports the raw number.
	Fixture f = fx(FX_V14);
	S7Header h = s7_of(&f)!!;
	assert(decode_setup_response(&h)!!.pdu == 960);
}

fn void test_v15_setup_response_pdu_zero_decodes() @test
{
	Fixture f = fx(FX_V15);
	S7Header h = s7_of(&f)!!;
	assert(decode_setup_response(&h)!!.pdu == 0);
}

fn void test_v16_setup_response_amq_zero_clamped() @test
{
	Fixture f = fx(FX_V16);
	S7Header h = s7_of(&f)!!;
	SetupParams p = decode_setup_response(&h)!!;
	assert(p.amq_calling == 1 && p.amq_called == 1 && p.pdu == 480);
}

fn void test_v17_setup_response_header_error() @test
{
	Fixture f = fx(FX_V17);
	S7Header h = s7_of(&f)!!;
	assert(h.err_class == 0x81 && h.err_code == 0x04);
	assert(@catch(decode_setup_response(&h)) == S7_ERROR);
}

fn void test_m29_setup_response_short_parameter() @test
{
	Fixture f = fx(FX_M29);
	S7Header h = s7_of(&f)!!;
	assert(h.param.len == 4);
	assert(@catch(decode_setup_response(&h)) == BAD_RESPONSE);
}

fn void test_m30_setup_response_wrong_function() @test
{
	Fixture f = fx(FX_M30);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_setup_response(&h)) == BAD_RESPONSE);
}

fn void test_setup_response_wrong_rosctr() @test
{
	// V11 is a Job, not an Ack_Data
	Fixture f = fx(FX_V11);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_setup_response(&h)) == BAD_RESPONSE);
}

// ---- S7 header malformed: M14-M18 ----

fn void test_m14_s7comm_plus() @test
{
	Fixture f = fx(FX_M14);
	assert(@catch(s7_of(&f)) == UNSUPPORTED_PROTOCOL);
}

fn void test_m15_header_truncated() @test
{
	Fixture f = fx(FX_M15);
	assert(@catch(s7_of(&f)) == TRUNCATED);
}

fn void test_m16_unknown_rosctr() @test
{
	Fixture f = fx(FX_M16);
	assert(@catch(s7_of(&f)) == BAD_S7_HEADER);
}

fn void test_m17_lengths_exceed_payload() @test
{
	Fixture f = fx(FX_M17);
	assert(@catch(s7_of(&f)) == BAD_S7_HEADER);
}

fn void test_m18_trailing_bytes() @test
{
	Fixture f = fx(FX_M18);
	assert(@catch(s7_of(&f)) == BAD_S7_HEADER);
}

fn void test_s7_header_other_protocol_id_and_empty() @test
{
	char[1] one;
	assert(@catch(decode_s7_header(one[:0])) == TRUNCATED);
	Fixture f = fx("33 01 00 00 00 01 00 00 00 00");
	assert(@catch(decode_s7_header(f.bytes())) == BAD_S7_HEADER);
	// ack header needs 12 bytes
	Fixture g = fx("32 03 00 00 00 01 00 00 00 00");
	assert(@catch(decode_s7_header(g.bytes())) == TRUNCATED);
}

fn void test_s7_header_userdata_and_job_have_ten_byte_header() @test
{
	Fixture f = fx("32 07 00 00 00 05 00 02 00 01 AA BB CC");
	S7Header h = decode_s7_header(f.bytes())!!;
	assert(h.rosctr == USERDATA && h.pdu_ref == 5);
	assert(h.param.len == 2 && h.param[0] == 0xAA && h.data.len == 1 && h.data[0] == 0xCC);
}

// ---- fixtures are really used ----

fn void test_mutated_cr_fixture_differs() @test
{
	Tsaps t = tsaps_from_rack_slot(PG, 0, 2)!!;
	char[64] out;
	usz n = encode_cr(t, 1, out[..])!!;
	Fixture want = fx(FX_V1);
	assert(same_bytes(out[:n], want.bytes()));
	want.buf[21] ^= 1;
	assert(!same_bytes(out[:n], want.bytes()));
}

fn void test_be_helpers_reject_offsets_that_wrap() @test
{
	char[8] b;
	assert(@catch(get_be16(b[..], usz::max)) == TRUNCATED);
	assert(@catch(get_be32(b[..], usz::max)) == TRUNCATED);
	assert(@catch(get_be16(b[..], usz::max - 1)) == TRUNCATED);
	assert(@catch(get_be32(b[..], usz::max - 2)) == TRUNCATED);
	assert(@catch(put_be16(b[..], usz::max, 1)) == BUFFER_TOO_SMALL);
	assert(@catch(put_be32(b[..], usz::max, 1)) == BUFFER_TOO_SMALL);
	assert(@catch(put_be16(b[:1], 0, 1)) == BUFFER_TOO_SMALL);
	assert(@catch(get_be32(b[:3], 0)) == TRUNCATED);
	assert(get_be16(b[:2], 0)!! == 0);
	assert(get_be32(b[:4], 0)!! == 0);
}
