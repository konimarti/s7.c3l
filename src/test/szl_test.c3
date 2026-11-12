module s7;

// ---- Test fixtures from TEST-VECTORS.md ----

// V50: SZL read request 0x0011 index 0x0000
const String FX_V50 = "03 00 00 21 02 F0 80 32 07 00 00 00 08 00 08 00 08 00 01 12 04 11 44 01 00 FF 09 00 04 00 11 00 00";

// V51: SZL read request 0x001C index 0x0000
const String FX_V51 = "03 00 00 21 02 F0 80 32 07 00 00 00 09 00 08 00 08 00 01 12 04 11 44 01 00 FF 09 00 04 00 1C 00 00";

// V52: SZL read request 0x0424 index 0x0000
const String FX_V52 = "03 00 00 21 02 F0 80 32 07 00 00 00 0A 00 08 00 08 00 01 12 04 11 44 01 00 FF 09 00 04 04 24 00 00";

// V53: SZL 0x001C response, 2 records of 34 bytes, complete
const String FX_V53 = "03 00 00 6D 02 F0 80 32 07 00 00 00 09 00 0C 00 50 00 01 12 08 12 84 01 01 00 00 00 00 FF 09 00 4C 00 1C 00 00 00 22 00 02 00 01 53 37 2D 31 32 30 30 20 73 74 61 74 69 6F 6E 5F 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 43 50 55 20 31 32 31 34 43 20 44 43 2F 44 43 2F 44 43 00 00 00 00 00 00 00 00 00 00 00 00 00 00";

// V54: SZL response error: param error code D401, data return code 0A (SZL not available)
const String FX_V54 = "03 00 00 21 02 F0 80 32 07 00 00 00 0A 00 0C 00 04 00 01 12 08 12 84 01 01 00 00 D4 01 0A 00 00 00";

// V55: SZL 0x0011 index 0x0001 response: one 28-byte record (order number)
const String FX_V55 = "03 00 00 45 02 F0 80 32 07 00 00 00 08 00 0C 00 28 00 01 12 08 12 84 01 01 00 00 00 00 FF 09 00 24 00 11 00 01 00 1C 00 01 00 01 36 45 53 37 20 32 31 34 2D 31 41 47 34 30 2D 30 58 42 30 20 00 00 01 02 00 03";

// V56: SZL 0x0424 response: RUN (status byte 0x08 at record offset 3, rest zero)
const String FX_V56 = "03 00 00 3D 02 F0 80 32 07 00 00 00 0A 00 0C 00 20 00 01 12 08 12 84 01 01 00 00 00 00 FF 09 00 1C 04 24 00 00 00 14 00 01 02 00 00 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00";

// V57: Read clock request
const String FX_V57 = "03 00 00 1D 02 F0 80 32 07 00 00 00 0B 00 08 00 04 00 01 12 04 11 47 01 00 0A 00 00 00";

// V58: Read clock response: 2025-11-12 14:30:45.000, weekday 5 (Thursday)
const String FX_V58 = "03 00 00 2B 02 F0 80 32 07 00 00 00 0B 00 0C 00 0E 00 01 12 08 12 87 01 01 00 00 00 00 FF 09 00 0A 00 20 25 11 12 14 30 45 00 05";

// M36: SZL response with record_len 0xFFFF, count 0xFFFF (overflow of record_len*count in 16 bit math)
const String FX_M36 = "03 00 00 2B 02 F0 80 32 07 00 00 00 09 00 0C 00 0E 00 01 12 08 12 84 01 01 00 00 00 00 FF 09 00 0C 00 1C 00 00 FF FF FF FF 00 00";

// M37: SZL response data length field larger than payload
const String FX_M37 = "03 00 00 25 02 F0 80 32 07 00 00 00 09 00 0C 00 08 00 01 12 08 12 84 01 01 00 00 00 00 FF 09 FF FF 00 1C 00 00";

