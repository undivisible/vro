module main

import os
import strings
import term.ui as tui

fn strip_ansi(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		if s[i] == 0x1b && i + 1 < s.len && s[i + 1] == `[` {
			i += 2
			for i < s.len && !((s[i] >= `A` && s[i] <= `Z`) || (s[i] >= `a` && s[i] <= `z`)) {
				i++
			}
			if i < s.len {
				i++
			}
			continue
		}
		out.write_u8(s[i])
		i++
	}
	return out.str()
}

fn test_vro_version() {
	assert vro_version == '1.1.5'
}

fn test_syntax_name_for_ext() {
	assert syntax_name_for_ext('.v') == 'v'
	assert syntax_name_for_ext('.cpp') == 'cpp'
	assert syntax_name_for_ext('.nim') == 'nim'
}

fn test_is_unsigned_decimal_int_string() {
	assert !is_unsigned_decimal_int_string('')
	assert !is_unsigned_decimal_int_string('12a')
	assert !is_unsigned_decimal_int_string('-3')
	assert !is_unsigned_decimal_int_string('  ')
	assert is_unsigned_decimal_int_string('42')
	assert is_unsigned_decimal_int_string('  7  ')
}

fn test_hl_carry_multiline_block_comment() {
	y := 'filetype: z\nrules:\n  - comment:\n      start: "/\\*"\n      end: "\\*/"\n'
	mut syn := compile_syntax_from_yaml(y)!
	mut c := []bool{len: syn.rules.len, init: false}
	c = hl_carry_row(mut syn, '/* open', c)
	assert c[0] == true
	c = hl_carry_row(mut syn, '  x', c)
	assert c[0] == true
	c = hl_carry_row(mut syn, '*/ close', c)
	assert c[0] == false
}

fn setup_test_v_syntax_dir() !(string, string) {
	dir := os.join_path(os.temp_dir(), 'vro-test-v-syntax')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	v_yaml := 'filetype: v
detect:
  filename: "\\\\.(v|vv|vsh)\$"
rules:
  - comment: "//.*"
  - comment:
      start: "/\\\\*"
      end: "\\\\*/"
  - constant.string:
      start: "\\""
      end: "\\""
      skip: "\\\\."
  - keyword: "(fn|mut|pub|return|import|module|struct|enum|if|else|for|true|false|none|nil)"
  - constant.number: "[0-9]+"
  - symbol.brackets: "(\\\\{|\\\\}|\\\\(|\\\\)|\\\\[|\\\\])"
'
	os.write_file(os.join_path(dir, 'v.yaml'), v_yaml)!
	old := os.getenv('VRO_SYNTAX_DIR')
	os.setenv('VRO_SYNTAX_DIR', dir, true)
	return dir, old
}

fn teardown_test_v_syntax_dir(dir string, old string) {
	if old.len > 0 {
		os.setenv('VRO_SYNTAX_DIR', old, true)
	} else {
		os.unsetenv('VRO_SYNTAX_DIR')
	}
	os.rmdir_all(dir) or {}
}

fn test_bundled_v_syntax_highlights_keywords() {
	dir, old := setup_test_v_syntax_dir()!
	defer {
		teardown_test_v_syntax_dir(dir, old)
	}
	mut syn := load_syntax_for_path('main.v') or { panic('missing v syntax') }
	mut ab := strings.new_builder(64)
	hl_draw_line_slice(mut syn, 'fn main() {', 0, 11, []bool{}, mut ab)
	out := ab.str()
	assert out.contains('\x1b[35mfn\x1b[0m')
	assert out.contains('\x1b[37m(')
}

fn test_bundled_v_line_comments_do_not_carry() {
	dir, old := setup_test_v_syntax_dir()!
	defer {
		teardown_test_v_syntax_dir(dir, old)
	}
	mut syn := load_syntax_for_path('main.v') or { panic('missing v syntax') }
	carry := []bool{len: syn.rules.len, init: false}
	next := hl_carry_row(mut syn, '// comment', carry)
	assert !next.any(it)
	mut ab := strings.new_builder(64)
	hl_draw_line_slice(mut syn, 'import os', 0, 9, next, mut ab)
	out := ab.str()
	assert out.contains('\x1b[35mimport\x1b[0m')
	assert !out.contains('\x1b[32mimport')
}

fn test_markdown_syntax_highlights_heading_and_links() {
	y := 'filetype: markdown
detect:
  filename: "\\\\.md$"
rules:
  - special: "^#{1,6}.*"
  - constant: "\\[[^]]+\\]"
  - constant: "https?://[^ )>]+"
  - statement: "^>.*"
  - type: "\\*\\*[^*]*\\*\\*"
'
	mut syn := compile_syntax_from_yaml(y) or { panic('markdown compile: ${err}') }
	assert syn.rules.len > 0
	mut ab := strings.new_builder(64)
	hl_draw_line_slice(mut syn, '# Hello', 0, 7, []bool{}, mut ab)
	out := ab.str()
	assert out.contains('\x1b[32m')
	assert out.contains('Hello')
	assert out.contains('\x1b[0m')
}

fn test_markdown_inline_code_does_not_carry_across_bullet_text() {
	src := os.read_file('syntax/markdown.yaml')!
	mut syn := compile_syntax_from_yaml(src)!
	line := '- `right <path>` / `left <path>` / `top <path>` / `bottom <path>` opens a file in a split'
	owners, groups, carry := hl_fill_owners(mut syn, line, []bool{})
	assert !carry.any(it)
	inline := '`right <path>`'
	code_at := line.index(inline) or { panic('missing inline code') }
	for i in code_at .. code_at + inline.len {
		assert groups[i] == 'special'
	}
	sep := ' / '
	sep_at := line.index_after(sep, code_at + inline.len) or { panic('missing separator') }
	for i in sep_at .. sep_at + sep.len {
		assert groups[i] != 'special'
		assert groups[i] != 'preproc'
		assert groups[i] != 'statement'
	}
	plain := ' opens a file in a split'
	at := line.index(plain) or { panic('missing plain text') }
	for i in at .. line.len {
		assert i < owners.len
		assert groups[i] != 'special'
	}
}

fn test_dynamic_syntax_dir_loads_unknown_extension() {
	old := os.getenv('VRO_SYNTAX_DIR')
	dir := os.join_path(os.temp_dir(), 'vro-dynamic-syntax-test')
	defer {
		if old.len > 0 {
			os.setenv('VRO_SYNTAX_DIR', old, true)
		} else {
			os.unsetenv('VRO_SYNTAX_DIR')
		}
		os.rmdir_all(dir) or {}
	}
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'foo.yaml'), 'filetype: foo\nrules:\n  - keyword: "zap"\n')!
	os.setenv('VRO_SYNTAX_DIR', dir, true)
	mut syn := load_syntax_for_path('demo.foo') or { panic('missing dynamic syntax') }
	assert syn.source == os.join_path(dir, 'foo.yaml')
	mut ab := strings.new_builder(64)
	hl_draw_line_slice(mut syn, 'zap value', 0, 9, []bool{}, mut ab)
	assert ab.str().contains('\x1b[35mzap\x1b[0m')
}

fn test_local_syntax_reports_source() {
	dir, old := setup_test_v_syntax_dir()!
	defer {
		teardown_test_v_syntax_dir(dir, old)
	}
	mut syn := load_syntax_for_path('demo.v') or { panic('missing v syntax') }
	assert syn.source == os.join_path(dir, 'v.yaml')
}

fn test_unquote_single_quoted_yaml() {
	assert unquote_dquoted("'hello'") or { panic(err.str()) } == 'hello'
	assert unquote_dquoted("'\\\\.'") or { panic(err.str()) } == '\\\\.'
	assert unquote_dquoted("'it''s'") or { panic(err.str()) } == "it's"
	_ := unquote_dquoted("'unclosed") or { 'err' }
}

fn test_bundled_rust_syntax_loads_despite_single_quoted_skip() {
	src := os.read_file('syntax/rust.yaml')!
	mut syn := compile_syntax_from_yaml(src)!
	assert syn.rules.len > 0
	mut ab := strings.new_builder(64)
	hl_draw_line_slice(mut syn, 'fn main() {}', 0, 12, []bool{}, mut ab)
	out := ab.str()
	assert out.contains('fn')
}

fn test_bundled_toml_syntax_loads_despite_single_quoted_skip() {
	src := os.read_file('syntax/toml.yaml')!
	mut syn := compile_syntax_from_yaml(src)!
	assert syn.rules.len > 0
}

fn test_embedded_syntax_yaml_returns_rust() {
	src := embedded_syntax_yaml('rust') or {
		assert false
		return
	}
	assert src.len > 0
	mut syn := compile_syntax_from_yaml(src)!
	assert syn.rules.len > 0
}

fn test_embedded_syntax_yaml_returns_none_for_unknown() {
	src := embedded_syntax_yaml('nonexistent_lang') or { return }
	assert false
}

fn test_load_syntax_for_path_falls_back_to_embedded() {
	// With VRO_SYNTAX_DIR pointing to a nonexistent dir and cwd outside
	// the repo, the only source for syntax YAML should be the embedded
	// copy compiled into the binary.
	old_dir := os.getwd()
	old_env := os.getenv('VRO_SYNTAX_DIR')
	os.chdir(os.temp_dir()) or {}
	os.setenv('VRO_SYNTAX_DIR', '/nonexistent/path', true)
	defer {
		os.chdir(old_dir) or {}
		os.setenv('VRO_SYNTAX_DIR', old_env, true)
	}
	syn := load_syntax_for_path('test.rs') or {
		assert false
		return
	}
	assert syn.rules.len > 0
	assert syn.source.starts_with('embedded:')
}

