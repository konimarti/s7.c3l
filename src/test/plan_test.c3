module s7;

// Tests for the request planner (plan.c3). S1-S8 are the splitting cases of the independent test vector set.

fn Address addr(String text) => parse_address(text)!!;

fn Plan plan_r(Address[] items, ushort pdu) => plan_read(items, pdu, 20, 1 << 20, mem)!!;

fn usz plan_pdus(Address[] items, ushort pdu)
{
	Plan p = plan_r(items, pdu);
	usz n = p.pdus.len;
	p.free();
	return n;
}

fn bool plan_ok(Address[] items, ushort pdu, ushort max_items, uint max_request)
{
	Plan? p = plan_read(items, pdu, max_items, max_request, mem);
	if (catch p) return false;
	p.free();
	return true;
}

fn Plan plan_w(Address[] items, ushort pdu) => plan_write(items, pdu, 20, 1 << 20, mem)!!;

fn void expect_chunk(Plan* plan, usz pdu, usz slice, uint item, uint offset, uint length)
{
	Slice s = plan.pdus[pdu].slices[slice];
	assert(s.item == item && s.offset == offset && s.length == length, "slice %d of pdu %d", (int)slice, (int)pdu);
}

// Independent size computation of one PDU (header, parameters and data, no TPKT/COTP).
fn usz read_request_size(Slice[] slices) => 12 + 12 * slices.len;

fn usz data_size(Slice[] slices)
{
	usz sum = 0;
	foreach (k, s : slices)
	{
		sum += (usz)4 + s.length;
		if ((usz)k + 1 < slices.len && (s.length & 1) == 1) sum += 1;
	}
	return sum;
}

fn usz read_response_size(Slice[] slices) => 14 + data_size(slices);

fn usz write_request_size(Slice[] slices) => 12 + 12 * slices.len + data_size(slices);

// ---- S1-S5, S7, S8 ----

fn void test_s1_read_chunks_at_240() @test
{
	Address[1] one = { addr("DB1.DBB0:222") };
	Plan a = plan_r(one[..], 240);
	assert(a.pdus.len == 1);                                        // S1: 222 bytes fit, 12+2+4+222 = 240
	assert(read_response_size(a.pdus[0].slices) == 240);
	a.free();
	Address[1] two = { addr("DB1.DBB0:223") };
	Plan b = plan_r(two[..], 240);
	assert(b.pdus.len == 2);                                        // 223 bytes: 222 + 1
	expect_chunk(&b, 0, 0, 0, 0, 222);
	expect_chunk(&b, 1, 0, 0, 222, 1);
	b.free();
}

fn void test_s2_chunks_at_480() @test
{
	Address[1] r462 = { addr("DB1.DBB0:462") };
	Plan a = plan_r(r462[..], 480);
	assert(a.pdus.len == 1);                                        // S2: read 462 at 480
	a.free();
	Address[1] r463 = { addr("DB1.DBB0:463") };
	Plan b = plan_r(r463[..], 480);
	assert(b.pdus.len == 2);
	b.free();
	Address[1] w452 = { addr("DB1.DBB0:452") };
	Plan c = plan_w(w452[..], 480);
	assert(c.pdus.len == 1);                                        // write 452 at 480
	assert(write_request_size(c.pdus[0].slices) == 480);
	c.free();
	Address[1] w453 = { addr("DB1.DBB0:453") };
	Plan d = plan_w(w453[..], 480);
	assert(d.pdus.len == 2);
	d.free();
}

fn void test_write_chunks_at_240() @test
{
	Address[1] w212 = { addr("DB1.DBB0:212") };
	Plan a = plan_w(w212[..], 240);
	assert(a.pdus.len == 1 && write_request_size(a.pdus[0].slices) == 240);
	a.free();
	Address[1] w213 = { addr("DB1.DBB0:213") };
	Plan b = plan_w(w213[..], 240);
	assert(b.pdus.len == 2);
	expect_chunk(&b, 0, 0, 0, 0, 212);
	expect_chunk(&b, 1, 0, 0, 212, 1);
	b.free();
}