// M38: SZL response: last-data-unit = 01 forever (peer never completes)
const String FX_M38 = "03 00 00 6D 02 F0 80 32 07 00 00 00 09 00 0C 00 50 00 01 12 08 12 84 01 01 00 01 00 00 FF 09 00 4C 00 1C 00 00 00 22 00 02 00 01 53 37 2D 31 32 30 30 20 73 74 61 74 69 6F 6E 5F 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 43 50 55 20 31 32 31 34 43 20 44 43 2F 44 43 2F 44 43 00 00 00 00 00 00 00 00 00 00 00 00 00 00";

// M39: Userdata param_len 0 with data_len 0
const String FX_M39 = "03 00 00 11 02 F0 80 32 07 00 00 00 09 00 00 00 00";

// M40: Clock response with BCD nibble 0xA (month byte 0x1A)
const String FX_M40 = "03 00 00 2B 02 F0 80 32 07 00 00 00 0B 00 0C 00 0E 00 01 12 08 12 87 01 01 00 00 00 00 FF 09 00 0A 00 20 25 1A 12 14 30 45 00 05";

// M41: Clock response with month 13 (0x13)
const String FX_M41 = "03 00 00 2B 02 F0 80 32 07 00 00 00 0B 00 0C 00 0E 00 01 12 08 12 87 01 01 00 00 00 00 FF 09 00 0A 00 20 25 13 12 14 30 45 00 05";

// M42: Clock response data length 5 (short)
const String FX_M42 = "03 00 00 26 02 F0 80 32 07 00 00 00 0B 00 0C 00 09 00 01 12 08 12 87 01 01 00 00 00 00 FF 09 00 05 00 00 00 00 00";

// Hand-built two-fragment 0x001C response from V53
// Fragment 1: record 1, seq 1, last_unit 1 (more)
const String FX_V53_FRAG1 = "03 00 00 4B 02 F0 80 32 07 00 00 00 09 00 0C 00 2E 00 01 12 08 12 84 01 01 00 01 00 00 FF 09 00 2A 00 1C 00 00 00 22 00 01 00 01 53 37 2D 31 32 30 30 20 73 74 61 74 69 6F 6E 5F 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00";
// Fragment 2: record 2, seq 2, last_unit 0 (complete)
const String FX_V53_FRAG2 = "03 00 00 4B 02 F0 80 32 07 00 00 00 09 00 0C 00 2E 00 01 12 08 12 84 01 02 00 00 00 00 FF 09 00 2A 00 1C 00 00 00 22 00 01 00 02 43 50 55 20 31 32 31 34 43 20 44 43 2F 44 43 2F 44 43 00 00 00 00 00 00 00 00 00 00 00 00 00 00";

// ---- Unit tests ----

fn void test_vector_v50() @test
{
	char[64] out;
	usz len = encode_szl_request(8, 0x0011, 0x0000, 0, out[..])!!;
	Fixture want = fx(FX_V50);
	assert(same_bytes(out[:len], want.bytes()));
}

fn void test_vector_v51() @test
{
	char[64] out;
	usz len = encode_szl_request(9, 0x001C, 0x0000, 0, out[..])!!;
	Fixture want = fx(FX_V51);
	assert(same_bytes(out[:len], want.bytes()));
}

fn void test_vector_v52() @test
{
	char[64] out;
	usz len = encode_szl_request(10, 0x0424, 0x0000, 0, out[..])!!;
	Fixture want = fx(FX_V52);
	assert(same_bytes(out[:len], want.bytes()));
}

fn void test_vector_v53() @test
{
	Fixture f = fx(FX_V53);
	S7Header h = s7_of(&f)!!;
	SzlPart part = decode_szl_response(&h)!!;

	assert(part.szl_id == 0x001C);
	assert(part.index == 0x0000);
	assert(part.rec_len == 34);
	assert(part.rec_count == 2);
	assert(part.seq == 1);
	assert(!part.more);
	assert(part.records.len == 68);

	CpuInfo info = decode_component_id(part.records, part.rec_len, mem)!!;
	defer info.free(mem);

	assert(info.module_name == "CPU 1214C DC/DC/DC");
}

