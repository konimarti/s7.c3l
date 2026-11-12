module peercheck;

import std::io;
import s7;

// Runs the peer cases of src/test/peer_cases.c3 outside the test runner: `peercheck [--capture] [case number...]`.
// Needs S7_PEER=host:port (see scripts/run_peer.py).
fn int main(String[] args)
{
	bool capture = false;
	foreach (a : args[1..])
	{
		if (a == "--capture") capture = true;
	}
	int failed = 0;
	foreach (i, pc : s7::PEER_CASES)
	{
		bool wanted = args.len == 1;
		foreach (a : args[1..])
		{
			if (a != "--capture" && a.to_int() ?? -1 == (int)i) wanted = true;
		}
		if (!wanted) continue;
		s7::peer_execute(pc, capture);
	}
	return failed;
}