fn syntax_group_at(mut syn CompiledSyntax, line string, needle string) string {
	owners, groups, _ := hl_fill_owners(mut syn, line, []bool{})
	at := line.index(needle) or { panic('missing needle ${needle}') }
	for i in at .. at + needle.len {
		if i < owners.len && owners[i] != -1 {
			return groups[i]
		}
	}
	return ''
}

fn syntax_group_at_offset(mut syn CompiledSyntax, line string, needle string, offset int) string {
	owners, groups, _ := hl_fill_owners(mut syn, line, []bool{})
	at := line.index(needle) or { panic('missing needle ${needle}') }
	idx := at + offset
	if idx < 0 || idx >= owners.len || owners[idx] == -1 {
		return ''
	}
	return groups[idx]
}

fn test_v_syntax_word_boundaries_do_not_split_identifiers() {
	src := os.read_file('syntax/v.yaml')!
	mut syn := compile_syntax_from_yaml(src)!
	assert syntax_group_at(mut syn, 'fn ctrl_key(c u8) int {', 'fn') == 'type.keyword'
	assert syntax_group_at(mut syn, "const vro_version = '1.0.5'", 'vro_version') == ''
	assert syntax_group_at(mut syn, 'const key_arrow_left = 1000', 'key_arrow_left') == ''
	assert syntax_group_at(mut syn, 'fn ctrl_key(c u8) int {', 'ctrl_key') == 'identifier.function'
	assert syntax_group_at_offset(mut syn, 'fn ctrl_key(c u8) int {', 'ctrl_key(', 'ctrl_key'.len) == 'symbol.brackets'
	assert syntax_group_at(mut syn, '@[inline]', 'inline') == 'symbol.attribute'
	assert syntax_group_at(mut syn, 'fn ctrl_key(c u8) int {', 'u8') == 'type'
	assert syntax_group_at(mut syn, 'fn size() i64 {', 'i64') == 'type'
	assert syntax_group_at(mut syn, 'fn count() int {', 'int') == 'type'
	assert syntax_group_at(mut syn, 'fn ratio() f64 {', 'f64') == 'type'
	assert syntax_group_at(mut syn, 'mut values := map[string]int{}', 'map') == 'type'
	assert syntax_group_at(mut syn, 'mut total any_int = 0', 'any_int') == 'type'
	assert syntax_group_at(mut syn, 'mut ptr uintptr', 'uintptr') == 'type'
	assert syntax_group_at(mut syn, 'const tab_stop = 4', '4') == 'constant.number'
	assert syntax_group_at(mut syn, 'mut _ := value', '_') == ''
	assert syntax_group_at(mut syn, 'if t[i] < `0` || t[i] > `9` {', '<') == 'symbol.operator'
	assert syntax_group_at(mut syn, 'if t[i] < `0` || t[i] > `9` {', '||') == 'symbol.operator'
}

fn test_bundled_v_line_comment_region_does_not_carry() {
	src := os.read_file('syntax/v.yaml')!
	mut syn := compile_syntax_from_yaml(src)!
	carry := []bool{len: syn.rules.len, init: false}
	next := hl_carry_row(mut syn, '// comment', carry)
	assert !next.any(it)
	assert syntax_group_at(mut syn, 'return int(c & 0x1f)', 'return') != 'comment'
	assert syntax_group_at(mut syn, 'return int(c & 0x1f)', '0x1f') == 'constant.number'
}

fn test_v_regions_override_keywords_and_numbers() {
	src := os.read_file('syntax/v.yaml')!
	mut syn := compile_syntax_from_yaml(src)!
	assert syntax_group_at(mut syn, '// SPDX-License-Identifier: MPL-2.0', 'SPDX') == 'comment'
	assert syntax_group_at(mut syn, '// SPDX-License-Identifier: MPL-2.0', '2') == 'comment'
	assert syntax_group_at(mut syn, "const vro_version = '1.0.5'", '1') == 'constant.string'
	assert syntax_group_at(mut syn, "const vro_version = '1.0.5'", '.') == 'constant.string'
}

fn test_editor_render_highlights_v_when_forced_color() {
	old_no_color := os.getenv('NO_COLOR')
	old_force := os.getenv('VRO_FORCE_COLOR')
	old_no_hl := os.getenv('VRO_NO_HL')
	os.setenv('NO_COLOR', '1', true)
	os.setenv('VRO_FORCE_COLOR', '1', true)
	os.unsetenv('VRO_NO_HL')
	defer {
		if old_no_color.len > 0 {
			os.setenv('NO_COLOR', old_no_color, true)
		} else {
			os.unsetenv('NO_COLOR')
		}
		if old_force.len > 0 {
			os.setenv('VRO_FORCE_COLOR', old_force, true)
		} else {
			os.unsetenv('VRO_FORCE_COLOR')
		}
		if old_no_hl.len > 0 {
			os.setenv('VRO_NO_HL', old_no_hl, true)
		} else {
			os.unsetenv('VRO_NO_HL')
		}
	}
	mut e := editor_new()
	e.filename = 'main.v'
	editor_load_buffer_content(mut e, 'fn ctrl_key(c u8) int {\n\treturn int(c & 0x1f)\n}')
	e.screencols = 80
	e.screenrows = 3
	out := editor_build_screen(mut e)
	assert syntax_group_at(mut e.hl_syn, 'fn ctrl_key(c u8) int {', 'u8') == 'type'
	assert out.contains('\x1b[34mfn\x1b[0m') || out.contains('\x1b[35mfn\x1b[0m')
	assert out.contains('\x1b[96mctrl_key\x1b[0m')
	assert out.contains('\x1b[34mu8\x1b[0m')
	assert out.contains('\x1b[36m0x1f\x1b[0m')
}

fn test_ui_sanitize_display() {
	assert ui_sanitize_display('') == ''
	esc := 'a' + u8(0x1b).ascii_str() + 'b'
	assert ui_sanitize_display(esc) == 'a?b'
	del := 'x' + u8(0x7f).ascii_str() + 'y'
	assert ui_sanitize_display(del) == 'x?y'
}

fn test_ctrl_q_dirty_countdown() {
	mut e := EditorConfig{
		dirty:           1
		quit_times_left: quit_times
	}
	assert editor_handle_ctrl_q(mut e)
	assert e.quit_times_left == 2
	assert e.statusmsg == 'Unsaved (2 more Ctrl-Q presses forces quit)'
	assert editor_handle_ctrl_q(mut e)
	assert e.quit_times_left == 1
	assert e.statusmsg == 'Unsaved (1 more Ctrl-Q press forces quit)'
	assert !editor_handle_ctrl_q(mut e)
}

fn test_footer_caret_stays_in_command_area() {
	mut e := EditorConfig{
		command_mode:       true
		command_buffer:     ': abc'
		cmd_caret_bytes:    5
		cmd_line_left_skip: 0
		screencols:         12
		rows:               [Erow{}]
		quit_times_left:    quit_times
		statusmsg_time:     0
	}
	cx := editor_footer_caret_column(mut e)
	assert cx >= 1
	assert cx <= e.screencols
}

fn test_escape_cancels_command_bar() {
	mut e := EditorConfig{
		quit_times_left: quit_times
	}
	assert editor_command_bar(mut e)
	assert e.command_mode
	assert editor_process_key(mut e, int(`\x1b`), '')
	assert !e.command_mode
	assert e.prompt_kind == .none
}

fn test_command_bar_backspace() {
	mut e := EditorConfig{
		quit_times_left: quit_times
	}
	assert editor_command_bar(mut e)
	assert editor_process_key(mut e, 0, 'abc')
	assert e.prompt_text == 'abc'
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.prompt_text == 'ab'
	assert editor_process_local_termui_bytes(mut e, '\x7f')
	assert e.prompt_text == 'a'
	// BS byte (8) routed as ascii when utf8 is empty
	editor_prompt_insert(mut e, 'bc')
	assert editor_process_key(mut e, 8, '')
	assert e.prompt_text == 'ab'
}

fn test_command_bar_backspace_control_text() {
	mut e := EditorConfig{
		quit_times_left: quit_times
	}
	assert editor_command_bar(mut e)
	editor_prompt_insert(mut e, 'abc')
	assert editor_process_key(mut e, 0, '\x7f')
	assert e.prompt_text == 'ab'
}

fn test_tui_backspace_ascii8_maps_to_delete() {
	ev := tui.Event{
		code:  .null
		ascii: 8
	}
	assert tui_key_to_editor_key(&ev) == int(`\x7f`)
}

fn test_csi_u_escape_maps_to_escape_key() {
	ev := tui.Event{
		typ:  .key_down
		code: .null
		utf8: '\x1b[27u'
	}
	assert tui_key_to_editor_key(ev) == int(`\x1b`)
}

fn test_kitty_csi_u_enter_maps_to_return() {
	// Ghostty sends Enter as \x1b[13u; V's tui parses it to ev.code = .enter
	ev := tui.Event{
		typ:  .key_down
		code: .enter
		utf8: '\x1b[13u'
	}
	assert tui_key_to_editor_key(ev) == int(`\r`)
}

