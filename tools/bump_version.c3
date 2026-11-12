module bump_version;

import std::io, std::io::file;

// Sets the version of the library in project.json ("version": "...") and in the constant of the main module file
// (const String VERSION = "...";). Run it from the repository root:
//
//     c3c compile-run tools/bump_version.c3 -- 0.2.0
//
// The argument must be MAJOR.MINOR.PATCH. Each pattern has to occur exactly once, otherwise nothing is written and the
// exit status is 1. The two changed lines are printed.

const String MAIN_FILE = "s7.c3";
const String JSON_FILE = "project.json";
const String JSON_PREFIX = "\"version\": \"";
const String CONST_PREFIX = "const String VERSION = \"";

fn bool valid_version(String v)
{
	int dots = 0;
	usz digits = 0;
	foreach (c : v)
	{
		if (c == '.')
		{
			if (digits == 0) return false;
			dots++;
			digits = 0;
		}
		else if (c >= '0' && c <= '9')
		{
			digits++;
		}
		else
		{
			return false;
		}
	}
	return dots == 2 && digits > 0;
}

// Number of occurrences of `needle` in `text`; `first` is where the first one starts.
fn usz count_of(String text, String needle, usz* first)
{
	usz count = 0;
	if (needle.len == 0 || text.len < needle.len) return 0;
	for (usz i = 0; i + needle.len <= text.len; i++)
	{
		if (text[i:needle.len] == needle)
		{
			if (count == 0) *first = i;
			count++;
		}
	}
	return count;
}

faultdef BAD_PATTERN;

// `text` with the quoted version after `prefix` replaced; fails unless `prefix` occurs exactly once and is closed by a quote.
// `old_line` and `new_line` receive the line before and after.
fn String? replace_version(String text, String prefix, String version, String* old_line, String* new_line)
{
	usz first;
	if (count_of(text, prefix, &first) != 1) return BAD_PATTERN~;
	usz start = first + prefix.len;
	usz end = start;
	while (end < text.len && text[end] != '"')
	{
		if (text[end] == '\n') return BAD_PATTERN~;
		end++;
	}
	if (end >= text.len) return BAD_PATTERN~;
	String result = string::tformat("%s%s%s", text[:start], version, text[end..]);
	usz line_start = first;
	while (line_start > 0 && text[line_start - 1] != '\n') line_start--;
	usz old_end = end;
	while (old_end < text.len && text[old_end] != '\n') old_end++;
	usz new_end = end + version.len - (end - start);
	while (new_end < result.len && result[new_end] != '\n') new_end++;
	*old_line = text[line_start:old_end - line_start];
	*new_line = result[line_start:new_end - line_start];
	return result;
}

fn int main(String[] args)
{
	if (args.len != 2 || !valid_version(args[1]))
	{
		io::eprintn("usage: bump_version MAJOR.MINOR.PATCH   (run from the repository root)");
		return 1;
	}
	String version = args[1];
	String? json = (String)file::load_temp(JSON_FILE);
	String? main_text = (String)file::load_temp(MAIN_FILE);
	if (catch e1 = json)
	{
		io::eprintfn("cannot read %s", JSON_FILE);
		return 1;
	}
	if (catch e2 = main_text)
	{
		io::eprintfn("cannot read %s", MAIN_FILE);
		return 1;
	}
	String old_json;
	String new_json;
	String old_main;
	String new_main;
	String? json_out = replace_version(json, JSON_PREFIX, version, &old_json, &new_json);
	if (catch e3 = json_out)
	{
		io::eprintfn("%s: the pattern %s must occur exactly once; nothing was changed", JSON_FILE, JSON_PREFIX);
		return 1;
	}
	String? main_out = replace_version(main_text, CONST_PREFIX, version, &old_main, &new_main);
	if (catch e4 = main_out)
	{
		io::eprintfn("%s: the pattern %s must occur exactly once; nothing was changed", MAIN_FILE, CONST_PREFIX);
		return 1;
	}
	if (catch e5 = file::save(JSON_FILE, json_out))
	{
		io::eprintfn("cannot write %s", JSON_FILE);
		return 1;
	}
	if (catch e6 = file::save(MAIN_FILE, main_out))
	{
		io::eprintfn("cannot write %s (%s was already changed)", MAIN_FILE, JSON_FILE);
		return 1;
	}
	io::printfn("%s:\n  - %s\n  + %s", JSON_FILE, old_json.trim(), new_json.trim());
	io::printfn("%s:\n  - %s\n  + %s", MAIN_FILE, old_main.trim(), new_main.trim());
	return 0;
}
