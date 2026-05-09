module main

import os
import regex
import strings

const builtin_v_yaml = $embed_file('syntax/v.yaml').to_string()

fn syntax_user_dir() string {
	return os.join_path(os.home_dir(), '.config', 'vro', 'syntax')
}

fn leading_spaces(line string) int {
	mut n := 0
	for n < line.len {
		if line[n] != ` ` && line[n] != `\t` {
			break
		}
		n++
	}
	return n
}

fn trim_line_end(line string) string {
	return line.trim_right(' \t\r')
}

// Unquote a YAML double-quoted string (one line).
fn unquote_dquoted(s string) !string {
	if s.len < 2 || s[0] != `"` {
		return error('expected opening quote')
	}
	mut out := strings.new_builder(s.len)
	mut i := 1
	for i < s.len {
		c := s[i]
		if c == `\\` && i + 1 < s.len {
			out.write_u8(s[i + 1])
			i += 2
			continue
		}
		if c == `"` {
			return out.str()
		}
		out.write_u8(c)
		i++
	}
	return error('unclosed quote')
}

struct YamlPat {
	group string
	pat   string
}

struct YamlReg {
	group string
	start string
	end   string
	skip  string
}

enum YamlRuleKind {
	pat
	reg
}

struct YamlRule {
	kind YamlRuleKind
	group string
	pat   string
	st    string
	en    string
	sk    string
}

struct CompiledPat {
	group string
mut:
	re regex.RE
}

struct CompiledReg {
	group string
mut:
	st regex.RE
	en regex.RE
	sk regex.RE
	has_skip bool
}

enum CompRuleKind {
	pat
	reg
}

struct CompiledRule {
	kind CompRuleKind
	group string
mut:
	pat CompiledPat
	reg CompiledReg
}

struct CompiledSyntax {
mut:
	filename_pat regex.RE
	has_detect     bool
	rules          []CompiledRule
}

fn compile_one_re(pat string) !regex.RE {
	p2 := pat.replace('\\b', '')
	mut re, err, _ := regex.regex_base(p2)
	if err != regex.compile_ok {
		return error('regex compile ${err}: ${pat}')
	}
	return re
}

fn compile_maybe_re(pat string) ?regex.RE {
	p2 := pat.replace('\\b', '')
	mut re, err, _ := regex.regex_base(p2)
	if err != regex.compile_ok {
		return none
	}
	return re
}

fn compile_syntax_from_yaml(src string) !CompiledSyntax {
	rules := parse_syntax_yaml(src)!
	mut out := CompiledSyntax{}
	for r in rules {
		match r.kind {
			.pat {
				re := compile_one_re(r.pat) or { continue }
				out.rules << CompiledRule{
					kind:  .pat
					group: r.group
					pat:   CompiledPat{ group: r.group, re: re }
				}
			}
			.reg {
				st := compile_one_re(r.st) or { continue }
				en := compile_one_re(r.en) or { continue }
				mut skre := regex.RE{}
				mut hsk := false
				if r.sk.len > 0 {
					if sk := compile_maybe_re(r.sk) {
						skre = sk
						hsk = true
					}
				}
				out.rules << CompiledRule{
					kind:  .reg
					group: r.group
					reg:   CompiledReg{ group: r.group, st: st, en: en, sk: skre, has_skip: hsk }
				}
			}
		}
	}
	// detect.filename
	detect_re := parse_detect_filename(src) or { '' }
	if detect_re.len > 0 {
		re := compile_one_re(detect_re)!
		out.filename_pat = re
		out.has_detect = true
	}
	return out
}

fn parse_detect_filename(src string) ?string {
	for raw in src.split_into_lines() {
		line := trim_line_end(raw)
		t := line.trim_space()
		if t.len == 0 || t[0] == `#` {
			continue
		}
		if t.starts_with('filename:') {
			val := t['filename:'.len..].trim_space()
			return unquote_dquoted(val) or { return none }
		}
	}
	return none
}

fn parse_syntax_yaml(src string) ![]YamlRule {
	mut rules := []YamlRule{}
	lines := src.split_into_lines()
	mut i := 0
	mut in_rules := false
	mut rules_base_indent := -1
	for i < lines.len {
		line := trim_line_end(lines[i])
		t := line.trim_space()
		if t.len == 0 || t[0] == `#` {
			i++
			continue
		}
		ind := leading_spaces(line)
		if !in_rules {
			if t == 'rules:' || t.starts_with('rules:') {
				in_rules = true
				rules_base_indent = ind
				i++
				continue
			}
			i++
			continue
		}
		// in rules: exit if dedented section
		if ind <= rules_base_indent && !t.starts_with('-') && t.contains(':') {
			break
		}
		if t.starts_with('-') {
			rest := t[1..].trim_space()
			colon := rest.index(':') or { -1 }
			if colon < 0 {
				i++
				continue
			}
			group := rest[..colon].trim_space()
			val := rest[colon + 1..].trim_space()
			rule_line_ind := ind
			if val.len > 0 && val[0] == `"` {
				pat := unquote_dquoted(val)!
				rules << YamlRule{ kind: .pat, group: group, pat: pat }
				i++
				continue
			}
			// region: read indented keys
			mut st := ''
			mut en := ''
			mut sk := ''
			i++
			for i < lines.len {
				l2 := trim_line_end(lines[i])
				if l2.trim_space().len == 0 || l2.trim_space()[0] == `#` {
					i++
					continue
				}
				in2 := leading_spaces(l2)
				if in2 <= rule_line_ind {
					break
				}
				t2 := l2.trim_space()
				if t2.starts_with('start:') {
					v := t2['start:'.len..].trim_space()
					st = unquote_dquoted(v)!
				} else if t2.starts_with('end:') {
					v := t2['end:'.len..].trim_space()
					en = unquote_dquoted(v)!
				} else if t2.starts_with('skip:') {
					v := t2['skip:'.len..].trim_space()
					sk = unquote_dquoted(v)!
				} else if t2.starts_with('rules:') {
					// skip nested rules block for v1
				}
				i++
			}
			if st.len > 0 && en.len > 0 {
				rules << YamlRule{ kind: .reg, group: group, st: st, en: en, sk: sk }
			}
			continue
		}
		i++
	}
	return rules
}