fn void test_s3_request_size_limits_the_item_count() @test
{
	Address[20] twenty;
	foreach (&a : twenty) *a = addr("DB1.DBB0");
	Plan p = plan_r(twenty[..], 240);
	assert(p.pdus.len == 2);                                        // S3: 12 + 12*19 = 240, the 20th item goes next
	assert(p.pdus[0].slices.len == 19 && p.pdus[1].slices.len == 1);
	assert(read_request_size(p.pdus[0].slices) == 240);
	assert(read_response_size(p.pdus[0].slices) == 127);            // 14 + 19*(4+1) + 18 pads
	p.free();
}

fn void test_response_size_limits_the_item_count() @test
{
	Address[20] twenty;
	foreach (&a : twenty) *a = addr("DB1.DBB0:10");
	Plan p = plan_r(twenty[..], 240);
	assert(p.pdus.len == 2);                                        // 14 + 14 n <= 240 gives n <= 16
	assert(p.pdus[0].slices.len == 16 && p.pdus[1].slices.len == 4);
	p.free();
}

fn void test_s4_max_items() @test
{
	Address[21] items;
	foreach (&a : items) *a = addr("DB1.DBB0");
	Plan p = plan_r(items[..], 960);
	assert(p.pdus.len == 2);                                        // S4 and M44: 21 items are cut at 20 + 1
	assert(p.pdus[0].slices.len == 20 && p.pdus[1].slices.len == 1);
	p.free();
	Plan q = plan_read(items[..], 960, 5, 1 << 20, mem)!!;
	assert(q.pdus.len == 5 && q.pdus[4].slices.len == 1);
	q.free();
}

fn void test_s5_one_thousand_bytes_at_240() @test
{
	Address[1] one = { addr("DB1.DBB0:1000") };
	Plan p = plan_r(one[..], 240);
	assert(p.pdus.len == 5);                                        // S5
	expect_chunk(&p, 0, 0, 0, 0, 222);
	expect_chunk(&p, 1, 0, 0, 222, 222);
	expect_chunk(&p, 2, 0, 0, 444, 222);
	expect_chunk(&p, 3, 0, 0, 666, 222);
	expect_chunk(&p, 4, 0, 0, 888, 112);
	p.free();
}

fn void test_s7_bit_and_large_item_do_not_share_a_pdu() @test
{
	Address[2] items = { addr("DB1.DBX0.1"), addr("DB1.DBB4:222") };
	Plan p = plan_r(items[..], 240);
	assert(p.pdus.len == 2);                                        // S7: 14 + (4+1+1) + (4+222) = 246 > 240
	expect_chunk(&p, 0, 0, 0, 0, 1);
	expect_chunk(&p, 1, 0, 1, 0, 222);
	p.free();
}

fn void test_s8_two_writes_share_a_pdu() @test
{
	Address[2] items = { addr("DB1.DBB0"), addr("DB1.DBB1") };
	Plan p = plan_w(items[..], 240);
	assert(p.pdus.len == 1 && p.pdus[0].slices.len == 2);           // S8: 12 + 24 + (4+1+1) + (4+1) = 47
	assert(write_request_size(p.pdus[0].slices) == 47);
	p.free();
}

fn void test_pad_accounting_odd_then_even() @test
{
	// response size of an odd first item and a second one of k bytes: 14 + (4 + 3 + 1) + (4 + k) = 26 + k
	Address[2] a = { addr("DB1.DBB0:3"), addr("DB1.DBB10:34") };
	assert(plan_pdus(a[..], 60) == 1);
	Address[2] b = { addr("DB1.DBB0:3"), addr("DB1.DBB10:35") };
	assert(plan_pdus(b[..], 60) == 2);
	// an even first item needs no pad: 14 + (4 + 4) + (4 + k) = 26 + k - 0 + ... = 22 + k
	Address[2] c = { addr("DB1.DBB0:4"), addr("DB1.DBB10:34") };
	assert(plan_pdus(c[..], 60) == 1);
	Address[2] d = { addr("DB1.DBB0:4"), addr("DB1.DBB10:39") };
	assert(plan_pdus(d[..], 60) == 2);
}

