module s7tool;
import std::io;

fn int main(String[] args)
{
	io::printfn("s7tool %s", env::PROJECT_VERSION);
	return 0;
}