fn group_to_ansi(group string) string {
	g := group.to_lower()
	if g.starts_with('comment') {
		return '\x1b[2m\x1b[32m'
	}
	if g.starts_with('constant.string') || g.contains('string') {
		return '\x1b[33m'
	}
	if g.starts_with('constant.number') || g.contains('number') {
		return '\x1b[36m'
	}
	if g.starts_with('keyword') || g == 'statement' || g == 'preproc' {
		return '\x1b[35m'
	}
	if g.contains('type') {
		return '\x1b[34m'
	}
	if g.contains('symbol') || g.contains('operator') {
		return '\x1b[37m'
	}
	return '\x1b[96m'
}

fn hl_apply_region(mut owners []int, mut groups []string, line string, ri int, mut cr CompiledReg) {
	mut pos := 0
	for pos < line.len {
		st, en := cr.st.find_from(line, pos)
		if st < 0 || en <= st {
			pos++
			continue
		}
		mut search := en
		mut end_abs := -1
		for search <= line.len {
			es2, ee2 := cr.en.find_from(line, search)
			if es2 >= 0 && ee2 > es2 {
				end_abs = ee2
				break
			}
			if cr.has_skip {
				ssk, esk := cr.sk.find_from(line, search)
				if ssk >= 0 && esk > ssk && (es2 < 0 || ssk <= es2) {
					search = esk
					continue
				}
			}
			break
		}
		if end_abs < 0 {
			for k := st; k < line.len; k++ {
				if owners[k] == -1 {
					owners[k] = ri
					groups[k] = cr.group
				}
			}
			return
		}
		for k := st; k < end_abs && k < line.len; k++ {
			if owners[k] == -1 {
				owners[k] = ri
				groups[k] = cr.group
			}
		}
		pos = end_abs
	}
}

fn hl_apply_pattern(mut owners []int, mut groups []string, line string, ri int, mut cp CompiledPat) {
	mut pos := 0
	for pos < line.len {
		st, en := cp.re.find_from(line, pos)
		if st < 0 || en <= st {
			pos++
			continue
		}
		for k := st; k < en && k < line.len; k++ {
			if owners[k] == -1 {
				owners[k] = ri
				groups[k] = cp.group
			}
		}
		pos = en
	}
}

fn hl_fill_owners(mut syn CompiledSyntax, line string) ([]int, []string) {
	mut owners := []int{len: line.len, init: -1}
	mut groups := []string{len: line.len, init: ''}
	for ri in 0 .. syn.rules.len {
		match syn.rules[ri].kind {
			.pat {
				mut p := syn.rules[ri].pat
				hl_apply_pattern(mut owners, mut groups, line, ri, mut p)
				syn.rules[ri].pat = p
			}
			.reg {
				mut r := syn.rules[ri].reg
				hl_apply_region(mut owners, mut groups, line, ri, mut r)
				syn.rules[ri].reg = r
			}
		}
	}
	return owners, groups
}

// Emit logical slice [coloff .. coloff+width) with ANSI (escapes are zero-width in terminal).
fn hl_draw_line_slice(mut syn CompiledSyntax, line string, coloff int, width int, mut ab strings.Builder) {
	if syn.rules.len == 0 || line.len == 0 || width <= 0 {
		if line.len > coloff {
			mut n := line.len - coloff
			if n > width {
				n = width
			}
			if n > 0 {
				ab.write_string(line[coloff..coloff + n])
			}
		}
		return
	}
	owners, groups := hl_fill_owners(mut syn, line)
	mut i := coloff
	mut limit := coloff + width
	if limit > line.len {
		limit = line.len
	}
	for {
		if i >= limit {
			break
		}
		if owners[i] == -1 {
			ab.write_u8(line[i])
			i++
			continue
		}
		g := groups[i]
		ab.write_string(group_to_ansi(g))
		for {
			if i >= limit || owners[i] == -1 || groups[i] != g {
				break
			}
			ab.write_u8(line[i])
			i++
		}
		ab.write_string('\x1b[0m')
	}
}

fn syntax_matches_path(syn &CompiledSyntax, path string) bool {
	if !syn.has_detect {
		return true
	}
	base := os.base(path)
	mut re := syn.filename_pat
	s, e2 := re.find(base)
	return s >= 0 && e2 > s
}

fn load_syntax_for_path(path string) ?CompiledSyntax {
	ext := os.file_ext(path)
	mut yaml_src := ''
	// Map common extensions to micro-style filenames (lazy: try one name).
	ft := match ext {
		'.v', '.vv', '.vsh' { 'v' }
		else { '' }
	}
	if ft.len > 0 {
		userp := os.join_path(syntax_user_dir(), '${ft}.yaml')
		if os.exists(userp) {
			yaml_src = os.read_file(userp) or { '' }
		}
	}
	if yaml_src.len == 0 && ft == 'v' {
		yaml_src = builtin_v_yaml
	}
	if yaml_src.len == 0 {
		return none
	}
	mut syn := compile_syntax_from_yaml(yaml_src) or { return none }
	if !syntax_matches_path(&syn, path) {
		return none
	}
	return syn
}
