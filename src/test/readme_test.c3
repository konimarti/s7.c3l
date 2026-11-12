module app;

import std::io;
import s7;

// The examples of README.md, copied here so that the compiler checks them. They are not run.

fn void? read_a_word(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	char[] bytes = client.read_bytes(s7::parse_address("DB1.DBW2")!, mem)!;
	defer free(bytes.ptr);
	assert(bytes.len == 2);
}

fn void? write_a_word(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	cfg.allow_write = true;
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	char[2] value = { 0x12, 0x34 };
	client.write_bytes(s7::parse_address("DB1.DBW2")!, value[..])!;
}

fn void? read_many(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	s7::Address[2] items = { s7::parse_address("DB1.DBB0[200]")!, s7::parse_address("DB99.DBW0")! };
	s7::Completion done = client.read(items[..])!;
	defer done.free();
	if (done.results[1].status) io::printfn("DB99: %s", done.results[1].status);
}

// the TCP transport of the first example
fn void? connect_over_tcp()
{
	s7::TcpTransport tcp = s7::tcp_connect("192.168.0.10")!;
	defer tcp.close()!!;
	read_a_word(&tcp)!;
}
