module main

import os

fn test_vro_version() {
	assert vro_version == '0.3.6'
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
