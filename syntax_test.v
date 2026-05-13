module main

import os
import strings
import term.ui as tui

fn test_vro_version() {
	assert vro_version == '0.3.8'
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

fn test_bundled_v_syntax_highlights_keywords() {
	mut syn := load_syntax_for_path('main.v') or { panic('missing v syntax') }
	mut ab := strings.new_builder(64)
	hl_draw_line_slice(mut syn, 'fn main() {', 0, 11, []bool{}, mut ab)
	out := ab.str()
	assert out.contains('\x1b[35mfn\x1b[0m')
	assert out.contains('\x1b[37m(')
}

fn test_bundled_v_line_comments_do_not_carry() {
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

fn test_embedded_v_syntax_reports_source() {
	old := os.getenv('VRO_SYNTAX_DIR')
	old_xdg := os.getenv('XDG_DATA_HOME')
	cwd := os.getwd()
	tmp := os.join_path(os.temp_dir(), 'vro-empty-syntax-cwd')
	xdg := os.join_path(os.temp_dir(), 'vro-empty-syntax-xdg')
	defer {
		if old.len > 0 {
			os.setenv('VRO_SYNTAX_DIR', old, true)
		} else {
			os.unsetenv('VRO_SYNTAX_DIR')
		}
		if old_xdg.len > 0 {
			os.setenv('XDG_DATA_HOME', old_xdg, true)
		} else {
			os.unsetenv('XDG_DATA_HOME')
		}
		os.chdir(cwd) or {}
		os.rmdir_all(tmp) or {}
		os.rmdir_all(xdg) or {}
	}
	os.rmdir_all(tmp) or {}
	os.rmdir_all(xdg) or {}
	os.mkdir_all(tmp)!
	os.mkdir_all(xdg)!
	os.chdir(tmp)!
	os.setenv('VRO_SYNTAX_DIR', os.join_path(os.temp_dir(), 'vro-missing-syntax-dir'),
		true)
	os.setenv('XDG_DATA_HOME', xdg, true)
	mut syn := load_syntax_for_path('demo.v') or { panic('missing embedded v syntax') }
	assert syn.source == 'embedded:v'
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
	assert e.cy == 1
	assert e.dirty == 0
	editor_scroll_mouse(mut e, .up)
	assert e.cy == 0
	assert e.dirty == 0
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
