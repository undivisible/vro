module main

// SPDX-License-Identifier: MPL-2.0
import os
import term.ui as tui
import strings
import time

const vro_version = '0.3.7'

const tab_stop = 4
const quit_times = 3

const key_arrow_left = 1000
const key_arrow_right = 1001
const key_arrow_up = 1002
const key_arrow_down = 1003
const key_del = 1004
const key_home = 1005
const key_end = 1006
const key_page_up = 1007
const key_page_down = 1008

enum EditorPromptKind {
	none
	command
	search
	save_name
}

fn ctrl_key(c u8) int {
	return int(c & 0x1f)
}

// Strip terminal control bytes from strings shown in the status/command line.
fn ui_sanitize_display(s string) string {
	if s.len == 0 {
		return ''
	}
	mut out := strings.new_builder(s.len)
	for i := 0; i < s.len; i++ {
		b := s[i]
		if b == 0x1b || b == 0x7f || (b < 0x20 && b != `\t`) {
			out.write_u8(`?`)
		} else {
			out.write_u8(b)
		}
	}
	return out.str()
}

fn is_unsigned_decimal_int_string(s string) bool {
	t := s.trim_space()
	if t.len == 0 {
		return false
	}
	for i := 0; i < t.len; i++ {
		if t[i] < `0` || t[i] > `9` {
			return false
		}
	}
	return true
}

struct Erow {
mut:
	chars  []u8
	render []u8
}

struct EditorConfig {
mut:
	cx             int
	cy             int
	rx             int
	rowoff         int
	coloff         int
	screenrows     int
	screencols     int
	rows           []Erow
	dirty          int
	filename       string
	trailing_nl    bool
	statusmsg      string
	statusmsg_time i64
	command_mode   bool
	command_buffer string
	prompt_kind    EditorPromptKind
	prompt_prefix  string
	prompt_text    string
	prompt_cx      int
	find_saved_cx  int
	find_saved_cy  int
	find_saved_col int
	find_saved_row int
	find_last      int = -1
	find_direction int = 1
	// Byte offset in command_buffer where the caret sits (prompt + cmd text); command_mode only.
	cmd_caret_bytes int
	// Sanitized command/status text trimmed by this many bytes so metadata fits on the right.
	cmd_line_left_skip int
	word_count         int
	words_dirty        bool = true
	quit_times_left    int
	// syntax highlighting (YAML; see syntax/)
	hl_syn        CompiledSyntax
	hl_cache_path string
	hl_disable    bool
	// Per-line region carry entering each row (multiline /* */, raw strings, …).
	hl_carry_enter      [][]bool
	hl_carry_lines      int
	hl_carry_rules      int
	hl_carry_valid      bool
	hl_carry_dirty_from int = -1 // >=0: suffix rebuild from this row (same row count as cache)
	// buffer word completion (Ctrl-N)
	complete_active   bool
	complete_prefix   string
	complete_matches  []string
	complete_idx      int
	complete_start_cx int
}

fn editor_row_cx_to_rx(row Erow, cx int) int {
	mut rx := 0
	for i in 0 .. cx {
		if i >= row.chars.len {
			break
		}
		if row.chars[i] == `\t` {
			rx += (tab_stop - 1) - (rx % tab_stop)
		} else if row.chars[i] >= 0x80 && row.chars[i] < 0xc0 {
			continue
		}
		rx++
	}
	return rx
}

fn editor_row_rx_to_cx(row Erow, rx int) int {
	mut cur_rx := 0
	for cx in 0 .. row.chars.len {
		if row.chars[cx] >= 0x80 && row.chars[cx] < 0xc0 {
			continue
		}
		if row.chars[cx] == `\t` {
			cur_rx += (tab_stop - 1) - (cur_rx % tab_stop)
		}
		cur_rx++
		if cur_rx > rx {
			return cx
		}
	}
	return row.chars.len
}

fn editor_update_row(mut row Erow) {
	mut renderer := []u8{}
	for ch in row.chars {
		if ch == `\t` {
			renderer << ` `
			for renderer.len % tab_stop != 0 {
				renderer << ` `
			}
		} else {
			renderer << ch
		}
	}
	row.render = renderer
}

fn editor_hl_carry_invalidate(mut e EditorConfig) {
	e.hl_carry_valid = false
	e.hl_carry_dirty_from = -1
}

// After in-place edits on one row, recompute carry only from `row` downward (O(tail)).
fn editor_hl_carry_mark_dirty_tail(mut e EditorConfig, row int) {
	if e.hl_disable || e.hl_syn.rules.len == 0 {
		return
	}
	if !e.hl_carry_valid || e.hl_carry_lines != e.rows.len || e.hl_carry_rules != e.hl_syn.rules.len
		|| e.hl_carry_enter.len != e.rows.len {
		return
	}
	if e.rows.len == 0 {
		return
	}
	mut r := row
	if r < 0 {
		r = 0
	}
	if r >= e.rows.len {
		r = e.rows.len - 1
	}
	if e.hl_carry_dirty_from < 0 || r < e.hl_carry_dirty_from {
		e.hl_carry_dirty_from = r
	}
}

fn editor_insert_row(mut e EditorConfig, at int, s string) {
	if at < 0 || at > e.rows.len {
		return
	}
	mut row := Erow{
		chars:  s.bytes()
		render: []
	}
	editor_update_row(mut row)
	e.rows.insert(at, row)
	e.dirty++
	e.words_dirty = true
	editor_hl_carry_invalidate(mut e)
}

fn editor_del_row(mut e EditorConfig, at int) {
	if at < 0 || at >= e.rows.len {
		return
	}
	e.rows.delete(at)
	e.dirty++
	e.words_dirty = true
	editor_hl_carry_invalidate(mut e)
}