fn test_kitty_csi_u_backspace_maps_to_delete() {
	// Ghostty sends Backspace as \x1b[127u; V's tui parses it to ev.code = .backspace
	ev := tui.Event{
		typ:  .key_down
		code: .backspace
		utf8: '\x1b[127u'
	}
	assert tui_key_to_editor_key(ev) == int(`\x7f`)
}

fn test_kitty_csi_u_tab_maps_to_tab() {
	ev := tui.Event{
		typ:  .key_down
		code: .tab
		utf8: '\x1b[9u'
	}
	assert tui_key_to_editor_key(ev) == int(`\t`)
}

fn test_kitty_csi_u_fallback_in_csi_sequence_handler() {
	// When V's tui doesn't parse the CSI u sequence (ev.code = .null),
	// the raw byte handler should still recognize kitty protocol sequences.
	assert tui_csi_sequence_to_editor_key('\x1b[13u') == int(`\r`)
	assert tui_csi_sequence_to_editor_key('\x1b[127u') == int(`\x7f`)
	assert tui_csi_sequence_to_editor_key('\x1b[9u') == int(`\t`)
	assert tui_csi_sequence_to_editor_key('\x1b[8u') == int(`\x7f`)
}

fn test_kitty_enter_inserts_newline() {
	// Simulates the full vro_event routing for a kitty protocol Enter key:
	// ev.code = .enter (parsed by V's tui), ev.utf8 = "\x1b[13u" (raw bytes)
	// The fix ensures this goes through tui_key_to_editor_key, not the raw byte handler.
	mut e := EditorConfig{
		quit_times_left: quit_times
	}
	mut row := Erow{
		chars:  'hello'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	e.rows = [row]
	e.cx = 5
	ev := tui.Event{
		typ:  .key_down
		code: .enter
		utf8: '\x1b[13u'
	}
	key := tui_key_to_editor_key(ev)
	text := tui_key_text(ev)
	assert key == int(`\r`)
	assert text == ''
	assert editor_process_key(mut e, key, text)
	assert e.rows.len == 2
	assert e.rows[0].chars.bytestr() == 'hello'
	assert e.rows[1].chars.bytestr() == ''
}

fn test_kitty_backspace_deletes_char() {
	mut row := Erow{
		chars:  'hello'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              5
		quit_times_left: quit_times
	}
	ev := tui.Event{
		typ:  .key_down
		code: .backspace
		utf8: '\x1b[127u'
	}
	key := tui_key_to_editor_key(ev)
	text := tui_key_text(ev)
	assert key == int(`\x7f`)
	assert text == ''
	assert editor_process_key(mut e, key, text)
	assert e.rows[0].chars.bytestr() == 'hell'
}

fn test_kitty_csi_u_regular_char_text_extraction() {
	// When a terminal sends a regular char as CSI u without the text field,
	// tui_key_text must NOT return the raw escape sequence as insertable text.
	ev := tui.Event{
		typ:   .key_down
		code:  .a
		ascii: 97
		utf8:  '\x1b[97;1u'
	}
	assert tui_key_text(ev) == 'a'
}

fn test_kitty_csi_u_regular_char_with_text_field() {
	// With the text field (flag 16), ev.utf8 is the actual character.
	ev := tui.Event{
		typ:   .key_down
		code:  .a
		ascii: 97
		utf8:  'a'
	}
	assert tui_key_text(ev) == 'a'
}

fn test_shift_tab_maps_to_shift_tab_key() {
	ev := tui.Event{
		typ:       .key_down
		code:      .tab
		modifiers: .shift
	}
	assert tui_key_to_editor_key(ev) == key_shift_tab
}

fn test_shift_tab_dedents_line() {
	mut row := Erow{
		chars:  '    hello'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              4
		quit_times_left: quit_times
	}
	assert editor_process_key(mut e, key_shift_tab, '')
	assert e.rows[0].chars.bytestr() == 'hello'
}

fn test_shift_tab_no_dedent_on_empty_line() {
	mut e := EditorConfig{
		quit_times_left: quit_times
	}
	editor_insert_row(mut e, 0, '')
	assert editor_process_key(mut e, key_shift_tab, '')
	assert e.rows[0].chars.bytestr() == ''
}

fn test_kitty_csi_u_f13_returns_zero() {
	// F13 (57376u) is not handled by vro — should return 0, not crash.
	assert tui_csi_sequence_to_editor_key('\x1b[57376u') == 0
}

fn test_local_termui_grouped_bytes_replay_controls() {
	mut e := EditorConfig{
		quit_times_left: quit_times
	}
	assert editor_process_local_termui_bytes(mut e, 'abc' + u8(5).ascii_str() + u8(27).ascii_str())
	assert e.rows.len == 1
	assert e.rows[0].chars.bytestr() == 'abc'
	assert !e.command_mode
	assert e.prompt_kind == .none
}

fn test_local_termui_arrow_escape_does_not_insert_text() {
	mut row := Erow{
		chars:  'ab'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              1
		quit_times_left: quit_times
	}
	assert editor_process_local_termui_bytes(mut e, '\x1b[D')
	assert e.cx == 0
	assert e.rows[0].chars.bytestr() == 'ab'
}

fn test_local_termui_shift_arrow_escape_selects() {
	mut row := Erow{
		chars:  'abcd'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              1
		quit_times_left: quit_times
	}
	assert editor_process_local_termui_bytes(mut e, '\x1b[1;2C')
	assert e.cx == 2
	assert e.selection_active
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'acd'
}

fn test_local_termui_option_delete_deletes_previous_word() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              10
		quit_times_left: quit_times
	}
	assert editor_process_local_termui_bytes(mut e, '\x1b\x7f')
	assert e.rows[0].chars.bytestr() == 'alpha '
	assert e.cx == 6
}

fn test_mouse_drag_selection_deletes_selected_text() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection(mut e, 1, gutter + 2, false)
	editor_drag_mouse_selection(mut e, 1, gutter + 6, false)
	editor_end_mouse_selection(mut e)
	assert e.selection_active
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'a beta'
	assert !e.selection_active
}

fn test_ctrl_delete_maps_and_deletes_next_word() {
	mut row := Erow{
		chars:  'alpha beta gamma'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              6
		quit_times_left: quit_times
	}
	ev := tui.Event{
		typ:       .key_down
		code:      .delete
		modifiers: .ctrl
	}
	assert tui_key_to_editor_key(ev) == key_delete_word_forward
	assert editor_process_key(mut e, key_delete_word_forward, '')
	assert e.rows[0].chars.bytestr() == 'alpha  gamma'
}

fn test_ctrl_w_deletes_previous_word() {
	mut row := Erow{
		chars:  'alpha beta gamma'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              10
		quit_times_left: quit_times
	}
	assert editor_process_key(mut e, ctrl_key(`w`), '')
	assert e.rows[0].chars.bytestr() == 'alpha  gamma'
	assert e.cx == 6
}

fn test_ctrl_u_deletes_to_line_start() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              6
		quit_times_left: quit_times
	}
	assert editor_process_key(mut e, ctrl_key(`u`), '')
	assert e.rows[0].chars.bytestr() == 'beta'
	assert e.cx == 0
}

fn test_ctrl_c_v_x_internal_clipboard() {
	old := os.getenv('VRO_NO_SYSTEM_CLIPBOARD')
	os.setenv('VRO_NO_SYSTEM_CLIPBOARD', '1', true)
	defer {
		if old.len > 0 {
			os.setenv('VRO_NO_SYSTEM_CLIPBOARD', old, true)
		} else {
			os.unsetenv('VRO_NO_SYSTEM_CLIPBOARD')
		}
	}
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              5
		quit_times_left: quit_times
	}
	editor_set_selection(mut e, CursorPos{
		cy: 0
		cx: 0
	}, CursorPos{
		cy: 0
		cx: 5
	})
	assert editor_process_key(mut e, ctrl_key(`c`), '')
	assert e.clipboard == 'alpha'
	assert e.rows[0].chars.bytestr() == 'alpha beta'
	editor_clear_selection(mut e)
	e.cx = e.rows[0].chars.len
	assert editor_process_key(mut e, ctrl_key(`v`), '')
	assert e.rows[0].chars.bytestr() == 'alpha betaalpha'
	editor_set_selection(mut e, CursorPos{
		cy: 0
		cx: 6
	}, CursorPos{
		cy: 0
		cx: 10
	})
	assert editor_process_key(mut e, ctrl_key(`x`), '')
	assert e.clipboard == 'beta'
	assert e.rows[0].chars.bytestr() == 'alpha alpha'
}

fn test_ctrl_z_and_ctrl_y_undo_redo_edit() {
	mut row := Erow{
		chars:  'alpha'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              5
		quit_times_left: quit_times
	}
	assert editor_process_key(mut e, 0, '!')
	assert e.rows[0].chars.bytestr() == 'alpha!'
	assert editor_process_key(mut e, ctrl_key(`z`), '')
	assert e.rows[0].chars.bytestr() == 'alpha'
	assert editor_process_key(mut e, ctrl_key(`y`), '')
	assert e.rows[0].chars.bytestr() == 'alpha!'
}

