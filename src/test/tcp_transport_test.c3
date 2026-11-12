module s7;

import std::net::tcp, std::time;

// Tests of TcpTransport over the loopback interface: a listener in the test plays the other end. No peer program needed.

struct Loop
{
	tcp::TcpServerSocket listener;
	TcpTransport client;
	tcp::TcpSocket server;          // the accepted side
}

fn void Loop.open(&self)
{
	self.listener = tcp::listen("127.0.0.1", 0, 4, REUSEADDR)!!;
	ushort port = self.listener.local_port()!!;
	self.client = tcp_connect("127.0.0.1", port)!!;
	self.server = tcp::accept(&self.listener)!!;
}

fn void Loop.finish(&self)
{
	self.client.close()!!;
	(void)self.server.close();
	(void)self.listener.close();
}

fn void test_tcp_round_trip() @test
{
	Loop l;
	l.open();
	char[5] hello = { 1, 2, 3, 4, 5 };
	l.client.write(hello[..], time::sec(2))!!;
	char[16] buf;
	assert((usz)l.server.read(buf[..])!! == 5 && buf[4] == 5);
	l.server.write(hello[:3])!!;
	assert(l.client.read(buf[..], time::sec(2))!! == 3 && buf[2] == 3);
	l.finish();
}

fn void test_tcp_read_times_out_and_stays_usable() @test
{
	Loop l;
	l.open();
	char[8] buf;
	assert(@catch(l.client.read(buf[..], time::ms(20))) == TIMEOUT);              // a bounded wait
	assert(@catch(l.client.read(buf[..], (time::Duration)0)) == TIMEOUT);         // zero polls once
	char[2] data = { 7, 8 };
	l.server.write(data[..])!!;
	assert(l.client.read(buf[..], time::sec(2))!! == 2 && buf[0] == 7);           // the connection is untouched
	l.finish();
}

fn void test_tcp_read_with_no_limit_returns_what_arrives() @test
{
	Loop l;
	l.open();
	char[1] data = { 9 };
	l.server.write(data[..])!!;
	char[8] buf;
	assert(l.client.read(buf[..], (time::Duration)-1)!! == 1);                    // a negative timeout waits
	l.finish();
}

fn void test_tcp_peer_end_of_stream_is_closed() @test
{
	Loop l;
	l.open();
	(void)l.server.close();
	char[8] buf;
	assert(@catch(l.client.read(buf[..], time::sec(2))) == CLOSED);
	l.finish();
}

fn void test_tcp_write_to_a_closed_connection_is_an_error_not_a_signal() @test
{
	Loop l;
	l.open();
	(void)l.server.close();
	char[4096] data;
	// the first write after the peer's close is accepted by the kernel and answered with a reset
	l.client.write(data[..], time::sec(2))!!;
	char[8] buf;
	assert(@catch(l.client.read(buf[..], time::sec(2))) == CLOSED);
	// writing to the reset connection raises SIGPIPE unless the send is made without it: the process must survive
	assert(@catch(l.client.write(data[..], time::sec(2))) == CLOSED);
	l.finish();
}

fn void test_tcp_close_is_idempotent_and_ends_use() @test
{
	Loop l;
	l.open();
	l.client.close()!!;
	l.client.close()!!;
	char[2] data = { 1, 2 };
	assert(@catch(l.client.write(data[..], time::sec(1))) == CLOSED);
	char[8] buf;
	assert(@catch(l.client.read(buf[..], time::sec(1))) == CLOSED);
	assert(@catch(l.client.read(buf[:0], time::sec(1))) == CLOSED);
	(void)l.server.close();
	(void)l.listener.close();
}

fn void test_tcp_connect_to_a_closed_port_fails() @test
{
	tcp::TcpServerSocket listener = tcp::listen("127.0.0.1", 0, 4, REUSEADDR)!!;
	ushort port = listener.local_port()!!;
	(void)listener.close();
	assert(@catch(tcp_connect("127.0.0.1", port, time::sec(2))) == CONNECT_REFUSED);
}

fn void test_tcp_empty_read_buffer_is_refused() @test
{
	Loop l;
	l.open();
	char[1] one;
	assert(@catch(l.client.read(one[:0], time::sec(1))) == INVALID_ARGUMENT);
	l.finish();
}

fn void test_client_over_a_real_socket() @test
{
	// the whole client against a scripted server on the loopback: handshake and one read
	Loop l;
	l.open();
	TrackingAllocator t;
	t.init(mem);
	// the server side answers from the same thread: queue the replies first, they wait in the socket buffer
	Fixture cc = fx(FX_V6);
	l.server.write(cc.bytes())!!;
	Fixture ack = fx(FX_V12);
	l.server.write(ack.bytes())!!;
	Client c;
	c.open(&l.client, config_480(), &t)!!;
	assert(c.pdu_size() == 480);
	Fixture rsp = fx(FX_V21);                              // the answer to the read that follows
	l.server.write(rsp.bytes())!!;
	char[] bytes = c.read_bytes(addr("DB1.DBW2"), &t)!!;
	Fixture want = fx("12 34");
	assert(same_bytes(bytes, want.bytes()));
	alloc::free(&t, bytes.ptr);
	// what the client sent arrived in whole frames
	char[256] seen;
	usz got = (usz)l.server.read(seen[..])!!;
	Fixture cr = fx(FX_V1);
	assert(got >= cr.len && same_bytes(seen[:cr.len], cr.bytes()));
	c.close();
	assert(!t.has_leaks());
	t.free();
	(void)l.server.close();
	(void)l.listener.close();
}

fn void test_client_gets_closed_when_the_server_goes_away_in_the_middle_of_a_job() @test
{
	Loop l;
	l.open();
	TrackingAllocator t;
	t.init(mem);
	Fixture cc = fx(FX_V6);
	l.server.write(cc.bytes())!!;
	Fixture ack = fx(FX_V12);
	l.server.write(ack.bytes())!!;
	Client c;
	c.open(&l.client, config_480(), &t)!!;
	(void)l.server.close();                                 // the PLC disappears before it answers
	assert(@catch(c.read_bytes(addr("DB1.DBW2"), &t)) == CLOSED);
	assert(@catch(c.read_bytes(addr("DB1.DBW2"), &t)) == NOT_CONNECTED);
	c.close();
	assert(!t.has_leaks());
	t.free();
	(void)l.listener.close();
}

fn void test_tcp_write_to_a_stalled_peer_times_out() @test
{
	// The server never reads. How much the two socket buffers take differs by system (and Windows tunes them), so one
	// big write is not guaranteed to block: write chunks until a write gives up, within a generous bound on the total.
	// The write that gives up must fault with TIMEOUT, not block and not report a closed connection.
	Loop l;
	l.open();
	usz chunk_size = 1024 * 1024;
	char[] chunk = alloc::new_array(mem, char, (sz)chunk_size)[:chunk_size];
	defer alloc::free(mem, chunk.ptr);
	usz max_chunks = 1024;                                  // 1 GiB: far more than any pair of socket buffers holds
	fault outcome = {};
	usz written = 0;
	while (written < max_chunks)
	{
		if (catch err = l.client.write(chunk, time::ms(200)))
		{
			outcome = err;
			break;
		}
		written++;
	}
	assert(written < max_chunks);
	assert(outcome == TIMEOUT);
	l.finish();
}
