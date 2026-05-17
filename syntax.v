module main

// SPDX-License-Identifier: MPL-2.0
import os
import regex
import strings

fn syntax_user_dir() string {
	return os.join_path(os.home_dir(), '.config', 'vro', 'syntax')
}

fn syntax_data_home_dir() string {
	xdg := os.getenv('XDG_DATA_HOME')
	if xdg.len > 0 {
		return os.join_path(xdg, 'vro', 'syntax')
	}
	return os.join_path(os.home_dir(), '.local', 'share', 'vro', 'syntax')
}

fn syntax_executable_dirs() []string {
	exe := os.executable()
	if exe.len == 0 {
		return []string{}
	}
	dir := os.dir(exe)
	parent := os.dir(dir)
	return [
		os.join_path(dir, 'syntax'),
		os.join_path(parent, 'share', 'vro', 'syntax'),
		os.join_path(parent, 'share', 'vro'),
	]
}

fn syntax_runtime_dirs() []string {
	mut dirs := []string{}
	env_dir := os.getenv('VRO_SYNTAX_DIR')
	if env_dir.len > 0 {
		for part in env_dir.split(os.path_delimiter) {
			if part.len > 0 {
				dirs << part
			}
		}
	}
	dirs << syntax_user_dir()
	dirs << os.join_path(os.getwd(), 'syntax')
	dirs << syntax_data_home_dir()
	dirs << syntax_executable_dirs()
	dirs << '/opt/homebrew/share/vro/syntax'
	dirs << '/usr/local/share/vro/syntax'
	dirs << '/usr/share/vro/syntax'
	return dirs
}

fn load_syntax_yaml_from_dir(dir string, ft string) ?(string, string) {
	path := os.join_path(dir, '${ft}.yaml')
	if os.exists(path) {
		src := os.read_file(path) or { return none }
		return src, path
	}
	return none
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
	kind  YamlRuleKind
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
	st       regex.RE
	en       regex.RE
	sk       regex.RE
	has_skip bool
}

enum CompRuleKind {
	pat
	reg
}

struct CompiledRule {
	kind  CompRuleKind
	group string
mut:
	pat CompiledPat
	reg CompiledReg
}

struct CompiledSyntax {
mut:
	filename_pat regex.RE
	has_detect   bool
	rules        []CompiledRule
	source       string
}

fn patch_v_regex(pat string) string {
	mut b := strings.new_builder(pat.len)
	mut i := 0
	mut in_class := false
	mut class_start := 0
	mut escaped := false
	for i < pat.len {
		c := pat[i]
		if escaped {
			b.write_u8(c)
			escaped = false
			i++
			continue
		}
		if c == `\\` {
			b.write_u8(c)
			escaped = true
			i++
			continue
		}
		if in_class {
			if i == class_start + 1 || (i == class_start + 2 && pat[class_start + 1] == `^`) {
				// first char inside class (or after ^)
				if c == `]` {
					b.write_u8(`\\`)
					b.write_u8(c)
					i++
					continue
				}
			}
			if c == `]` {
				in_class = false
			}
		} else if c == `[` {
			in_class = true
			class_start = i
		}
		b.write_u8(c)
		i++
	}
	return b.str()
}

fn compile_one_re(pat string) !regex.RE {
	p2 := pat.replace('\\b', '')
	p3 := patch_v_regex(p2)
	mut re, err, _ := regex.regex_base(p3)
	if err != regex.compile_ok {
		return error('regex compile ${err}: ${pat}')
	}
	return re
}

fn compile_maybe_re(pat string) ?regex.RE {
	p2 := pat.replace('\\b', '')
	p3 := patch_v_regex(p2)
	mut re, err, _ := regex.regex_base(p3)
	if err != regex.compile_ok {
		return none
	}
	return re
}

fn split_top_level_alternation(pat string) []string {
	if pat.len < 3 || pat[0] != `(` || pat[pat.len - 1] != `)` {
		return [pat]
	}
	inner := pat[1..pat.len - 1]
	mut parts := []string{}
	mut start := 0
	mut depth := 0
	mut in_class := false
	mut escaped := false
	for i, ch in inner {
		if escaped {
			escaped = false
			continue
		}
		if ch == `\\` {
			escaped = true
			continue
		}
		if in_class {
			if ch == `]` {
				in_class = false
			}
			continue
		}
		match ch {
			`[` {
				in_class = true
			}
			`(` {
				depth++
			}
			`)` {
				if depth > 0 {
					depth--
				}
			}
			`|` {
				if depth == 0 {
					parts << inner[start..i]
					start = i + 1
				}
			}
			else {}
		}
	}
	if parts.len == 0 {
		return [pat]
	}
	parts << inner[start..]
	return parts
}