fn test_mouse_click_respects_horizontal_scroll() {
	mut row := Erow{
		chars:  '0123456789abcdef'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      12
		coloff:          5
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_click_from_mouse(mut e, 1, gutter + 3)
	assert e.cx == 7
}

fn test_mouse_up_updates_selection_endpoint() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection(mut e, 1, gutter + 2, false)
	editor_drag_mouse_selection(mut e, 1, gutter + 4, false)
	editor_drag_mouse_selection(mut e, 1, gutter + 8, true)
	editor_end_mouse_selection(mut e)
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'aeta'
}

fn test_mouse_small_jitter_acts_like_click() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection(mut e, 1, gutter + 2, false)
	editor_end_mouse_selection(mut e)
	assert e.cx == 1
	assert !e.selection_active
}

fn test_mouse_can_select_one_character() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection(mut e, 1, gutter + 2, false)
	editor_drag_mouse_selection(mut e, 1, gutter + 3, false)
	editor_end_mouse_selection(mut e)
	assert e.selection_active
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'apha beta'
}

fn test_mouse_same_cell_acts_like_click() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection(mut e, 1, gutter + 2, false)
	editor_drag_mouse_selection(mut e, 1, gutter + 2, false)
	editor_end_mouse_selection(mut e)
	assert e.cx == 1
	assert !e.selection_active
}

fn test_double_click_selects_word() {
	mut row := Erow{
		chars:  'alpha beta gamma'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 8, false, 1000)
	editor_end_mouse_selection(mut e)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 8, false, 1200)
	assert e.selection_active
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'alpha  gamma'
}

fn test_triple_click_selects_sentence() {
	mut row := Erow{
		chars:  'One fish. Two fish! Red fish?'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 12, false, 1000)
	editor_end_mouse_selection(mut e)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 12, false, 1200)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 12, false, 1400)
	assert e.selection_active
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'One fish.  Red fish?'
}

fn test_drag_resets_click_count() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 2, false, 1000)
	editor_drag_mouse_selection(mut e, 1, gutter + 4, false)
	editor_end_mouse_selection(mut e)
	editor_begin_mouse_selection_at(mut e, 1, gutter + 2, false, 1200)
	editor_end_mouse_selection(mut e)
	assert !e.selection_active
}

