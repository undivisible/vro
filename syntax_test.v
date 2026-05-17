module main

import os
import strings
import term.ui as tui

fn test_vro_version() {
	assert vro_version == '1.0.4'
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
	assert out.contains('\x1b[94mfn\x1b[0m')
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
	assert out.contains('\x1b[94mimport\x1b[0m')
	assert !out.contains('\x1b[90mimport')
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
	assert out.contains('\x1b[97m')
	assert out.contains('Hello')
	assert out.contains('\x1b[0m')
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
	assert ab.str().contains('\x1b[94mzap\x1b[0m')
}

fn test_local_syntax_reports_source() {
	dir, old := setup_test_v_syntax_dir()!
	defer {
		teardown_test_v_syntax_dir(dir, old)
	}
	mut syn := load_syntax_for_path('demo.v') or { panic('missing v syntax') }
	assert syn.source == os.join_path(dir, 'v.yaml')
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

fn test_csi_u_escape_maps_to_escape_key() {
	ev := tui.Event{
		typ:  .key_down
		code: .null
		utf8: '\x1b[27u'
	}
	assert tui_key_to_editor_key(ev) == int(`\x1b`)
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