fn compile_syntax_from_yaml(src string) !CompiledSyntax {
	rules := parse_syntax_yaml(src)!
	mut out := CompiledSyntax{}
	for r in rules {
		match r.kind {
			.pat {
				for part in split_top_level_alternation(r.pat) {
					re := compile_one_re(part) or { continue }
					out.rules << CompiledRule{
						kind:  .pat
						group: r.group
						pat:   CompiledPat{
							group: r.group
							re:    re
						}
					}
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
					reg:   CompiledReg{
						group:    r.group
						st:       st
						en:       en
						sk:       skre
						has_skip: hsk
					}
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
				rules << YamlRule{
					kind:  .pat
					group: group
					pat:   pat
				}
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
				rules << YamlRule{
					kind:  .reg
					group: group
					st:    st
					en:    en
					sk:    sk
				}
			}
			continue
		}
		i++
	}
	return rules
}

@[inline]
fn group_to_ansi(group string) string {
	g := group.to_lower()
	if g.starts_with('comment') {
		return '\x1b[90m'
	}
	if g.starts_with('constant.string') || g.contains('string') {
		return '\x1b[92m'
	}
	if g.starts_with('constant.number') || g.contains('number') {
		return '\x1b[36m'
	}
	if g.starts_with('keyword') || g == 'statement' || g == 'preproc' {
		return '\x1b[94m'
	}
	if g.contains('type') {
		return '\x1b[96m'
	}
	if g.contains('symbol') || g.contains('operator') {
		return '\x1b[37m'
	}
	return '\x1b[97m'
}

// Find end pattern from search (same skip rules as micro-style regions).
fn hl_region_find_end(mut cr CompiledReg, line string, search int) int {
	mut s := search
	for s <= line.len {
		es2, ee2 := cr.en.find_from(line, s)
		if es2 >= 0 && ee2 > es2 {
			return ee2
		}
		if cr.has_skip {
			ssk, esk := cr.sk.find_from(line, s)
			if ssk >= 0 && esk > ssk && (es2 < 0 || ssk <= es2) {
				s = esk
				continue
			}
		}
		break
	}
	return -1
}

// carry_in: region opened on a previous line without a closing end yet.
// Returns carry_out: true if the region is still unclosed at end of this line.
fn hl_apply_region(mut owners []int, mut groups []string, line string, ri int, mut cr CompiledReg, carry_in bool) bool {
	mut pos := 0
	if carry_in {
		end_abs := hl_region_find_end(mut cr, line, 0)
		if end_abs < 0 {
			for k := 0; k < line.len; k++ {
				if owners[k] == -1 {
					owners[k] = ri
					groups[k] = cr.group
				}
			}
			return true
		}
		for k := 0; k < end_abs && k < line.len; k++ {
			if owners[k] == -1 {
				owners[k] = ri
				groups[k] = cr.group
			}
		}
		pos = end_abs
	}
	for pos < line.len {
		st, en := cr.st.find_from(line, pos)
		if st < 0 {
			break
		}
		if en <= st {
			pos++
			continue
		}
		search := en
		end_abs := hl_region_find_end(mut cr, line, search)
		if end_abs < 0 {
			for k := st; k < line.len; k++ {
				if owners[k] == -1 {
					owners[k] = ri
					groups[k] = cr.group
				}
			}
			return true
		}
		for k := st; k < end_abs && k < line.len; k++ {
			if owners[k] == -1 {
				owners[k] = ri
				groups[k] = cr.group
			}
		}
		pos = end_abs
	}
	return false
}

// Region carry only (no coloring). Must stay in sync with hl_apply_region.
fn hl_reg_carry_through_line(mut cr CompiledReg, line string, carry_in bool) bool {
	mut pos := 0
	if carry_in {
		end_abs := hl_region_find_end(mut cr, line, 0)
		if end_abs < 0 {
			return true
		}
		pos = end_abs
	}
	for pos < line.len {
		st, en := cr.st.find_from(line, pos)
		if st < 0 {
			break
		}
		if en <= st {
			pos++
			continue
		}
		end_abs := hl_region_find_end(mut cr, line, en)
		if end_abs < 0 {
			return true
		}
		pos = end_abs
	}
	return false
}

fn hl_carry_row(mut syn CompiledSyntax, line string, carry []bool) []bool {
	mut next := []bool{len: syn.rules.len, init: false}
	for ri in 0 .. syn.rules.len {
		match syn.rules[ri].kind {
			.pat {
				next[ri] = false
			}
			.reg {
				mut r := syn.rules[ri].reg
				ci := ri < carry.len && carry[ri]
				next[ri] = hl_reg_carry_through_line(mut r, line, ci)
			}
		}
	}
	return next
}

fn hl_apply_pattern(mut owners []int, mut groups []string, line string, ri int, mut cp CompiledPat) {
	mut pos := 0
	for pos < line.len {
		st, en := cp.re.find_from(line, pos)
		if st < 0 {
			break
		}
		if en <= st {
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

fn hl_fill_owners(mut syn CompiledSyntax, line string, carry_in []bool) ([]int, []string, []bool) {
	mut owners := []int{len: line.len, init: -1}
	mut groups := []string{len: line.len, init: ''}
	mut carry_out := []bool{len: syn.rules.len, init: false}
	for ri in 0 .. syn.rules.len {
		match syn.rules[ri].kind {
			.pat {
				mut p := syn.rules[ri].pat
				hl_apply_pattern(mut owners, mut groups, line, ri, mut p)
				syn.rules[ri].pat = p
				carry_out[ri] = false
			}
			.reg {
				mut r := syn.rules[ri].reg
				ci := if ri < carry_in.len { carry_in[ri] } else { false }
				co := hl_apply_region(mut owners, mut groups, line, ri, mut r, ci)
				syn.rules[ri].reg = r
				carry_out[ri] = co
			}
		}
	}
	return owners, groups, carry_out
}

// Emit logical slice [coloff .. coloff+width) with ANSI (escapes are zero-width in terminal).
// carry_in: per-rule region continuation from previous physical line (see editor hl_carry_enter).
fn hl_draw_line_slice(mut syn CompiledSyntax, line string, coloff int, width int, carry_in []bool, mut ab strings.Builder) {
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
	owners, groups, _ := hl_fill_owners(mut syn, line, carry_in)
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

// Emit slice using pre-computed owners/groups (hot path for cached rows).
fn hl_draw_line_slice_cached(owners []int, groups []string, line string, coloff int, width int, mut ab strings.Builder) {
	mut i := coloff
	mut limit := coloff + width
	if limit > line.len {
		limit = line.len
	}
	if owners.len != line.len {
		// cache out of sync – fall through to identity emit
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
	for i < limit {
		if owners[i] == -1 {
			ab.write_u8(line[i])
			i++
			continue
		}
		g := groups[i]
		ab.write_string(group_to_ansi(g))
		for i < limit && owners[i] != -1 && groups[i] == g {
			ab.write_u8(line[i])
			i++
		}
		ab.write_string('\x1b[0m')
	}
}

// Micro-style syntax bundle names (see micro runtime/syntax/*.yaml).
fn syntax_name_for_ext(ext string) string {
	return match ext {
		'.v', '.vv', '.vsh' {
			'v'
		}
		'.go' {
			'go'
		}
		'.rs' {
			'rust'
		}
		'.c', '.h' {
			'c'
		}
		'.py', '.pyw' {
			'python3'
		}
		'.js', '.mjs', '.cjs' {
			'javascript'
		}
		'.ts', '.tsx' {
			'typescript'
		}
		'.json' {
			'json'
		}
		'.yaml', '.yml' {
			'yaml'
		}
		'.md', '.mdx' {
			'markdown'
		}
		'.sh', '.bash', '.zsh' {
			'sh'
		}
		'.toml' {
			'toml'
		}
		'.html', '.htm' {
			'html'
		}
		'.css' {
			'css'
		}
		'.sql' {
			'sql'
		}
		'.zig' {
			'zig'
		}
		'.cc', '.cxx', '.cpp', '.hpp', '.hxx' {
			'cpp'
		}
		else {
			if ext.len > 1 && ext[0] == `.` {
				return ext[1..]
			}
			''
		}
	}
}

fn load_syntax_for_path(path string) ?CompiledSyntax {
	ext := os.file_ext(path)
	mut yaml_src := ''
	mut source_name := ''
	ft := syntax_name_for_ext(ext)
	if ft.len > 0 {
		for dir in syntax_runtime_dirs() {
			if src, source := load_syntax_yaml_from_dir(dir, ft) {
				yaml_src = src
				source_name = source
				break
			}
		}
	}
	if yaml_src.len == 0 {
		return none
	}
	mut syn := compile_syntax_from_yaml(yaml_src) or { return none }
	syn.source = source_name
	return syn
}