fn editor_row_insert_char(mut row Erow, at int, c u8) {
	mut idx := at
	if idx < 0 || idx > row.chars.len {
		idx = row.chars.len
	}
	row.chars.insert(idx, c)
	editor_update_row(mut row)
}

fn editor_row_append_string(mut row Erow, s []u8) {
	row.chars << s
	editor_update_row(mut row)
}

fn editor_row_del_char(mut row Erow, at int) {
	if at < 0 || at >= row.chars.len {
		return
	}
	row.chars.delete(at)
	editor_update_row(mut row)
}

fn editor_insert_char(mut e EditorConfig, c u8) {
	mut added_row := false
	if e.cy == e.rows.len {
		editor_insert_row(mut e, e.rows.len, '')
		added_row = true
	}
	mut row := e.rows[e.cy]
	editor_row_insert_char(mut row, e.cx, c)
	e.rows[e.cy] = row
	e.cx++
	e.dirty++
	e.words_dirty = true
	if !added_row {
		editor_hl_carry_mark_dirty_tail(mut e, e.cy)
	}
}

fn editor_insert_newline(mut e EditorConfig) {
	if e.cx == 0 {
		editor_insert_row(mut e, e.cy, '')
	} else {
		current := e.rows[e.cy]
		left := current.chars[..e.cx].bytestr()
		right := current.chars[e.cx..].bytestr()
		mut row := e.rows[e.cy]
		row.chars = left.bytes()
		editor_update_row(mut row)
		e.rows[e.cy] = row
		editor_insert_row(mut e, e.cy + 1, right)
	}
	e.cy++
	e.cx = 0
}

fn editor_del_char(mut e EditorConfig) {
	if e.cy == e.rows.len {
		return
	}
	if e.cx == 0 && e.cy == 0 {
		return
	}
	if e.cx > 0 {
		mut row := e.rows[e.cy]
		editor_row_del_char(mut row, e.cx - 1)
		e.rows[e.cy] = row
		e.cx--
	} else {
		prev_len := e.rows[e.cy - 1].chars.len
		mut prev_row := e.rows[e.cy - 1]
		current := e.rows[e.cy]
		editor_row_append_string(mut prev_row, current.chars)
		e.rows[e.cy - 1] = prev_row
		editor_del_row(mut e, e.cy)
		e.cy--
		e.cx = prev_len
		e.dirty++
		return
	}
	e.dirty++
	editor_hl_carry_mark_dirty_tail(mut e, e.cy)
}

fn editor_rows_to_string(e EditorConfig) string {
	mut sb := strings.new_builder(1024)
	for i, row in e.rows {
		sb.write_string(row.chars.bytestr())
		if i != e.rows.len - 1 {
			sb.write_u8(`\n`)
		}
	}
	if e.trailing_nl {
		sb.write_u8(`\n`)
	}
	return sb.str()
}