fn test_shift_mouse_extends_from_cursor() {
	mut row := Erow{
		chars:  'alpha beta'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              2
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	gutter := editor_line_gutter_width(e)
	editor_begin_mouse_selection(mut e, 1, gutter + 7, true)
	editor_drag_mouse_selection(mut e, 1, gutter + 8, true)
	editor_end_mouse_selection(mut e)
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'aleta'
}

fn test_shift_arrow_extends_selection_and_delete_removes_it() {
	mut row := Erow{
		chars:  'abcd'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		cx:              1
		quit_times_left: quit_times
	}
	ev := tui.Event{
		typ:       .key_down
		code:      .right
		modifiers: .shift
	}
	assert tui_key_to_editor_key(ev) == key_shift_arrow_right
	assert editor_process_key(mut e, key_shift_arrow_right, '')
	assert editor_process_key(mut e, key_shift_arrow_right, '')
	assert e.selection_active
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows[0].chars.bytestr() == 'ad'
}

fn test_mouse_wheel_scrolls_without_dirtying() {
	mut rows := []Erow{}
	for i in 0 .. 8 {
		mut row := Erow{
			chars:  'line${i}'.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		rows << row
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      3
		screencols:      40
		quit_times_left: quit_times
	}
	editor_scroll_mouse(mut e, .down)
	assert e.rowoff == 1
	assert e.cy == 0
	assert e.dirty == 0
	editor_scroll_mouse(mut e, .up)
	assert e.rowoff == 0
	assert e.cy == 0
	assert e.dirty == 0
}

fn test_mouse_horizontal_scroll() {
	mut rows := [Erow{
		chars:  'hello'.bytes()
		render: []u8{}
	}]
	editor_update_row(mut rows[0])
	mut e := EditorConfig{
		rows:            rows
		screenrows:      3
		screencols:      40
		quit_times_left: quit_times
	}
	editor_scroll_mouse(mut e, .right)
	assert e.coloff == 1
	assert e.dirty == 0
	editor_scroll_mouse(mut e, .left)
	assert e.coloff == 0
	assert e.dirty == 0
}

fn test_backspace_deletes_selection() {
	mut row := Erow{
		chars:  'hello world'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:            [row]
		screenrows:      3
		screencols:      40
		quit_times_left: quit_times
	}
	editor_set_selection(mut e, CursorPos{0, 0}, CursorPos{0, 5})
	assert e.selection_active
	editor_del_char(mut e)
	assert e.rows[0].chars.bytestr() == ' world'
	assert !e.selection_active
}

fn test_open_save_preserves_trailing_newline() {
	path := os.join_path(os.temp_dir(), 'vro-trailing-newline-test.txt')
	defer {
		if os.exists(path) {
			os.rm(path) or {}
		}
	}
	os.write_file(path, 'alpha\n')!
	mut e := EditorConfig{}
	editor_open(mut e, path)!
	assert editor_rows_to_string(e) == 'alpha\n'
	assert editor_save_to_path(mut e, path)
	assert os.read_file(path)! == 'alpha\n'
}

fn test_save_to_failed_path_keeps_filename() {
	mut e := EditorConfig{
		filename: 'original.txt'
		rows:     [Erow{
			chars:  'data'.bytes()
			render: 'data'.bytes()
		}]
		dirty:    1
	}
	bad_path := os.join_path(os.temp_dir(), 'vro-missing-dir', 'out.txt')
	assert !editor_save_to_path(mut e, bad_path)
	assert e.filename == 'original.txt'
	assert e.dirty == 1
}

fn test_dirty_open_requires_bang() {
	path1 := os.join_path(os.temp_dir(), 'vro-open-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-open-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'one')!
	os.write_file(path2, 'two')!
	mut e := EditorConfig{}
	editor_open(mut e, path1)!
	e.dirty = 1
	assert editor_run_command(mut e, 'open ${path2}')
	assert e.filename == path1
	assert e.statusmsg == 'Unsaved changes. Use open! to discard.'
	assert editor_run_command(mut e, 'open! ${path2}')
	assert e.filename == path2
	assert editor_rows_to_string(e) == 'two'
}

fn test_app_open_args_loads_multiple_buffers() {
	path1 := os.join_path(os.temp_dir(), 'vro-args-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-args-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'one')!
	os.write_file(path2, 'two')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1, path2])
	assert app.buffers.len == 2
	assert app.panes.len == 1
	assert app.panes[0].buffer == 0
	assert app.buffers[1].filename == path2
}

fn test_app_split_commands_open_files_in_new_panes() {
	path1 := os.join_path(os.temp_dir(), 'vro-split-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-split-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'one')!
	os.write_file(path2, 'two')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	assert app_run_command(mut app, 'right ${path2}')
	assert app.buffers.len == 2
	assert app.panes.len == 2
	assert app.active_pane == 1
	assert app.panes[1].buffer == 1
	assert app.panes[1].split == .right
	assert app.buffers[1].filename == path2
}

fn test_app_buffer_switching_and_close() {
	path1 := os.join_path(os.temp_dir(), 'vro-buffer-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-buffer-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'one')!
	os.write_file(path2, 'two')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1, path2])
	assert app_run_command(mut app, 'buffer 2')
	assert app.panes[0].buffer == 1
	assert app_run_command(mut app, 'bprev')
	assert app.panes[0].buffer == 0
	assert app_run_command(mut app, 'bnext')
	assert app.panes[0].buffer == 1
	assert app_run_command(mut app, 'close')
	assert app.panes.len == 1
	assert app.buffers.len == 2
}

fn test_open_command_replaces_only_active_split_buffer() {
	path1 := os.join_path(os.temp_dir(), 'vro-active-open-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-active-open-two.txt')
	path3 := os.join_path(os.temp_dir(), 'vro-active-open-three.txt')
	defer {
		for path in [path1, path2, path3] {
			if os.exists(path) {
				os.rm(path) or {}
			}
		}
	}
	os.write_file(path1, 'left')!
	os.write_file(path2, 'right')!
	os.write_file(path3, 'replacement')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	assert app_run_command(mut app, 'right ${path2}')
	app.active_pane = 0
	assert app_run_command(mut app, 'open ${path3}')
	assert app.buffers[app.panes[0].buffer].filename == path3
	assert app.buffers[app.panes[1].buffer].filename == path2
}

fn test_git_refresh_reports_on_active_pane_only() {
	path1 := os.join_path(os.temp_dir(), 'vro-active-git-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-active-git-two.txt')
	defer {
		for path in [path1, path2] {
			if os.exists(path) {
				os.rm(path) or {}
			}
		}
	}
	os.write_file(path1, 'left')!
	os.write_file(path2, 'right')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	assert app_run_command(mut app, 'right ${path2}')
	app.active_pane = 1
	assert app_run_command(mut app, 'git refresh')
	assert app.buffers[app.panes[1].buffer].statusmsg == 'Git gutter refresh is disabled'
	assert app.buffers[app.panes[0].buffer].statusmsg != 'Git gutter refresh is disabled'
}

fn test_app_terminal_split_command_reports_unsupported() {
	mut app := vro_app_new()
	vro_app_open_args(mut app, []string{})
	assert app_run_command(mut app, 'top zsh')
	active := app_active_editor(mut app)
	assert active.statusmsg == 'Terminal panes are not supported yet'
	assert app.panes.len == 1
}

fn test_parse_git_diff_marks_added_modified_and_deleted_lines() {
	diff := 'diff --git a/a.txt b/a.txt
@@ -1,3 +1,4 @@
 one
-two
+too
+three
 four
@@ -8,2 +9,0 @@
-gone
-also gone
'
	marks := parse_git_diff_marks(diff)
	assert git_mark_for_line(marks, 2) == '~'
	assert git_mark_for_line(marks, 3) == '+'
	assert git_mark_for_line(marks, 9) == '-'
}

fn test_parse_git_diff_marks_empty_for_no_diff() {
	assert parse_git_diff_marks('').len == 0
	assert parse_git_diff_marks('not a diff').len == 0
}

fn test_gutter_width_matches_rendered_columns_without_git_mark() {
	mut e := EditorConfig{
		rows: [
			Erow{
				chars:  'alpha'.bytes()
				render: 'alpha'.bytes()
			},
		]
	}
	mut ab := strings.new_builder(32)
	editor_append_line_gutter(e, mut ab, 0)
	assert strip_ansi(ab.str()).len == editor_line_gutter_width(e)
}

fn test_gutter_git_marks_render_as_background_cell() {
	mut e := EditorConfig{
		rows:      [
			Erow{
				chars:  'alpha'.bytes()
				render: 'alpha'.bytes()
			},
		]
		git_marks: [
			GitGutterMark{
				line: 1
				mark: '+'
			},
		]
	}
	mut ab := strings.new_builder(32)
	editor_append_line_gutter(e, mut ab, 0)
	out := ab.str()
	assert strip_ansi(out).len == editor_line_gutter_width(e)
	assert !strip_ansi(out).contains('+')
	assert out.contains('\x1b[42m \x1b[0m')
}

fn test_split_cursor_matches_first_text_column_after_gutter() {
	mut row := Erow{
		chars:  'alpha'.bytes()
		render: []u8{}
	}
	editor_update_row(mut row)
	mut e := EditorConfig{
		rows:       [row]
		screenrows: 4
		screencols: 20
	}
	mut ab := strings.new_builder(128)
	cursor := editor_draw_at(mut e, mut ab, PaneRect{
		row:    1
		col:    1
		width:  20
		height: 5
	})
	assert cursor.col == 1 + editor_line_gutter_width(e)
	assert strip_ansi(ab.str()).contains('1  alpha')
}

fn test_split_screen_renders_multiple_filenames() {
	path1 := os.join_path(os.temp_dir(), 'vro-render-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-render-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'one')!
	os.write_file(path2, 'two')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	app.screencols = 80
	app.screenrows = 12
	assert app_run_command(mut app, 'bottom ${path2}')
	out := app_build_screen(mut app)
	assert out.contains(path1)
	assert out.contains(path2)
}

fn test_split_screen_fits_tui_buffer() {
	path1 := os.join_path(os.temp_dir(), 'vro-buffer-frame-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-buffer-frame-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	mut left := ''
	mut right := ''
	for i in 0 .. 80 {
		left += 'left line ${i} with enough text to fill a typical pane width\n'
		right += 'right line ${i} with enough text to fill a typical pane width\n'
	}
	os.write_file(path1, left)!
	os.write_file(path2, right)!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	app.screencols = 160
	app.screenrows = 48
	assert app_run_command(mut app, 'right ${path2}')
	out := app_build_screen(mut app)
	assert out.len < tui_buffer_size
	assert out.len > 4096
}

fn test_right_split_renders_second_pane_on_same_row() {
	path1 := os.join_path(os.temp_dir(), 'vro-right-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-right-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'left-side')!
	os.write_file(path2, 'right-side')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	app.screencols = 80
	app.screenrows = 12
	assert app_run_command(mut app, 'right ${path2}')
	out := app_build_screen(mut app)
	assert out.contains('\x1b[1;1H')
	assert out.contains('\x1b[1;41H')
	assert out.contains('left-side')
	assert out.contains('right-side')
}

fn test_bottom_split_renders_second_pane_lower() {
	path1 := os.join_path(os.temp_dir(), 'vro-bottom-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-bottom-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'top-side')!
	os.write_file(path2, 'bottom-side')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	app.screencols = 80
	app.screenrows = 12
	assert app_run_command(mut app, 'bottom ${path2}')
	out := app_build_screen(mut app)
	assert out.contains('\x1b[1;1H')
	assert out.contains('\x1b[7;1H')
	assert out.contains('top-side')
	assert out.contains('bottom-side')
}

fn test_split_command_escape_cancels_command_mode() {
	path1 := os.join_path(os.temp_dir(), 'vro-escape-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-escape-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'one')!
	os.write_file(path2, 'two')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	assert app_run_command(mut app, 'right ${path2}')
	assert app_process_key(mut app, ctrl_key(`e`), '')
	assert app_active_editor(mut app).command_mode
	assert app_process_local_termui_bytes(mut app, '\x1b')
	active := app_active_editor(mut app)
	assert !active.command_mode
	assert !active.rows.any(it.chars.bytestr().contains('^['))
}

fn test_mouse_scroll_moves_view_without_clicking_first() {
	mut rows := []Erow{}
	for i in 0 .. 20 {
		mut row := Erow{
			chars:  'line${i}'.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		rows << row
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	for _ in 0 .. 4 {
		editor_scroll_mouse(mut e, .down)
		editor_scroll(mut e)
	}
	assert e.rowoff == 4
	assert e.cy == 0
}

fn test_mouse_scroll_does_not_pin_cursor_to_top() {
	mut rows := []Erow{}
	for i in 0 .. 20 {
		mut row := Erow{
			chars:  'line${i}'.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		rows << row
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      5
		screencols:      40
		quit_times_left: quit_times
	}
	for _ in 0 .. 4 {
		editor_scroll_mouse(mut e, .down)
	}
	assert e.rowoff == 4
	assert e.cy == 0
}

fn test_editor_hides_cursor_when_caret_scrolled_offscreen() {
	mut rows := []Erow{}
	for i in 0 .. 20 {
		mut row := Erow{
			chars:  'line${i}'.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		rows << row
	}
	mut e := EditorConfig{
		rows:          rows
		screenrows:    5
		screencols:    40
		rowoff:        4
		cy:            0
		follow_cursor: false
	}
	out := editor_build_screen(mut e)
	assert !out.contains('\x1b[?25h')
}

fn test_mouse_click_in_right_split_focuses_second_editor() {
	path1 := os.join_path(os.temp_dir(), 'vro-focus-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-focus-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'left')!
	os.write_file(path2, 'right')!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	app.screencols = 80
	app.screenrows = 12
	assert app_run_command(mut app, 'right ${path2}')
	app.active_pane = 0
	app_mouse_down(mut app, 1, 45, false)
	assert app.active_pane == 1
	assert app_active_editor(mut app).filename == path2
}

fn test_mouse_scroll_over_right_split_scrolls_second_editor() {
	path1 := os.join_path(os.temp_dir(), 'vro-scroll-one.txt')
	path2 := os.join_path(os.temp_dir(), 'vro-scroll-two.txt')
	defer {
		if os.exists(path1) {
			os.rm(path1) or {}
		}
		if os.exists(path2) {
			os.rm(path2) or {}
		}
	}
	os.write_file(path1, 'left')!
	mut content := ''
	for i in 0 .. 20 {
		content += 'right${i}\n'
	}
	os.write_file(path2, content)!
	mut app := vro_app_new()
	vro_app_open_args(mut app, [path1])
	app.screencols = 80
	app.screenrows = 12
	assert app_run_command(mut app, 'right ${path2}')
	app.active_pane = 0
	app_mouse_scroll(mut app, 1, 45, .down)
	assert app.active_pane == 1
	assert app.buffers[1].rowoff == 1
	assert app.buffers[0].rowoff == 0
}

fn test_tui_key_to_editor_key_ctrl_letters() {
	code_base := int(tui.KeyCode.a)
	for i in 0 .. 26 {
		c := code_base + i
		ev := tui.Event{
			code:      unsafe { tui.KeyCode(c) }
			modifiers: tui.Modifiers.ctrl
			ascii:     u8(c)
			utf8:      ''
		}
		key := tui_key_to_editor_key(&ev)
		assert key == ctrl_key(u8(c)), 'Ctrl+${u8(c).ascii_str()}: got ${key} expected ${ctrl_key(u8(c))}'
	}
}

fn test_tui_key_to_editor_key_special_keys() {
	ev := tui.Event{
		code: tui.KeyCode.enter
	}
	assert tui_key_to_editor_key(&ev) == int(`\r`)
	ev2 := tui.Event{
		code: tui.KeyCode.escape
	}
	assert tui_key_to_editor_key(&ev2) == int(`\x1b`)
	ev3 := tui.Event{
		code: tui.KeyCode.tab
	}
	assert tui_key_to_editor_key(&ev3) == int(`\t`)
	ev4 := tui.Event{
		code: tui.KeyCode.backspace
	}
	assert tui_key_to_editor_key(&ev4) == int(`\x7f`)
	ev5 := tui.Event{
		code: tui.KeyCode.delete
	}
	assert tui_key_to_editor_key(&ev5) == key_del
	ev6 := tui.Event{
		code: tui.KeyCode.left
	}
	assert tui_key_to_editor_key(&ev6) == key_arrow_left
	ev7 := tui.Event{
		code: tui.KeyCode.right
	}
	assert tui_key_to_editor_key(&ev7) == key_arrow_right
	ev8 := tui.Event{
		code: tui.KeyCode.up
	}
	assert tui_key_to_editor_key(&ev8) == key_arrow_up
	ev9 := tui.Event{
		code: tui.KeyCode.down
	}
	assert tui_key_to_editor_key(&ev9) == key_arrow_down
	ev10 := tui.Event{
		code: tui.KeyCode.home
	}
	assert tui_key_to_editor_key(&ev10) == key_home
	ev11 := tui.Event{
		code: tui.KeyCode.end
	}
	assert tui_key_to_editor_key(&ev11) == key_end
	ev12 := tui.Event{
		code: tui.KeyCode.page_up
	}
	assert tui_key_to_editor_key(&ev12) == key_page_up
	ev13 := tui.Event{
		code: tui.KeyCode.page_down
	}
	assert tui_key_to_editor_key(&ev13) == key_page_down
}

fn test_tui_key_to_editor_key_shift_arrows() {
	ev := tui.Event{
		code:      tui.KeyCode.up
		modifiers: tui.Modifiers.shift
	}
	assert tui_key_to_editor_key(&ev) == key_shift_arrow_up
	ev2 := tui.Event{
		code:      tui.KeyCode.down
		modifiers: tui.Modifiers.shift
	}
	assert tui_key_to_editor_key(&ev2) == key_shift_arrow_down
	ev3 := tui.Event{
		code:      tui.KeyCode.left
		modifiers: tui.Modifiers.shift
	}
	assert tui_key_to_editor_key(&ev3) == key_shift_arrow_left
	ev4 := tui.Event{
		code:      tui.KeyCode.right
		modifiers: tui.Modifiers.shift
	}
	assert tui_key_to_editor_key(&ev4) == key_shift_arrow_right
}

fn test_tui_key_to_editor_key_ctrl_delete_backspace() {
	ev := tui.Event{
		code:      tui.KeyCode.delete
		modifiers: tui.Modifiers.ctrl
	}
	assert tui_key_to_editor_key(&ev) == key_delete_word_forward
	ev2 := tui.Event{
		code:      tui.KeyCode.backspace
		modifiers: tui.Modifiers.ctrl
	}
	assert tui_key_to_editor_key(&ev2) == key_delete_word_backward
}

fn test_tui_key_text_basic() {
	// Printable character
	ev := tui.Event{
		code:  tui.KeyCode.a
		ascii: 97
		utf8:  'a'
	}
	assert tui_key_text(&ev) == 'a'

	// Ctrl+letter → empty
	ev2 := tui.Event{
		code:      tui.KeyCode.q
		modifiers: tui.Modifiers.ctrl
	}
	assert tui_key_text(&ev2) == ''
}

fn test_tui_control_byte_to_editor_key() {
	// Tab
	assert tui_control_byte_to_editor_key(9) == int(`\t`)
	// Enter (LF)
	assert tui_control_byte_to_editor_key(10) == int(`\r`)
	// Enter (CR)
	assert tui_control_byte_to_editor_key(13) == int(`\r`)
	// Escape
	assert tui_control_byte_to_editor_key(27) == int(`\x1b`)
	// Backspace
	assert tui_control_byte_to_editor_key(127) == int(`\x7f`)
	// Ctrl+letter (1-8, 11-12, 14-26)
	assert tui_control_byte_to_editor_key(1) == ctrl_key(u8(97)) // Ctrl+A → ctrl_key('a')
	assert tui_control_byte_to_editor_key(17) == ctrl_key(u8(113)) // Ctrl+Q → ctrl_key('q')
	assert tui_control_byte_to_editor_key(26) == ctrl_key(u8(122)) // Ctrl+Z → ctrl_key('z')
	// Non-control byte
	assert tui_control_byte_to_editor_key(32) == 0
	assert tui_control_byte_to_editor_key(65) == 0
}

fn test_tui_control_byte_to_editor_key_ctrl_mapping_correctness() {
	// Verify that the ctrl_key computation in tui_control_byte_to_editor_key
	// produces the same value as direct ctrl_key for each Ctrl+letter
	// The function does: ctrl_key(96 | b) for bytes 1-8, 11-12, 14-26
	for b in 1 .. 9 {
		key := tui_control_byte_to_editor_key(u8(b))
		expected := ctrl_key(u8(96 | b))
		assert key == expected, 'byte ${b}: got ${key} expected ${expected}'
	}
	for b in 11 .. 13 {
		key := tui_control_byte_to_editor_key(u8(b))
		expected := ctrl_key(u8(96 | b))
		assert key == expected, 'byte ${b}: got ${key} expected ${expected}'
	}
	for b in 14 .. 27 {
		key := tui_control_byte_to_editor_key(u8(b))
		expected := ctrl_key(u8(96 | b))
		assert key == expected, 'byte ${b}: got ${key} expected ${expected}'
	}
}

fn test_tui_csi_sequence_to_editor_key() {
	assert tui_csi_sequence_to_editor_key('\x1b[A') == key_arrow_up
	assert tui_csi_sequence_to_editor_key('\x1bOA') == key_arrow_up
	assert tui_csi_sequence_to_editor_key('\x1b[1;A') == key_arrow_up
	assert tui_csi_sequence_to_editor_key('\x1b[B') == key_arrow_down
	assert tui_csi_sequence_to_editor_key('\x1b[C') == key_arrow_right
	assert tui_csi_sequence_to_editor_key('\x1b[D') == key_arrow_left
	assert tui_csi_sequence_to_editor_key('\x1b[H') == key_home
	assert tui_csi_sequence_to_editor_key('\x1b[F') == key_end
	assert tui_csi_sequence_to_editor_key('\x1b[3~') == key_del
	assert tui_csi_sequence_to_editor_key('\x1b[5~') == key_page_up
	assert tui_csi_sequence_to_editor_key('\x1b[6~') == key_page_down
	assert tui_csi_sequence_to_editor_key('\x1b[1;2A') == key_shift_arrow_up
	assert tui_csi_sequence_to_editor_key('\x1b[1;2B') == key_shift_arrow_down
	assert tui_csi_sequence_to_editor_key('\x1b[1;2C') == key_shift_arrow_right
	assert tui_csi_sequence_to_editor_key('\x1b[1;2D') == key_shift_arrow_left
	assert tui_csi_sequence_to_editor_key('\x1b[3;5~') == key_delete_word_forward
	assert tui_csi_sequence_to_editor_key('\x1b\x7f') == key_delete_word_backward
	// Kitty protocol Escape
	assert tui_csi_sequence_to_editor_key('\x1b[27u') == int(`\x1b`)
	assert tui_csi_sequence_to_editor_key('\x1b[27;1u') == int(`\x1b`)
}

fn test_sgr_scroll_direction() {
	// Standard SGR scroll events
	assert sgr_scroll_direction('\x1b[<64;1;1M') == tui.Direction.up
	assert sgr_scroll_direction('\x1b[<65;1;1M') == tui.Direction.down
	assert sgr_scroll_direction('\x1b[<66;1;1M') == tui.Direction.left
	assert sgr_scroll_direction('\x1b[<67;1;1M') == tui.Direction.right
	// With modifier flags (buttons 64-95)
	assert sgr_scroll_direction('\x1b[<68;1;1M') == tui.Direction.up // shift+up
	assert sgr_scroll_direction('\x1b[<69;1;1M') == tui.Direction.down // shift+down
	assert sgr_scroll_direction('\x1b[<80;1;1M') == tui.Direction.up // ctrl+up
	assert sgr_scroll_direction('\x1b[<81;1;1M') == tui.Direction.down // ctrl+down
	assert sgr_scroll_direction('\x1b[<84;1;1M') == tui.Direction.up // ctrl+shift+up
	assert sgr_scroll_direction('\x1b[<85;1;1M') == tui.Direction.down // ctrl+shift+down
	// Non-scroll events (buttons outside 64-95)
	assert sgr_scroll_direction('\x1b[<0;1;1M') == tui.Direction.unknown
	assert sgr_scroll_direction('\x1b[<35;1;1M') == tui.Direction.unknown
	assert sgr_scroll_direction('\x1b[<96;1;1M') == tui.Direction.unknown
	// Non-SGR sequences
	assert sgr_scroll_direction('\x1b[A') == tui.Direction.unknown
	assert sgr_scroll_direction('hello') == tui.Direction.unknown
}

fn test_editor_process_key_ctrl_combinations() {
	mut e := EditorConfig{
		rows:            [
			Erow{
				chars:  'hello world'.bytes()
				render: []u8{}
			},
		]
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
	}
	editor_update_row(mut e.rows[0])

	// Ctrl+S → save (no-op with no filename, but should not crash)
	assert editor_process_key(mut e, ctrl_key(`s`), '')

	// Ctrl+L → redraw (no-op)
	assert editor_process_key(mut e, ctrl_key(`l`), '')

	// Escape → no-op in normal mode
	assert editor_process_key(mut e, int(`\x1b`), '')

	// Tab → insert spaces
	old_cx := e.cx
	assert editor_process_key(mut e, int(`\t`), '')
	assert e.cx >= old_cx + tab_stop

	// Backspace (byte 127 and Ctrl+H)
	assert editor_process_key(mut e, int(`\x7f`), '')
	// Delete (key_del)
	e.cy = 0
	e.cx = 5
	assert editor_process_key(mut e, key_del, '')
}

fn test_editor_process_key_insert_text() {
	mut e := EditorConfig{
		rows:            [Erow{
			chars:  ''.bytes()
			render: []u8{}
		}]
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
	}
	editor_update_row(mut e.rows[0])

	// Insert 'a' via text
	assert editor_process_key(mut e, 0, 'a')
	assert e.rows[e.cy].chars == [u8(`a`)]
	assert e.cx == 1
}

fn test_editor_process_local_termui_bytes_arrows() {
	mut e := EditorConfig{
		rows:            [
			Erow{
				chars:  'hello world'.bytes()
				render: []u8{}
			},
		]
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
	}
	editor_update_row(mut e.rows[0])

	// Arrow right
	e.cx = 0
	assert editor_process_local_termui_bytes(mut e, '\x1b[C')
	assert e.cx == 1
	// Arrow left
	assert editor_process_local_termui_bytes(mut e, '\x1b[D')
	assert e.cx == 0
}

fn test_editor_process_local_termui_bytes_ctrl_q() {
	mut e := EditorConfig{
		rows:            [Erow{
			chars:  'hello'.bytes()
			render: []u8{}
		}]
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
		dirty:           0 // clean file → Ctrl+Q should quit (return false)
	}
	editor_update_row(mut e.rows[0])

	// Ctrl+Q via Path 1 (control byte)
	assert !editor_process_local_termui_bytes(mut e, '\x11')
}

fn test_editor_process_local_termui_bytes_paste() {
	mut e := EditorConfig{
		rows:            [Erow{
			chars:  ''.bytes()
			render: []u8{}
		}]
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
	}
	editor_update_row(mut e.rows[0])

	// Paste text
	assert editor_process_local_termui_bytes(mut e, 'hello')
	assert editor_rows_to_string(e) == 'hello'
}

fn test_editor_mouse_scroll_viewport() {
	mut rows := []Erow{}
	for i in 0 .. 10 {
		mut row := Erow{
			chars:  'line${i}'.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		rows << row
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      3
		screencols:      40
		quit_times_left: quit_times
	}

	// Scroll down
	assert e.rowoff == 0
	editor_scroll_mouse(mut e, .down)
	assert e.rowoff == 1
	// Scroll up
	editor_scroll_mouse(mut e, .up)
	assert e.rowoff == 0
	// Scroll past bottom edge
	for _ in 0 .. 20 {
		editor_scroll_mouse(mut e, .down)
	}
	// Max scroll: rowoff + screenrows <= rows.len → rowoff max = rows.len - screenrows = 7
	assert e.rowoff == 7
	// Scroll up past top edge
	for _ in 0 .. 20 {
		editor_scroll_mouse(mut e, .up)
	}
	assert e.rowoff == 0
}

fn test_editor_mouse_scroll_horizontal() {
	mut rows := [
		Erow{
			chars:  'a very long line that exceeds the screen width for testing horizontal scrolling'.bytes()
			render: []u8{}
		},
	]
	editor_update_row(mut rows[0])
	mut e := EditorConfig{
		rows:            rows
		screenrows:      3
		screencols:      40
		quit_times_left: quit_times
	}

	assert e.coloff == 0
	editor_scroll_mouse(mut e, .right)
	assert e.coloff == 1
	editor_scroll_mouse(mut e, .left)
	assert e.coloff == 0
	// Scrolling horizontally should NOT change cursor position
	assert e.cx == 0
}

fn test_backspace_at_line_start_merges_with_previous() {
	mut rows := [
		Erow{
			chars:  'hello'.bytes()
			render: []u8{}
		},
		Erow{
			chars:  'world'.bytes()
			render: []u8{}
		},
	]
	for mut r in rows {
		editor_update_row(mut r)
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
		dirty:           0
		cx:              0
		cy:              1
	}
	editor_del_char(mut e)
	assert e.rows.len == 1
	assert e.rows[0].chars.bytestr() == 'helloworld'
	assert e.cx == 5
	assert e.cy == 0
	assert e.dirty > 0
}

fn test_backspace_at_line_start_merges_with_previous_key_routing() {
	mut rows := [
		Erow{
			chars:  'hello'.bytes()
			render: []u8{}
		},
		Erow{
			chars:  'world'.bytes()
			render: []u8{}
		},
	]
	for mut r in rows {
		editor_update_row(mut r)
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
		dirty:           0
		cx:              0
		cy:              1
	}
	// Simulate backspace key (127 = int(`\x7f`))
	assert editor_process_key(mut e, int(`\x7f`), '')
	assert e.rows.len == 1
	assert e.rows[0].chars.bytestr() == 'helloworld'
	assert e.cx == 5
	assert e.cy == 0
}

fn test_backspace_at_line_start_merges_with_previous_via_local_bytes() {
	mut rows := [
		Erow{
			chars:  'hello'.bytes()
			render: []u8{}
		},
		Erow{
			chars:  'world'.bytes()
			render: []u8{}
		},
	]
	for mut r in rows {
		editor_update_row(mut r)
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      24
		screencols:      80
		quit_times_left: quit_times
		dirty:           0
		cx:              0
		cy:              1
	}
	// Simulate backspace byte via local termui bytes
	assert editor_process_local_termui_bytes(mut e, u8(127).ascii_str())
	assert e.rows.len == 1
	assert e.rows[0].chars.bytestr() == 'helloworld'
	assert e.cx == 5
	assert e.cy == 0
}

fn syntax_group_at_ex(mut syn CompiledSyntax, line string, needle string) string {
	owners, groups, _ := hl_fill_owners(mut syn, line, []bool{})
	at := line.index(needle) or { return '' }
	for i in at .. at + needle.len {
		if i < owners.len && owners[i] >= 0 {
			return groups[i]
		}
	}
	return ''
}

fn test_javascript_syntax_groups() {
	src := os.read_file('syntax/javascript.yaml') or { panic(err) }
	mut syn := compile_syntax_from_yaml(src) or { panic(err) }

	// Keywords — all should be statement
	assert syntax_group_at_ex(mut syn, 'const x = 1;', 'const') == 'statement'
	assert syntax_group_at_ex(mut syn, 'let x = 1;', 'let') == 'statement'
	assert syntax_group_at_ex(mut syn, 'var x = 1;', 'var') == 'statement'
	assert syntax_group_at_ex(mut syn, 'if (true) {}', 'if') == 'statement'
	assert syntax_group_at_ex(mut syn, 'return x;', 'return') == 'statement'
	assert syntax_group_at_ex(mut syn, 'function foo() {}', 'function') == 'statement'
	assert syntax_group_at_ex(mut syn, 'class Foo {}', 'class') == 'statement'
	assert syntax_group_at_ex(mut syn, 'import x from "y"', 'import') == 'statement'
	assert syntax_group_at_ex(mut syn, 'import x from "y"', 'from') == 'statement'
	assert syntax_group_at_ex(mut syn, 'async function f() {}', 'async') == 'statement'
	assert syntax_group_at_ex(mut syn, 'await p;', 'await') == 'statement'
	assert syntax_group_at_ex(mut syn, 'typeof x', 'typeof') == 'statement'
	assert syntax_group_at_ex(mut syn, 'x instanceof y', 'instanceof') == 'statement'
	assert syntax_group_at_ex(mut syn, 'throw e;', 'throw') == 'statement'
	assert syntax_group_at_ex(mut syn, 'try {}', 'try') == 'statement'
	assert syntax_group_at_ex(mut syn, 'catch(e) {}', 'catch') == 'statement'
	assert syntax_group_at_ex(mut syn, 'for (;;) {}', 'for') == 'statement'
	assert syntax_group_at_ex(mut syn, 'while (x) {}', 'while') == 'statement'
	assert syntax_group_at_ex(mut syn, 'do {} while (x)', 'do') == 'statement'
	assert syntax_group_at_ex(mut syn, 'switch (x) {}', 'switch') == 'statement'
	assert syntax_group_at_ex(mut syn, 'break;', 'break') == 'statement'
	assert syntax_group_at_ex(mut syn, 'continue;', 'continue') == 'statement'
	assert syntax_group_at_ex(mut syn, 'debugger;', 'debugger') == 'statement'
	assert syntax_group_at_ex(mut syn, 'export default x;', 'export') == 'statement'
	assert syntax_group_at_ex(mut syn, 'export default x;', 'default') == 'statement'
	assert syntax_group_at_ex(mut syn, 'new Foo()', 'new') == 'statement'
	assert syntax_group_at_ex(mut syn, 'delete x;', 'delete') == 'statement'
	assert syntax_group_at_ex(mut syn, 'void x;', 'void') == 'statement'
	assert syntax_group_at_ex(mut syn, 'yield x;', 'yield') == 'statement'
	assert syntax_group_at_ex(mut syn, 'with (x) {}', 'with') == 'statement'
	assert syntax_group_at_ex(mut syn, 'this.foo', 'this') == 'statement'
	assert syntax_group_at_ex(mut syn, 'static foo() {}', 'static') == 'statement'
	assert syntax_group_at_ex(mut syn, 'super()', 'super') == 'statement'
	assert syntax_group_at_ex(mut syn, 'set foo(v) {}', 'set') == 'statement'
	assert syntax_group_at_ex(mut syn, 'get foo() {}', 'get') == 'statement'
	assert syntax_group_at_ex(mut syn, 'x of y', 'of') == 'statement'
	assert syntax_group_at_ex(mut syn, 'x in y', 'in') == 'statement'

	// Constants
	assert syntax_group_at_ex(mut syn, 'null', 'null') == 'constant'
	assert syntax_group_at_ex(mut syn, 'true', 'true') == 'constant'
	assert syntax_group_at_ex(mut syn, 'false', 'false') == 'constant'
	assert syntax_group_at_ex(mut syn, 'undefined', 'undefined') == 'constant'
	assert syntax_group_at_ex(mut syn, 'NaN', 'NaN') == 'constant'
	assert syntax_group_at_ex(mut syn, 'Infinity', 'Infinity') == 'constant'
	assert syntax_group_at_ex(mut syn, 'globalThis', 'globalThis') == 'constant'

	// Error reserved words
	assert syntax_group_at_ex(mut syn, 'enum', 'enum') == 'error'
	assert syntax_group_at_ex(mut syn, 'implements', 'implements') == 'error'
	assert syntax_group_at_ex(mut syn, 'interface', 'interface') == 'error'
	assert syntax_group_at_ex(mut syn, 'package', 'package') == 'error'
	assert syntax_group_at_ex(mut syn, 'private', 'private') == 'error'
	assert syntax_group_at_ex(mut syn, 'protected', 'protected') == 'error'
	assert syntax_group_at_ex(mut syn, 'public', 'public') == 'error'

	// Numbers — micro's original YAML doesn't have 0b/0o/BigInt
	assert syntax_group_at_ex(mut syn, '42', '42') == 'constant.number'
	assert syntax_group_at_ex(mut syn, '0xFF', '0xFF') == 'constant.number'
	assert syntax_group_at_ex(mut syn, '3.14', '3.14') == 'constant.number'
	assert syntax_group_at_ex(mut syn, '1e10', '1e10') == 'constant.number'
	// 0b/0o/BigInt not in original — should not match
	assert syntax_group_at_ex(mut syn, '0b1010', '0b1010') == ''
	assert syntax_group_at_ex(mut syn, '0o777', '0o777') == ''
	assert syntax_group_at_ex(mut syn, '100n', '100n') == ''

	// Types
	assert syntax_group_at_ex(mut syn, 'Array', 'Array') == 'type'
	assert syntax_group_at_ex(mut syn, 'Promise', 'Promise') == 'type'
	assert syntax_group_at_ex(mut syn, 'Map', 'Map') == 'type'
	assert syntax_group_at_ex(mut syn, 'Set', 'Set') == 'type'

	// Identifiers — NOT highlighted
	assert syntax_group_at_ex(mut syn, 'foo', 'foo') == ''
	assert syntax_group_at_ex(mut syn, 'console', 'console') == ''
	assert syntax_group_at_ex(mut syn, 'bar', 'bar') == ''

	// reject and resolve ARE in statement keywords in micro's original YAML
	// (they're not JS keywords but micro included them)
	assert syntax_group_at_ex(mut syn, 'reject(x)', 'reject') == 'statement'
	assert syntax_group_at_ex(mut syn, 'resolve(x)', 'resolve') == 'statement'

	// Single-quoted string region
	_, gs, _ := hl_fill_owners(mut syn, "'hello'", []bool{})
	assert gs[0] == 'constant.string'

	// Double-quoted string region
	_, gd, _ := hl_fill_owners(mut syn, '"hello"', []bool{})
	assert gd[0] == 'constant.string'

	// Backtick string region
	_, gt, _ := hl_fill_owners(mut syn, '`hello`', []bool{})
	assert gt[0] == 'constant.string'
}

fn test_editor_mouse_scroll_no_content_change() {
	mut rows := []Erow{}
	for i in 0 .. 5 {
		mut row := Erow{
			chars:  'line'.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		rows << row
	}
	mut e := EditorConfig{
		rows:            rows
		screenrows:      3
		screencols:      40
		quit_times_left: quit_times
		dirty:           0
	}

	editor_scroll_mouse(mut e, .down)
	assert e.dirty == 0
	editor_scroll_mouse(mut e, .right)
	assert e.dirty == 0
}

fn test_js_render_diagnostic() {
	src := os.read_file('syntax/javascript.yaml') or { panic(err) }
	mut syn := compile_syntax_from_yaml(src) or { panic(err) }

	// Check that null IS matched as constant on its own
	assert syntax_group_at_ex(mut syn, 'null', 'null') == 'constant'

	// Check within return statement
	assert syntax_group_at_ex(mut syn, 'return null', 'null') == 'constant'

	// Check within full line with leading spaces
	assert syntax_group_at_ex(mut syn, '    return null;', 'null') == 'constant'

	// Check carry state: does hl_draw_line_slice produce correct output?
	mut carry := []bool{len: syn.rules.len, init: false}

	// First process leading lines to build carry state
	carry = hl_carry_row(mut syn, 'const x = 42', carry)
	carry = hl_carry_row(mut syn, "let y = 'hello';", carry)
	carry = hl_carry_row(mut syn, '`test`', carry)
	carry = hl_carry_row(mut syn, 'if (x > 0) {', carry)

	// Now check null on the target line
	line := '    return null;'
	owners, groups, _ := hl_fill_owners(mut syn, line, carry)
	at := line.index('null') or { panic('null not found') }
	g := groups[at]
	assert g == 'constant', 'null group should be constant, got [${g}]'

	// Verify ANSI color output
	mut ab := strings.new_builder(128)
	hl_draw_line_slice(mut syn, '    return null;', 0, 15, carry, mut ab)
	out := ab.str()
	assert out.contains('\x1b[35mreturn\x1b[0m'), 'return should be magenta'
	assert out.contains('\x1b[95mnull\x1b[0m'), 'null should be bright magenta'
}

fn test_js_rendered_ansi_colors() {
	// Test that the editor renders JS with correct ANSI colors
	old_no_color := os.getenv('NO_COLOR')
	old_force := os.getenv('VRO_FORCE_COLOR')
	os.setenv('NO_COLOR', '1', true)
	os.setenv('VRO_FORCE_COLOR', '1', true)
	defer {
		if old_no_color.len > 0 {
			os.setenv('NO_COLOR', old_no_color, true)
		} else {
			os.unsetenv('NO_COLOR')
		}
		if old_force.len > 0 {
			os.setenv('VRO_FORCE_COLOR', old_force, true)
		} else {
			os.unsetenv('VRO_FORCE_COLOR')
		}
	}

	mut e := editor_new()
	e.filename = 'test.js'
	e.screencols = 80
	e.screenrows = 10

	code := 'const x = 42;\nlet y = "hello";\nif (true) {\n    return null;\n}\n'
	editor_load_buffer_content(mut e, code)
	out := editor_build_screen(mut e)

	// Keywords = magenta (35m)
	assert out.contains('\x1b[35mconst\x1b[0m')
	assert out.contains('\x1b[35mlet\x1b[0m')
	assert out.contains('\x1b[35mif\x1b[0m')
	assert out.contains('\x1b[35mreturn\x1b[0m')

	// Numbers = cyan (36m)
	assert out.contains('\x1b[36m42\x1b[0m')

	// Strings = yellow (33m)
	assert out.contains('\x1b[33m"hello"\x1b[0m')

	// Constants = bright magenta (95m)
	assert out.contains('\x1b[95mtrue\x1b[0m')
	assert out.contains('\x1b[95mnull\x1b[0m')

	// Unhighlighted identifiers (x, y) should be plain text without color codes
	// Verify no yellow/cyan/etc wrapping around x
	assert !out.contains('\x1b[33mx\x1b[0m')
	assert !out.contains('\x1b[35mx\x1b[0m')
	assert !out.contains('\x1b[95mx\x1b[0m')

	// Now test single-quoted strings
	mut e2 := editor_new()
	e2.filename = 'test.js'
	e2.screencols = 80
	e2.screenrows = 3
	editor_load_buffer_content(mut e2, "const s = 'hi';\n")
	out2 := editor_build_screen(mut e2)
	assert out2.contains("\x1b[33m'hi'\x1b[0m")

	// Test template literal
	mut e3 := editor_new()
	e3.filename = 'test.js'
	e3.screencols = 80
	e3.screenrows = 3
	editor_load_buffer_content(mut e3, 'const t = `hi`;\n')
	out3 := editor_build_screen(mut e3)
	assert out3.contains('\x1b[33m`hi`\x1b[0m')

	// Verify group_to_ansi mapping for key groups
	assert group_to_ansi('comment') == '\x1b[2m\x1b[32m'
	assert group_to_ansi('constant.string') == '\x1b[33m'
	assert group_to_ansi('constant.number') == '\x1b[36m'
	assert group_to_ansi('statement') == '\x1b[35m'
	assert group_to_ansi('type') == '\x1b[34m'
	assert group_to_ansi('symbol.brackets') == '\x1b[37m'
	assert group_to_ansi('constant') == '\x1b[95m'
	assert group_to_ansi('error') == '\x1b[91m'
	assert group_to_ansi('special') == '\x1b[32m'
	assert group_to_ansi('constant.bool') == '\x1b[95m'
	assert group_to_ansi('identifier.function') == '\x1b[96m'
	assert group_to_ansi('constant.specialchar') == '\x1b[95m'
	assert group_to_ansi('statement.built_in') == '\x1b[35m'
}