// ---- timers, counters, bits ----

fn void test_timer_and_counter_split_on_two_byte_boundaries() @test
{
	Address[1] t = { addr("T10:300") };      // 600 bytes
	Plan p = plan_r(t[..], 240);
	assert(p.pdus.len == 3);
	expect_chunk(&p, 0, 0, 0, 0, 222);
	expect_chunk(&p, 1, 0, 0, 222, 222);
	expect_chunk(&p, 2, 0, 0, 444, 156);
	foreach (pdu : p.pdus)
	{
		foreach (s : pdu.slices) assert(s.offset % 2 == 0 && s.length % 2 == 0);
	}
	Address c = chunk_address(&t[0], &p.pdus[1].slices[0]);
	assert(c.tsize == TIMER && c.byte_off == 10 + 111 && c.count == 111);
	p.free();
}

fn void test_bits_are_never_split() @test
{
	Address[3] bits = { addr("I0.0"), addr("DB1.DBX3.7"), addr("M5.1") };
	Plan p = plan_r(bits[..], 240);
	assert(p.pdus.len == 1 && p.pdus[0].slices.len == 3);
	foreach (s : p.pdus[0].slices) assert(s.length == 1 && s.offset == 0);
	p.free();
}

fn void test_word_items_are_planned_in_bytes() @test
{
	Address[1] w = { addr("DB1.DBW2:300") };   // 600 bytes
	Plan p = plan_r(w[..], 240);
	assert(p.pdus.len == 3);
	expect_chunk(&p, 2, 0, 0, 444, 156);
	Address c = chunk_address(&w[0], &p.pdus[1].slices[0]);
	assert(c.tsize == BYTE && c.byte_off == 2 + 222 && c.count == 222);
	p.free();
}

// ---- big and invalid requests ----

fn void test_one_mebibyte_at_960() @test
{
	Address big = { .area = DB, .db = 1, .tsize = BYTE, .count = 1048576 };
	Address[1] one = { big };
	Plan p = plan_r(one[..], 960);
	usz want = (1048576 + 941) / 942;
	assert(p.pdus.len == want);
	usz covered = 0;
	foreach (pdu : p.pdus)
	{
		assert(pdu.slices.len == 1 && pdu.slices[0].offset == covered);
		covered += pdu.slices[0].length;
	}
	assert(covered == 1048576);
	p.free();
}

fn void test_limits_and_arguments() @test
{
	Address big = { .area = DB, .db = 1, .tsize = BYTE, .count = 1048577 };
	Address[1] one = { big };
	assert(@catch(plan_read(one[..], 960, 20, 1 << 20, mem)) == INVALID_ARGUMENT);
	big.count = 1048576;
	Address[1] fits = { big };
	assert(plan_ok(fits[..], 960, 20, 1 << 20));
	Address half = { .area = DB, .db = 1, .tsize = BYTE, .count = 600000 };
	Address[2] two = { half, half };
	assert(@catch(plan_read(two[..], 960, 20, 1 << 20, mem)) == INVALID_ARGUMENT);   // the sum counts

	Address[1] ok = { addr("DB1.DBB0") };
	assert(@catch(plan_read(ok[:0], 240, 20, 1 << 20, mem)) == INVALID_ARGUMENT);
	assert(@catch(plan_read(ok[..], 240, 0, 1 << 20, mem)) == INVALID_ARGUMENT);
	assert(@catch(plan_read(ok[..], 29, 20, 1 << 20, mem)) == INVALID_ARGUMENT);
	assert(plan_ok(ok[..], 30, 20, 1 << 20));

	Address zero = { .area = DB, .db = 1, .tsize = BYTE, .count = 0 };
	Address[1] z = { zero };
	assert(@catch(plan_read(z[..], 240, 20, 1 << 20, mem)) == INVALID_ARGUMENT);
	Address bits = { .area = DB, .db = 1, .tsize = BIT, .count = 2 };
	Address[1] b = { bits };
	assert(@catch(plan_read(b[..], 240, 20, 1 << 20, mem)) == INVALID_ARGUMENT);
	assert(@catch(plan_write(b[..], 240, 20, 1 << 20, mem)) == INVALID_ARGUMENT);
}