fn editor_load_buffer_content(mut e EditorConfig, content string) {
	e.rows = []Erow{}
	for line in content.split_into_lines() {
		mut row := Erow{
			chars:  line.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		e.rows << row
	}
	e.trailing_nl = content.ends_with('\n')
	e.words_dirty = true
	editor_hl_carry_invalidate(mut e)
}

fn editor_open(mut e EditorConfig, filename string) ! {
	e.hl_cache_path = ''
	e.filename = filename
	content := os.read_file(filename)!
	editor_load_buffer_content(mut e, content)
	e.cx = 0
	e.cy = 0
	e.rx = 0
	e.rowoff = 0
	e.coloff = 0
	e.dirty = 0
}

fn editor_open_into_buffer(mut e EditorConfig, filename string) ! {
	e.hl_cache_path = ''
	content := os.read_file(filename)!
	editor_load_buffer_content(mut e, content)
	e.filename = filename
	e.cx = 0
	e.cy = 0
	e.rx = 0
	e.rowoff = 0
	e.coloff = 0
	e.dirty = 0
}

fn editor_save_to_path(mut e EditorConfig, filename string) bool {
	data := editor_rows_to_string(e)
	os.write_file(filename, data) or {
		editor_set_status_message(mut e, 'Cannot save! I/O error')
		return false
	}
	e.filename = filename
	e.dirty = 0
	e.quit_times_left = quit_times
	editor_set_status_message(mut e, '${data.len} bytes written to disk')
	return true
}

fn editor_save(mut e EditorConfig) bool {
	mut filename := e.filename
	if filename == '' {
		editor_begin_prompt(mut e, .save_name, '> ', '')
		return false
	}

	return editor_save_to_path(mut e, filename)
}

fn digit_count(n int) int {
	mut v := n
	if v < 1 {
		v = 1
	}
	mut digits := 1
	for v >= 10 {
		v /= 10
		digits++
	}
	return digits
}

fn editor_line_gutter_width(e EditorConfig) int {
	total_lines := if e.rows.len == 0 { 1 } else { e.rows.len }
	return digit_count(total_lines) + 1
}

fn editor_text_screencols(e EditorConfig) int {
	mut cols := e.screencols - editor_line_gutter_width(e)
	if cols < 1 {
		cols = 1
	}
	return cols
}

fn editor_append_line_gutter(e EditorConfig, mut ab strings.Builder, filerow int) {
	width := editor_line_gutter_width(e) - 1
	mut label := ''
	if filerow < e.rows.len {
		label = (filerow + 1).str()
	}
	for _ in label.len .. width {
		ab.write_u8(` `)
	}
	ab.write_string('\x1b[90m')
	ab.write_string(label)
	ab.write_u8(` `)
	ab.write_string('\x1b[0m')
}

fn editor_find_literal(mut e EditorConfig, query string) bool {
	if query.len == 0 || e.rows.len == 0 {
		return false
	}
	mut current := e.cy
	for _ in 0 .. e.rows.len {
		row := e.rows[current]
		idx := row.render.bytestr().index(query) or { -1 }
		if idx != -1 {
			e.cy = current
			e.cx = editor_row_rx_to_cx(row, idx)
			e.rowoff = e.rows.len
			return true
		}
		current++
		if current >= e.rows.len {
			current = 0
		}
	}
	return false
}

fn editor_ensure_syntax(mut e EditorConfig) {
	if e.hl_disable {
		return
	}
	if e.filename == e.hl_cache_path {
		return
	}
	e.hl_cache_path = e.filename
	editor_hl_carry_invalidate(mut e)
	if e.filename.len == 0 {
		e.hl_syn = CompiledSyntax{}
		return
	}
	if s := load_syntax_for_path(e.filename) {
		e.hl_syn = s
	} else {
		e.hl_syn = CompiledSyntax{}
	}
}

fn editor_ensure_hl_carry(mut e EditorConfig) {
	if e.hl_disable || e.hl_syn.rules.len == 0 {
		e.hl_carry_enter = [][]bool{}
		e.hl_carry_lines = e.rows.len
		e.hl_carry_rules = e.hl_syn.rules.len
		e.hl_carry_dirty_from = -1
		e.hl_carry_valid = true
		return
	}
	rl := e.hl_syn.rules.len

	if e.hl_carry_valid && e.hl_carry_dirty_from >= 0 && e.hl_carry_lines == e.rows.len
		&& e.hl_carry_rules == rl && e.hl_carry_enter.len == e.rows.len
		&& e.hl_carry_dirty_from < e.rows.len {
		tf := e.hl_carry_dirty_from
		mut carry := []bool{len: rl, init: false}
		for ri in 0 .. rl {
			carry[ri] = e.hl_carry_enter[tf][ri]
		}
		for li in tf .. e.rows.len {
			mut snap := []bool{len: rl, init: false}
			for ri in 0 .. rl {
				snap[ri] = carry[ri]
			}
			e.hl_carry_enter[li] = snap
			line := e.rows[li].render.bytestr()
			carry = hl_carry_row(mut e.hl_syn, line, carry)
		}
		e.hl_carry_dirty_from = -1
		return
	}

	if e.hl_carry_valid && e.hl_carry_dirty_from < 0 && e.hl_carry_lines == e.rows.len
		&& e.hl_carry_rules == rl {
		return
	}

	e.hl_carry_dirty_from = -1
	mut carry := []bool{len: rl, init: false}
	e.hl_carry_enter = [][]bool{}
	for li in 0 .. e.rows.len {
		mut snap := []bool{len: rl, init: false}
		for ri in 0 .. rl {
			snap[ri] = carry[ri]
		}
		e.hl_carry_enter << snap
		line := e.rows[li].render.bytestr()
		carry = hl_carry_row(mut e.hl_syn, line, carry)
	}
	e.hl_carry_lines = e.rows.len
	e.hl_carry_rules = rl
	e.hl_carry_valid = true
}

fn editor_scroll(mut e EditorConfig) {
	e.rx = 0
	if e.cy < e.rows.len {
		e.rx = editor_row_cx_to_rx(e.rows[e.cy], e.cx)
	}
	if e.cy < e.rowoff {
		e.rowoff = e.cy
	}
	if e.cy >= e.rowoff + e.screenrows {
		e.rowoff = e.cy - e.screenrows + 1
	}
	if e.rx < e.coloff {
		e.coloff = e.rx
	}
	text_cols := editor_text_screencols(e)
	if e.rx >= e.coloff + text_cols {
		e.coloff = e.rx - text_cols + 1
	}
}

fn editor_draw_rows(mut e EditorConfig, mut ab strings.Builder) {
	editor_ensure_syntax(mut e)
	editor_ensure_hl_carry(mut e)
	for y in 0 .. e.screenrows {
		filerow := y + e.rowoff
		editor_append_line_gutter(e, mut ab, filerow)
		if filerow >= e.rows.len {
			// Keep empty rows visually blank like a plain editor.
		} else {
			render := e.rows[filerow].render.bytestr()
			mut len := render.len - e.coloff
			if len < 0 {
				len = 0
			}
			text_cols := editor_text_screencols(e)
			if len > text_cols {
				len = text_cols
			}
			if len > 0 {
				if e.hl_syn.rules.len > 0 && !e.hl_disable {
					carry_in := if filerow < e.hl_carry_enter.len {
						e.hl_carry_enter[filerow]
					} else {
						[]bool{}
					}
					hl_draw_line_slice(mut e.hl_syn, render, e.coloff, len, carry_in, mut ab)
				} else {
					ab.write_string(render[e.coloff..e.coloff + len])
				}
			}
		}
		ab.write_string('\x1b[K')
		ab.write_string('\r\n')
	}
}

fn editor_word_count_recompute(e EditorConfig) int {
	mut in_word := false
	mut words := 0
	for row in e.rows {
		for ch in row.chars {
			is_space := ch == ` ` || ch == `\t` || ch == `\n` || ch == `\r`
			if is_space {
				in_word = false
			} else if !in_word {
				in_word = true
				words++
			}
		}
		in_word = false
	}
	return words
}

fn editor_word_count_get(mut e EditorConfig) int {
	if e.words_dirty {
		e.word_count = editor_word_count_recompute(e)
		e.words_dirty = false
	}
	return e.word_count
}

fn editor_status_footer_parts(mut e EditorConfig) (string, string) {
	mut raw_left := ''
	if e.command_mode {
		raw_left = e.command_buffer
	} else if time.now().unix() - e.statusmsg_time < 3 {
		raw_left = e.statusmsg
	}
	left_full := ui_sanitize_display(raw_left)

	filename := if e.filename == '' { '[No Name]' } else { e.filename }
	modified := if e.dirty > 0 { '*' } else { '' }
	total_lines := if e.rows.len == 0 { 1 } else { e.rows.len }
	wc := if e.command_mode {
		e.word_count
	} else {
		editor_word_count_get(mut e)
	}
	mut line_no := e.cy + 1
	if e.cy >= e.rows.len {
		line_no = total_lines
	}
	col_no := e.cx + 1
	right := if e.command_mode {
		ui_sanitize_display('${filename}${modified} ${wc}w L${line_no}/${total_lines} C${col_no}')
	} else {
		ui_sanitize_display('${filename}${modified} L${line_no}/${total_lines} C${col_no} ${wc}w')
	}
	return left_full, right
}

// One bottom line: reserve columns for dim metadata on the right; truncate command/status from the left.
fn editor_append_status_line(mut e EditorConfig, mut ab strings.Builder) {
	left_full, right := editor_status_footer_parts(mut e)

	mut max_left := e.screencols - right.len
	if max_left < 1 {
		max_left = 1
	}
	mut skip := 0
	mut visible := left_full
	if left_full.len > max_left {
		skip = left_full.len - max_left
		visible = left_full[skip..]
	}
	if e.command_mode {
		e.cmd_line_left_skip = skip
	} else {
		e.cmd_line_left_skip = 0
	}

	ab.write_string(visible)
	mut used := visible.len
	target := e.screencols - right.len
	for used < target {
		ab.write_u8(` `)
		used++
	}
	if right.len > 0 {
		ab.write_string('\x1b[90m')
		ab.write_string(right)
		ab.write_string('\x1b[0m')
	}
}

fn editor_footer_caret_column(mut e EditorConfig) int {
	if !e.command_mode {
		return 1
	}
	_, right := editor_status_footer_parts(mut e)
	mut max_left := e.screencols - right.len
	if max_left < 1 {
		max_left = 1
	}
	mut cx := e.cmd_caret_bytes - e.cmd_line_left_skip + 1
	if cx < 1 {
		cx = 1
	}
	if cx > max_left {
		cx = max_left
	}
	return cx
}

fn editor_draw_status_bar(mut e EditorConfig, mut ab strings.Builder) {
	editor_append_status_line(mut e, mut ab)
}

fn editor_build_screen(mut e EditorConfig) string {
	editor_scroll(mut e)

	mut ab := strings.new_builder(4096)
	ab.write_string('\x1b[?25l')
	ab.write_string('\x1b[H')
	editor_draw_rows(mut e, mut ab)
	editor_draw_status_bar(mut e, mut ab)
	mut cursor_y := (e.cy - e.rowoff) + 1
	mut cursor_x := editor_line_gutter_width(e) + (e.rx - e.coloff) + 1
	if e.command_mode {
		cursor_y = e.screenrows + 1
		cursor_x = editor_footer_caret_column(mut e)
	}
	if cursor_y < 1 {
		cursor_y = 1
	}
	if cursor_x < 1 {
		cursor_x = 1
	}
	ab.write_string('\x1b[${cursor_y};${cursor_x}H')
	ab.write_string('\x1b[?25h')
	return ab.str()
}

fn editor_set_status_message(mut e EditorConfig, msg string) {
	e.statusmsg = ui_sanitize_display(msg)
	e.statusmsg_time = time.now().unix()
}

fn editor_move_cursor(mut e EditorConfig, key int) {
	match key {
		key_arrow_left {
			if e.cx != 0 {
				e.cx--
			} else if e.cy > 0 {
				e.cy--
				e.cx = e.rows[e.cy].chars.len
			}
		}
		key_arrow_right {
			if e.cy < e.rows.len {
				row_len := e.rows[e.cy].chars.len
				if e.cx < row_len {
					e.cx++
				} else if e.cx == row_len {
					e.cy++
					e.cx = 0
				}
			}
		}
		key_arrow_up {
			if e.cy != 0 {
				e.cy--
			}
		}
		key_arrow_down {
			if e.cy < e.rows.len {
				e.cy++
			}
		}
		else {}
	}

	row_len := if e.cy < e.rows.len { e.rows[e.cy].chars.len } else { 0 }
	if e.cx > row_len {
		e.cx = row_len
	}
}

fn editor_begin_prompt(mut e EditorConfig, kind EditorPromptKind, prefix string, text string) {
	e.command_mode = true
	e.prompt_kind = kind
	e.prompt_prefix = prefix
	e.prompt_text = text
	e.prompt_cx = text.len
	e.command_buffer = prefix + text
	e.cmd_caret_bytes = prefix.len + e.prompt_cx
}

fn editor_end_prompt(mut e EditorConfig) {
	e.command_mode = false
	e.command_buffer = ''
	e.prompt_kind = .none
	e.prompt_prefix = ''
	e.prompt_text = ''
	e.prompt_cx = 0
	e.cmd_caret_bytes = 0
}

fn editor_sync_prompt_display(mut e EditorConfig) {
	e.command_buffer = e.prompt_prefix + e.prompt_text
	e.cmd_caret_bytes = e.prompt_prefix.len + e.prompt_cx
}

fn editor_find_callback(mut e EditorConfig, query string, key int) {
	if key == int(`\r`) || key == int(`\x1b`) {
		e.find_last = -1
		e.find_direction = 1
		return
	} else if key == key_arrow_right || key == key_arrow_down {
		e.find_direction = 1
	} else if key == key_arrow_left || key == key_arrow_up {
		e.find_direction = -1
	} else {
		e.find_last = -1
		e.find_direction = 1
	}

	if e.find_last == -1 {
		e.find_direction = 1
	}
	mut current := e.find_last
	for _ in 0 .. e.rows.len {
		current += e.find_direction
		if current == -1 {
			current = e.rows.len - 1
		} else if current == e.rows.len {
			current = 0
		}

		row := e.rows[current]
		idx := row.render.bytestr().index(query) or { -1 }
		if idx != -1 {
			e.find_last = current
			e.cy = current
			e.cx = editor_row_rx_to_cx(row, idx)
			e.rowoff = e.rows.len
			break
		}
	}
}

fn editor_find(mut e EditorConfig) {
	e.find_saved_cx = e.cx
	e.find_saved_cy = e.cy
	e.find_saved_col = e.coloff
	e.find_saved_row = e.rowoff
	e.find_last = -1
	e.find_direction = 1
	editor_begin_prompt(mut e, .search, 'Search: ', '')
}

fn editor_command_bar(mut e EditorConfig) bool {
	editor_begin_prompt(mut e, .command, ': ', '')
	return true
}

fn editor_cancel_prompt(mut e EditorConfig) {
	if e.prompt_kind == .search {
		e.cx = e.find_saved_cx
		e.cy = e.find_saved_cy
		e.coloff = e.find_saved_col
		e.rowoff = e.find_saved_row
	}
	editor_end_prompt(mut e)
	editor_set_status_message(mut e, '')
}

fn editor_submit_prompt(mut e EditorConfig) bool {
	kind := e.prompt_kind
	input := e.prompt_text
	editor_end_prompt(mut e)
	match kind {
		.command {
			return editor_run_command(mut e, input)
		}
		.search {
			return true
		}
		.save_name {
			if input.len > 0 {
				editor_save_to_path(mut e, input)
			}
			return true
		}
		.none {
			return true
		}
	}
}

fn editor_prompt_insert(mut e EditorConfig, text string) {
	if text.len == 0 {
		return
	}
	e.prompt_text = e.prompt_text[..e.prompt_cx] + text + e.prompt_text[e.prompt_cx..]
	e.prompt_cx += text.len
	editor_sync_prompt_display(mut e)
	if e.prompt_kind == .search {
		editor_find_callback(mut e, e.prompt_text, 0)
	}
}

fn editor_prompt_key(mut e EditorConfig, key int) bool {
	match key {
		key_arrow_left {
			if e.prompt_kind == .search {
				editor_find_callback(mut e, e.prompt_text, key)
			} else if e.prompt_cx > 0 {
				e.prompt_cx--
			}
		}
		key_arrow_right {
			if e.prompt_kind == .search {
				editor_find_callback(mut e, e.prompt_text, key)
			} else if e.prompt_cx < e.prompt_text.len {
				e.prompt_cx++
			}
		}
		key_arrow_up, key_arrow_down {
			if e.prompt_kind == .search {
				editor_find_callback(mut e, e.prompt_text, key)
			}
		}
		key_home {
			e.prompt_cx = 0
		}
		key_end {
			e.prompt_cx = e.prompt_text.len
		}
		key_del {
			if e.prompt_cx < e.prompt_text.len {
				e.prompt_text = e.prompt_text[..e.prompt_cx] + e.prompt_text[e.prompt_cx + 1..]
				if e.prompt_kind == .search {
					editor_find_callback(mut e, e.prompt_text, key)
				}
			}
		}
		ctrl_key(`h`), int(`\x7f`) {
			if e.prompt_cx > 0 {
				e.prompt_text = e.prompt_text[..e.prompt_cx - 1] + e.prompt_text[e.prompt_cx..]
				e.prompt_cx--
				if e.prompt_kind == .search {
					editor_find_callback(mut e, e.prompt_text, key)
				}
			}
		}
		int(`\x1b`) {
			editor_cancel_prompt(mut e)
			return true
		}
		int(`\r`) {
			if e.prompt_text.len != 0 || e.prompt_kind == .search || e.prompt_kind == .command {
				return editor_submit_prompt(mut e)
			}
		}
		else {}
	}

	editor_sync_prompt_display(mut e)
	return true
}

fn editor_run_command(mut e EditorConfig, input string) bool {
	cmdline := input.trim_space()
	if cmdline.len == 0 {
		return true
	}
	parts := cmdline.split(' ')
	cmd := parts[0].to_lower()
	args := if parts.len > 1 { cmdline[cmd.len + 1..].trim_space() } else { '' }

	match cmd {
		'q', 'quit', 'exit', 'x' {
			if e.dirty > 0 {
				editor_set_status_message(mut e, 'Unsaved changes. Use quit! or Ctrl-Q to force.')
				return true
			}
			print('\x1b[2J')
			print('\x1b[H')
			return false
		}
		'q!', 'quit!', 'exit!', 'x!' {
			print('\x1b[2J')
			print('\x1b[H')
			return false
		}
		'wq' {
			saved := if args.len > 0 { editor_save_to_path(mut e, args) } else { editor_save(mut e) }
			if !saved {
				return true
			}
			if e.dirty > 0 {
				return true
			}
			print('\x1b[2J')
			print('\x1b[H')
			return false
		}
		'w', 'write', 'save' {
			if args.len > 0 {
				editor_save_to_path(mut e, args)
			} else {
				editor_save(mut e)
			}
		}
		'saveas' {
			if args.len == 0 {
				editor_set_status_message(mut e, 'Usage: saveas <path>')
				return true
			}
			editor_save_to_path(mut e, args)
		}
		'open', 'o', 'open!', 'o!' {
			if args.len == 0 {
				editor_set_status_message(mut e, 'Usage: open <path>')
				return true
			}
			if e.dirty > 0 && cmd != 'open!' && cmd != 'o!' {
				editor_set_status_message(mut e, 'Unsaved changes. Use open! to discard.')
				return true
			}
			editor_open_into_buffer(mut e, args) or {
				editor_set_status_message(mut e, 'Open failed: ${err.msg()}')
				return true
			}
			editor_set_status_message(mut e, 'Opened ${args}')
		}
		'find', '/' {
			if args.len == 0 {
				editor_find(mut e)
				return true
			}
			if editor_find_literal(mut e, args) {
				editor_set_status_message(mut e, 'Found "${args}"')
			} else {
				editor_set_status_message(mut e, 'No match for "${args}"')
			}
		}
		'goto', 'g' {
			if args.len == 0 {
				editor_set_status_message(mut e, 'Usage: goto <line>')
				return true
			}
			if !is_unsigned_decimal_int_string(args) {
				editor_set_status_message(mut e, 'goto expects a positive integer line number')
				return true
			}
			line := args.trim_space().int()
			if line <= 0 {
				editor_set_status_message(mut e, 'Invalid line number')
				return true
			}
			mut target := line - 1
			if target > e.rows.len {
				target = e.rows.len
			}
			e.cy = target
			if e.cy < e.rows.len && e.cx > e.rows[e.cy].chars.len {
				e.cx = e.rows[e.cy].chars.len
			}
			editor_set_status_message(mut e, 'Moved to line ${target + 1}')
		}
		'help' {
			editor_set_status_message(mut e,
				'open/o open!/o! w/wq write/save saveas find goto/g quit/exit/x quit! help')
		}
		else {
			editor_set_status_message(mut e, 'Unknown command: ${cmd}')
		}
	}

	return true
}

fn editor_complete_reset(mut e EditorConfig) {
	e.complete_active = false
	e.complete_prefix = ''
	e.complete_matches = []string{}
	e.complete_idx = 0
	e.complete_start_cx = 0
}

fn is_html_filename(fname string) bool {
	ext := os.file_ext(fname).to_lower()
	return ext == '.html' || ext == '.htm'
}

fn emmet_is_void(tag string) bool {
	t := tag.to_lower()
	return match t {
		'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param',
		'source', 'track', 'wbr' {
			true
		}
		else {
			false
		}
	}
}

fn is_word_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`
}

fn indent_inner_spaces(n int) string {
	if n <= 0 {
		return ''
	}
	mut b := strings.new_builder(n)
	for _ in 0 .. n {
		b.write_u8(` `)
	}
	return b.str()
}

fn editor_try_emmet_tab(mut e EditorConfig) bool {
	if !is_html_filename(e.filename) {
		return false
	}
	if e.cy >= e.rows.len {
		return false
	}
	line := e.rows[e.cy].chars.bytestr()
	if e.cx != line.len {
		return false
	}
	mut start := e.cx
	for start > 0 && is_word_byte(line[start - 1]) {
		start--
	}
	if start == e.cx {
		return false
	}
	tag := line[start..e.cx]
	for i in 0 .. start {
		ch := line[i]
		if ch != ` ` && ch != `\t` {
			return false
		}
	}
	for i in 0 .. tag.len {
		c := tag[i]
		is_ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
			|| (c >= `0` && c <= `9`) || c == `-`
		if !is_ok {
			return false
		}
	}
	ltag := tag.to_lower()
	indent_prefix := line[..start]
	if emmet_is_void(ltag) {
		newline := '${indent_prefix}<${ltag}>'
		mut row := e.rows[e.cy]
		row.chars = newline.bytes()
		editor_update_row(mut row)
		e.rows[e.cy] = row
		e.cx = row.chars.len
		e.dirty++
		e.words_dirty = true
		editor_hl_carry_mark_dirty_tail(mut e, e.cy)
		editor_complete_reset(mut e)
		return true
	}
	line1 := '${indent_prefix}<${ltag}>'
	line2 := indent_prefix + indent_inner_spaces(tab_stop)
	line3 := '${indent_prefix}</${ltag}>'
	editor_del_row(mut e, e.cy)
	editor_insert_row(mut e, e.cy, line1)
	editor_insert_row(mut e, e.cy + 1, line2)
	editor_insert_row(mut e, e.cy + 2, line3)
	e.cy = e.cy + 1
	e.cx = e.rows[e.cy].chars.len
	e.dirty++
	e.words_dirty = true
	editor_hl_carry_mark_dirty_tail(mut e, e.cy - 2)
	editor_complete_reset(mut e)
	return true
}

fn word_bounds_before_cx(line string, cx int) (int, int) {
	mut end := cx
	if end > line.len {
		end = line.len
	}
	mut start := end
	for start > 0 && is_word_byte(line[start - 1]) {
		start--
	}
	return start, end
}

fn editor_collect_buffer_words(e EditorConfig) []string {
	mut seen := map[string]bool{}
	mut out := []string{}
	for row in e.rows {
		line := row.chars.bytestr()
		mut i := 0
		for i < line.len {
			if !is_word_byte(line[i]) {
				i++
				continue
			}
			mut j := i
			for j < line.len && is_word_byte(line[j]) {
				j++
			}
			w := line[i..j]
			if w.len > 0 && !seen[w] {
				seen[w] = true
				out << w
			}
			i = j
		}
	}
	out.sort()
	return out
}

fn editor_cycle_word_completion(mut e EditorConfig) {
	if e.cy >= e.rows.len {
		return
	}
	mut line := e.rows[e.cy].chars.bytestr()
	if !e.complete_active {
		start, end := word_bounds_before_cx(line, e.cx)
		if start == end {
			editor_set_status_message(mut e, 'No word at cursor')
			return
		}
		prefix := line[start..end]
		e.complete_prefix = prefix
		e.complete_start_cx = start
		e.complete_matches = []string{}
		allw := editor_collect_buffer_words(e)
		for w in allw {
			if w.len > prefix.len && w.starts_with(prefix) {
				e.complete_matches << w
			}
		}
		if e.complete_matches.len == 0 {
			editor_set_status_message(mut e, 'No completions')
			e.complete_active = false
			return
		}
		e.complete_active = true
		e.complete_idx = -1
	}
	e.complete_idx = (e.complete_idx + 1) % e.complete_matches.len
	repl := e.complete_matches[e.complete_idx]
	start := e.complete_start_cx
	old_end := e.cx
	line = e.rows[e.cy].chars.bytestr()
	if old_end < start || old_end > line.len {
		editor_complete_reset(mut e)
		return
	}
	left := line[..start]
	right := line[old_end..]
	newl := left + repl + right
	mut row := e.rows[e.cy]
	row.chars = newl.bytes()
	editor_update_row(mut row)
	e.rows[e.cy] = row
	e.cx = start + repl.len
	e.dirty++
	e.words_dirty = true
	editor_hl_carry_mark_dirty_tail(mut e, e.cy)
	editor_set_status_message(mut e, 'complete ${e.complete_idx + 1}/${e.complete_matches.len}')
}

fn editor_click_from_mouse(mut e EditorConfig, term_row int, term_col int) {
	if e.command_mode {
		return
	}
	if term_row < 1 || term_row > e.screenrows {
		return
	}
	filerow := e.rowoff + term_row - 1
	if filerow < 0 {
		return
	}
	if filerow >= e.rows.len {
		e.cy = e.rows.len
		e.cx = 0
		editor_complete_reset(mut e)
		return
	}
	e.cy = filerow
	mut rx := term_col - 1
	if rx < 0 {
		rx = 0
	}
	row := e.rows[filerow]
	e.cx = editor_row_rx_to_cx(row, rx)
	editor_complete_reset(mut e)
}

fn editor_insert_tab_or_spaces(mut e EditorConfig) {
	editor_complete_reset(mut e)
	if e.cy == e.rows.len {
		editor_insert_row(mut e, e.rows.len, '')
	}
	row := e.rows[e.cy]
	pos := editor_row_cx_to_rx(row, e.cx)
	mut n := tab_stop - (pos % tab_stop)
	if n == 0 {
		n = tab_stop
	}
	for _ in 0 .. n {
		editor_insert_char(mut e, ` `)
	}
}

fn editor_handle_ctrl_q(mut e EditorConfig) bool {
	if e.dirty == 0 {
		return false
	}
	e.quit_times_left--
	if e.quit_times_left > 0 {
		press_word := if e.quit_times_left == 1 { 'press' } else { 'presses' }
		editor_set_status_message(mut e,
			'Unsaved (${e.quit_times_left} more Ctrl-Q ${press_word} forces quit)')
		return true
	}
	return false
}

fn editor_insert_text(mut e EditorConfig, text string) {
	for b in text.bytes() {
		editor_insert_char(mut e, b)
	}
}

fn editor_process_key(mut e EditorConfig, c int, text string) bool {
	if e.command_mode {
		if text.len > 0 && c != int(`\r`) && c != int(`\x1b`) && c != int(`\x7f`) && c != int(`\t`) {
			editor_prompt_insert(mut e, text)
			return true
		}
		return editor_prompt_key(mut e, c)
	}
	if c == ctrl_key(`q`) {
		return editor_handle_ctrl_q(mut e)
	}
	dirty_before := e.dirty
	match c {
		int(`\r`) {
			editor_complete_reset(mut e)
			editor_insert_newline(mut e)
		}
		ctrl_key(`s`) {
			_ = editor_save(mut e)
		}
		ctrl_key(`f`) {
			editor_find(mut e)
		}
		ctrl_key(`e`) {
			if !editor_command_bar(mut e) {
				return false
			}
		}
		ctrl_key(`n`) {
			editor_cycle_word_completion(mut e)
		}
		int(`\t`) {
			if !editor_try_emmet_tab(mut e) {
				editor_insert_tab_or_spaces(mut e)
			}
		}
		key_home {
			editor_complete_reset(mut e)
			e.cx = 0
		}
		key_end {
			editor_complete_reset(mut e)
			if e.cy < e.rows.len {
				e.cx = e.rows[e.cy].chars.len
			}
		}
		ctrl_key(`l`), int(`\x1b`) {}
		key_page_up, key_page_down {
			editor_complete_reset(mut e)
			if c == key_page_up {
				e.cy = e.rowoff
			} else if c == key_page_down {
				e.cy = e.rowoff + e.screenrows - 1
				if e.cy > e.rows.len {
					e.cy = e.rows.len
				}
			}
			for _ in 0 .. e.screenrows {
				editor_move_cursor(mut e, if c == key_page_up {
					key_arrow_up
				} else {
					key_arrow_down
				})
			}
		}
		key_arrow_up, key_arrow_down, key_arrow_left, key_arrow_right {
			editor_complete_reset(mut e)
			editor_move_cursor(mut e, c)
		}
		key_del, ctrl_key(`h`), int(`\x7f`) {
			editor_complete_reset(mut e)
			if c == key_del {
				editor_move_cursor(mut e, key_arrow_right)
			}
			editor_del_char(mut e)
		}
		ctrl_key(`u`) {
			editor_complete_reset(mut e)
			for _ in 0 .. 16 {
				editor_del_char(mut e)
			}
		}
		else {
			if text.len > 0 {
				editor_complete_reset(mut e)
				editor_insert_text(mut e, text)
			} else if c >= 32 && c <= 126 {
				editor_complete_reset(mut e)
				editor_insert_char(mut e, u8(c))
			}
		}
	}

	if e.dirty != dirty_before || e.dirty == 0 {
		e.quit_times_left = quit_times
	}
	return true
}

struct VroApp {
mut:
	tui          &tui.Context = unsafe { nil }
	editor       EditorConfig
	needs_redraw bool = true
	should_quit  bool
}

fn editor_sync_terminal_size(mut e EditorConfig, width int, height int) {
	mut rows := height - 1
	if rows < 1 {
		rows = 1
	}
	mut cols := width
	if cols < 1 {
		cols = 1
	}
	e.screenrows = rows
	e.screencols = cols
}

fn tui_key_to_editor_key(ev &tui.Event) int {
	code_int := int(ev.code)
	if ev.modifiers.has(.ctrl) && code_int >= int(tui.KeyCode.a) && code_int <= int(tui.KeyCode.z) {
		return ctrl_key(u8(code_int))
	}
	return match ev.code {
		.enter {
			int(`\r`)
		}
		.escape {
			int(`\x1b`)
		}
		.tab {
			int(`\t`)
		}
		.backspace {
			int(`\x7f`)
		}
		.delete {
			key_del
		}
		.left {
			key_arrow_left
		}
		.right {
			key_arrow_right
		}
		.up {
			key_arrow_up
		}
		.down {
			key_arrow_down
		}
		.home {
			key_home
		}
		.end {
			key_end
		}
		.page_up {
			key_page_up
		}
		.page_down {
			key_page_down
		}
		else {
			int(ev.ascii)
		}
	}
}

fn tui_key_text(ev &tui.Event) string {
	if ev.modifiers.has(.ctrl) || ev.modifiers.has(.alt) {
		return ''
	}
	if ev.utf8.len > 0 && ev.code != .enter && ev.code != .tab && ev.code != .backspace
		&& ev.code != .delete && ev.code != .escape {
		return ev.utf8
	}
	if ev.ascii >= 32 && ev.ascii <= 126 {
		return ev.ascii.ascii_str()
	}
	return ''
}

fn vro_event(ev &tui.Event, x voidptr) {
	mut app := unsafe { &VroApp(x) }
	match ev.typ {
		.key_down {
			key := tui_key_to_editor_key(ev)
			text := tui_key_text(ev)
			if !editor_process_key(mut app.editor, key, text) {
				app.should_quit = true
			}
			app.needs_redraw = true
		}
		.mouse_down {
			if ev.button == .left {
				editor_click_from_mouse(mut app.editor, ev.y, ev.x)
				app.needs_redraw = true
			}
		}
		.resized {
			editor_sync_terminal_size(mut app.editor, ev.width, ev.height)
			app.needs_redraw = true
		}
		else {}
	}
}

fn vro_init(_ voidptr) {
	if os.getenv('VRO_NO_MOUSE').len == 0 {
		print('\x1b[?1003h\x1b[?1006h')
		flush_stdout()
	}
}

fn vro_frame(x voidptr) {
	mut app := unsafe { &VroApp(x) }
	editor_sync_terminal_size(mut app.editor, app.tui.window_width, app.tui.window_height)
	if !app.needs_redraw {
		if app.should_quit {
			exit(0)
		}
		return
	}
	app.tui.write(editor_build_screen(mut app.editor))
	app.tui.flush()
	app.needs_redraw = false
	if app.should_quit {
		exit(0)
	}
}

fn print_vro_version() {
	println('vro ${vro_version}')
}

fn print_vro_help() {
	println('vro ${vro_version} — minimal terminal text editor')
	println('')
	println('Usage:')
	println('  vro [options] [file]')
	println('')
	println('Options:')
	println('  -h, -help, --help     Show this help and exit')
	println('  -version, --version   Print version and exit')
	println('')
	println('Editing: Tab indent; .html/.htm only: Tab expands tag at EOL (emmet-lite).')
	println('Ctrl-N cycles buffer word completions. Mouse: left click moves cursor (xterm SGR).')
	println('Line numbers are shown in the left gutter.')
	println('Ctrl-Q: quit; if buffer dirty, press Ctrl-Q three times to force quit (or save first).')
	println('VRO_NO_MOUSE=1 disables mouse. NO_COLOR / VRO_NO_HL=1 disable highlighting.')
	println('')
	println('With a file path, opens that file. Run without arguments to start an empty buffer.')
}

fn cli_early_exit(args []string) bool {
	if args.len < 2 {
		return false
	}
	match args[1] {
		'-version', '--version' {
			print_vro_version()
			return true
		}
		'-h', '-help', '--help' {
			print_vro_help()
			return true
		}
		else {}
	}

	return false
}

fn main() {
	args := os.args
	if cli_early_exit(args) {
		exit(0)
	}

	mut app := &VroApp{}
	app.editor.quit_times_left = quit_times
	app.editor.hl_disable = os.getenv('NO_COLOR').len > 0 || os.getenv('VRO_NO_HL') == '1'

	if args.len >= 2 {
		editor_open(mut app.editor, args[1]) or {
			editor_set_status_message(mut app.editor, 'Could not open file: ${err.msg()}')
		}
	}

	app.tui = tui.init(
		user_data:            app
		init_fn:              vro_init
		event_fn:             vro_event
		frame_fn:             vro_frame
		window_title:         'vro'
		hide_cursor:          false
		capture_events:       true
		frame_rate:           30
		use_alternate_buffer: true
	)
	app.tui.run() or {
		eprintln(err.msg())
		exit(1)
	}
}
