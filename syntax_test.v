module main

fn test_vro_version() {
	assert vro_version == '0.3.4'
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
