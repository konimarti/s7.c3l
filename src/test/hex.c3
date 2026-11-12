module s7;

// Test helper: hex text ("03 00 00 16 ...", spaces ignored) -> bytes.
struct Fixture
{
	char[512] buf;
	usz len;
}

fn Fixture fx(String text)
{
	Fixture f;
	int hi = -1;
	foreach (c : text)
	{
		int v;
		if (c >= '0' && c <= '9')
		{
			v = c - '0';
		}
		else if (c >= 'A' && c <= 'F')
		{
			v = c - 'A' + 10;
		}
		else if (c >= 'a' && c <= 'f')
		{
			v = c - 'a' + 10;
		}
		else
		{
			continue;
		}
		if (hi < 0)
		{
			hi = v;
		}
		else
		{
			f.buf[f.len] = (char)(hi * 16 + v);
			f.len++;
			hi = -1;
		}
	}
	assert(hi < 0, "odd number of hex digits");
	return f;
}

fn char[] Fixture.bytes(&self) => self.buf[:self.len];

fn bool same_bytes(char[] a, char[] b)
{
	if (a.len != b.len) return false;
	foreach (i, x : a)
	{
		if (x != b[i]) return false;
	}
	return true;
}

fn void test_hex_helper() @test
{
	Fixture f = fx("03 0a FF\n00");
	assert(f.len == 4);
	assert(f.bytes()[0] == 3 && f.bytes()[1] == 0x0A && f.bytes()[2] == 0xFF && f.bytes()[3] == 0);
	assert(same_bytes(f.bytes(), f.bytes()));
}
