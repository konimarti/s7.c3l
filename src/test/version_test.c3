module s7;

import s7tool;

// In the library's own test build the library is the top-level project, so env::PROJECT_VERSION is the version of
// project.json: the constant of the library must equal it (tools/bump_version.c3 changes both).
fn void version_matches_project_json() @test
{
	assert(s7::VERSION == env::PROJECT_VERSION, "VERSION %s but project.json says %s", s7::VERSION, env::PROJECT_VERSION);
}

fn void test_version_is_major_minor_patch() @test
{
	String v = s7::VERSION;
	int dots = 0;
	foreach (c : v)
	{
		if (c == '.')
		{
			dots++;
		}
		else
		{
			assert(c >= '0' && c <= '9', "version %s", v);
		}
	}
	assert(dots == 2 && v.len >= 5);
}

fn void test_the_tool_has_a_version_option() @test
{
	String[2] args = { "s7tool", "--version" };
	s7tool::Options o = s7tool::default_options();
	s7tool::parse_options(args[..], &o)!!;
	assert(o.version && !o.help);
	// no command and no host are needed
	String[3] with_command = { "s7tool", "--version", "info" };
	s7tool::Options p = s7tool::default_options();
	s7tool::parse_options(with_command[..], &p)!!;
	assert(p.version);
}