fn void test_chunk_start_must_stay_addressable() @test
{
	Address far = { .area = DB, .db = 1, .byte_off = 2097151, .tsize = BYTE, .count = 1 };
	Address[1] one = { far };
	assert(plan_ok(one[..], 240, 20, 1 << 20));
	far.count = 223;      // the second chunk would start at byte 2097151 + 222
	Address[1] two = { far };
	assert(@catch(plan_read(two[..], 240, 20, 1 << 20, mem)) == ADDRESS_RANGE);
	Address timer = { .area = TIMER, .byte_off = 65535, .tsize = TIMER, .count = 200 };
	Address[1] t = { timer };
	assert(@catch(plan_read(t[..], 240, 20, 1 << 20, mem)) == ADDRESS_RANGE);
}

fn void test_plan_free_is_harmless_twice() @test
{
	TrackingAllocator t;
	t.init(mem);
	Address[1] one = { addr("DB1.DBB0:1000") };
	Plan p = plan_read(one[..], 240, 20, 1 << 20, &t)!!;
	assert(t.allocation_count() == 2);
	p.free();
	p.free();
	assert(t.allocation_count() == 0);
	assert(@catch(plan_read(one[..], 29, 20, 1 << 20, &t)) == INVALID_ARGUMENT);
	assert(t.allocation_count() == 0, "a failed plan allocates nothing");
	t.free();
}

// ---- property test ----

struct PlanRng
{
	ulong state;
}

fn usz PlanRng.below(&self, usz n)
{
	ulong x = self.state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	self.state = x;
	return (usz)(x % (ulong)n);
}

fn void test_random_item_lists_respect_the_pdu_size() @test
{
	PlanRng rng = { 0x6A09E667F3BCC908 };
	ushort[3] sizes = { 240, 480, 960 };
	Tsize[6] kinds = { BIT, BYTE, WORD, DWORD, TIMER, COUNTER };
	for (int round = 0; round < 500; round++)
	{
		foreach (pdu_size : sizes)
		{
			usz n = 1 + rng.below(30);
			Address[30] items;
			for (usz i = 0; i < n; i++)
			{
				Tsize ts = kinds[rng.below(6)];
				Address a = { .area = ts == TIMER ? TIMER : (ts == COUNTER ? COUNTER : DB), .db = 1, .tsize = ts };
				a.byte_off = (uint)rng.below(1000);
				a.count = ts == BIT ? 1 : (uint)(1 + rng.below(rng.below(4) == 0 ? 600 : 12));
				items[i] = a;
			}
			foreach (write : (bool[2]){ false, true })
			{
				Plan p = plan_items(items[:n], pdu_size, 20, 1 << 20, write, mem)!!;
				usz next_item = 0;
				usz covered = 0;
				foreach (pdu : p.pdus)
				{
					assert(pdu.slices.len >= 1 && pdu.slices.len <= 20);
					assert(12 + 12 * pdu.slices.len <= pdu_size);
					if (write)
					{
						assert(write_request_size(pdu.slices) <= pdu_size);
					}
					else
					{
						assert(read_response_size(pdu.slices) <= pdu_size);
					}
					foreach (s : pdu.slices)
					{
						// in order, contiguous, exactly once
						if (s.item != next_item)
						{
							assert(s.item == next_item + 1 && covered == items[next_item].payload_bytes());
							next_item = s.item;
							covered = 0;
						}
						assert(s.offset == covered && s.length > 0);
						if (items[s.item].tsize == BIT) assert(s.length == 1);
						covered += s.length;
					}
				}
				assert(next_item == n - 1 && covered == items[n - 1].payload_bytes());
				p.free();
			}
		}
	}
}