fn void test_vector_v54() @test
{
	Fixture f = fx(FX_V54);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_szl_response(&h)) == NOT_SUPPORTED);
}

fn void test_vector_v55() @test
{
	Fixture f = fx(FX_V55);
	S7Header h = s7_of(&f)!!;
	SzlPart part = decode_szl_response(&h)!!;

	assert(part.szl_id == 0x0011);
	assert(part.index == 1);
	assert(part.rec_len == 28);
	assert(part.rec_count == 1);
	assert(part.seq == 1);
	assert(!part.more);

	ModuleId m = decode_module_id(part.records, mem)!!;
	defer m.free(mem);

	assert(m.index == 1);
	assert(m.order_number == "6ES7 214-1AG40-0XB0");
	assert(m.module_type == 0);
	assert(m.version == 0x0102);
}

fn void test_vector_v56() @test
{
	Fixture f = fx(FX_V56);
	S7Header h = s7_of(&f)!!;
	SzlPart part = decode_szl_response(&h)!!;

	assert(part.szl_id == 0x0424);
	assert(part.index == 0);
	assert(part.rec_len == 20);
	assert(part.rec_count == 1);

	CpuState state = decode_cpu_state(part.records, part.rec_len)!!;
	assert(state == RUN);

	// Also verify STOP and STARTUP states
	char[20] stop_rec = {};
	stop_rec[3] = 0x04;
	assert(decode_cpu_state(stop_rec[..], 20)!! == STOP);

	char[20] startup_rec = {};
	startup_rec[3] = 0x01;
	assert(decode_cpu_state(startup_rec[..], 20)!! == STARTUP);

	char[20] unk_rec = {};
	unk_rec[3] = 0x99;
	assert(decode_cpu_state(unk_rec[..], 20)!! == UNKNOWN);
}

fn void test_vector_v57() @test
{
	char[64] out;
	usz len = encode_clock_request(11, out[..])!!;
	Fixture want = fx(FX_V57);
	assert(same_bytes(out[:len], want.bytes()));
}

fn void test_vector_v58() @test
{
	Fixture f = fx(FX_V58);
	S7Header h = s7_of(&f)!!;
	Dtl d = decode_clock_response(&h)!!;

	assert(d.year == 2025);
	assert(d.month == 11);
	assert(d.day == 12);
	assert(d.hour == 14);
	assert(d.minute == 30);
	assert(d.second == 45);
	assert(d.weekday == 5); // deliberately mismatched weekday accepted per V58 spec
	assert(d.nanosecond == 0);
}

fn void test_vector_m36() @test
{
	Fixture f = fx(FX_M36);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_szl_response(&h)) == BAD_RESPONSE);
}

fn void test_vector_m37() @test
{
	Fixture f = fx(FX_M37);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_szl_response(&h)) == BAD_RESPONSE);
}

fn void test_vector_m38() @test
{
	Fixture f = fx(FX_M38);
	S7Header h = s7_of(&f)!!;
	SzlPart part = decode_szl_response(&h)!!;
	assert(part.more);
	assert(part.seq == 1);

	// Continuation encoder with the received sequence number
	char[64] cont_out;
	usz cont_len = encode_szl_continuation_request(9, part.szl_id, part.index, part.seq, cont_out[..])!!;
	assert(cont_len == SZL_REQUEST_FRAME_LEN);
	assert(cont_out[24] == 1); // parameter seq byte echoes part.seq
}

fn void test_vector_m39() @test
{
	Fixture f = fx(FX_M39);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_szl_response(&h)) == BAD_RESPONSE);
}

fn void test_vector_m40() @test
{
	Fixture f = fx(FX_M40);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_clock_response(&h)) == INVALID_VALUE);
}

fn void test_vector_m41() @test
{
	Fixture f = fx(FX_M41);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_clock_response(&h)) == INVALID_VALUE);
}

fn void test_vector_m42() @test
{
	Fixture f = fx(FX_M42);
	S7Header h = s7_of(&f)!!;
	assert(@catch(decode_clock_response(&h)) == BAD_RESPONSE);
}

// Extra: two-fragment 0x001C response built from V53
fn void test_extra_two_fragment_reassembly() @test
{
	Fixture f1 = fx(FX_V53_FRAG1);
	S7Header h1 = s7_of(&f1)!!;
	SzlPart p1 = decode_szl_response(&h1)!!;
	assert(p1.more);
	assert(p1.seq == 1);
	assert(p1.rec_count == 1);

	Fixture f2 = fx(FX_V53_FRAG2);
	S7Header h2 = s7_of(&f2)!!;
	SzlPart p2 = decode_szl_response(&h2)!!;
	assert(!p2.more);
	assert(p2.seq == 2);
	assert(p2.rec_count == 1);

	SzlAssembler asmb = szl_assembler_init(DEFAULT_LIMITS, mem);
	defer asmb.free();

	asmb.push(&p1)!!;
	assert(!asmb.is_done(&p1));

	asmb.push(&p2)!!;
	assert(asmb.is_done(&p2));

	char[] all_records = asmb.records();
	assert(all_records.len == 68);

	CpuInfo info = decode_component_id(all_records, 34, mem)!!;
	defer info.free(mem);
	assert(info.module_name == "CPU 1214C DC/DC/DC");
}

// Extra: sequence-number mismatch
fn void test_extra_sequence_mismatch() @test
{
	Fixture f1 = fx(FX_V53_FRAG1);
	S7Header h1 = s7_of(&f1)!!;
	SzlPart p1 = decode_szl_response(&h1)!!;

	Fixture f2 = fx(FX_V53_FRAG2);
	S7Header h2 = s7_of(&f2)!!;
	SzlPart p2 = decode_szl_response(&h2)!!;
	p2.seq = 99; // Corrupt sequence number

	SzlAssembler asmb = szl_assembler_init(DEFAULT_LIMITS, mem);
	defer asmb.free();

	asmb.push(&p1)!!;
	assert(@catch(asmb.push(&p2)) == UNEXPECTED_PDU);
}

// Extra: 70-fragment endless "more" stream stops after 64 follow-ups with BAD_RESPONSE
fn void test_extra_fragment_cap() @test
{
	Fixture f = fx(FX_M38);
	S7Header h = s7_of(&f)!!;
	SzlPart part = decode_szl_response(&h)!!;

	SzlAssembler asmb = szl_assembler_init(DEFAULT_LIMITS, mem);
	defer asmb.free();

	// Limits.max_szl_fragments is 64. Feeding 65 fragments must fail with BAD_RESPONSE.
	bool failed = false;
	for (int i = 0; i < 70; i++)
	{
		SzlPart current = part;
		current.seq = (char)(1 + i);
		if (catch err = asmb.push(&current))
		{
			assert(err == BAD_RESPONSE);
			assert(i == 64); // Fails on the 65th fragment (64 follow-ups)
			failed = true;
			break;
		}
	}
	assert(failed);
}

// Extra: reassembly over max_request_bytes (INVALID_ARGUMENT)
fn void test_extra_max_request_bytes() @test
{
	Fixture f1 = fx(FX_V53_FRAG1);
	S7Header h1 = s7_of(&f1)!!;
	SzlPart p1 = decode_szl_response(&h1)!!;

	Fixture f2 = fx(FX_V53_FRAG2);
	S7Header h2 = s7_of(&f2)!!;
	SzlPart p2 = decode_szl_response(&h2)!!;

	Limits tight_limits = DEFAULT_LIMITS;
	tight_limits.max_request_bytes = 50; // Less than 34 + 34 = 68 bytes

	SzlAssembler asmb = szl_assembler_init(tight_limits, mem);
	defer asmb.free();

	asmb.push(&p1)!!; // 34 bytes <= 50 bytes: OK
	assert(@catch(asmb.push(&p2)) == INVALID_ARGUMENT); // 68 bytes > 50 bytes
}
