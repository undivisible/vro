module main
// SPDX-License-Identifier: MPL-2.0

import os
import term
import strings
import time

#flag linux -D_DEFAULT_SOURCE
#flag darwin -D_DARWIN_C_SOURCE
#include <termios.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>

const vro_version = '0.3.2'

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

fn ctrl_key(c u8) int {
	return int(c & 0x1f)
}

fn tty_flush() {
	unsafe {
		C.fflush(C.stdout)
	}
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
	cx              int
	cy              int
	rx              int
	rowoff          int
	coloff          int
	screenrows      int
	screencols      int
	rows            []Erow
	dirty           int
	filename        string
	statusmsg       string
	statusmsg_time  i64
	command_mode    bool
	command_buffer  string
	// Byte offset in command_buffer where the caret sits (prompt + cmd text); command_mode only.
	cmd_caret_bytes int
	// Sanitized command/status text trimmed by this many bytes so metadata fits on the right.
	cmd_line_left_skip int
	word_count      int
	words_dirty     bool = true
	quit_times_left int
	orig_termios    C.termios
	// syntax highlighting (YAML; see syntax/)
	hl_syn          CompiledSyntax
	hl_cache_path   string
	hl_disable      bool
	// Per-line region carry entering each row (multiline /* */, raw strings, …).
	hl_carry_enter     [][]bool
	hl_carry_lines     int
	hl_carry_rules     int
	hl_carry_valid     bool
	hl_carry_dirty_from int = -1 // >=0: suffix rebuild from this row (same row count as cache)
	// buffer word completion (Ctrl-N)
	complete_active   bool
	complete_prefix   string
	complete_matches  []string
	complete_idx      int
	complete_start_cx int
}

fn die(mut e EditorConfig, message string) {
	disable_raw_mode(mut e)
	eprintln(message)
	exit(1)
}

fn enable_raw_mode(mut e EditorConfig) {
	if C.tcgetattr(0, &e.orig_termios) == -1 {
		die(mut e, 'tcgetattr failed')
	}

	mut raw := e.orig_termios
	// macOS: V's C interop often leaves termios flag macros unusable; use XNU masks.
	// Linux: keep libc macros (glibc tcflag_t).
	$if macos {
		// XNU termios masks; V maps tcflag_t fields as int on Darwin.
		iflag_clr := 0x00000002 | 0x00000100 | 0x00000010 | 0x00000020 | 0x00000200
		oflag_clr := 0x00000001
		cflag_set := 0x00000300
		lflag_clr := 0x00000008 | 0x00000100 | 0x00000400 | 0x00000080
		raw.c_iflag &= ~iflag_clr
		raw.c_oflag &= ~oflag_clr
		raw.c_cflag |= cflag_set
		raw.c_lflag &= ~lflag_clr
		// Darwin: VMIN=16, VTIME=17 — block until one byte (no idle read()→0 spin).
		raw.c_cc[16] = 1
		raw.c_cc[17] = 0
	} $else {
		raw.c_iflag &= ~(C.BRKINT | C.ICRNL | C.INPCK | C.ISTRIP | C.IXON)
		raw.c_oflag &= ~(C.OPOST)
		raw.c_cflag |= C.CS8
		raw.c_lflag &= ~(C.ECHO | C.ICANON | C.IEXTEN | C.ISIG)
		raw.c_cc[C.VMIN] = 1
		raw.c_cc[C.VTIME] = 0
	}

	if C.tcsetattr(0, C.TCSAFLUSH, &raw) == -1 {
		die(mut e, 'tcsetattr failed')
	}
}

fn disable_raw_mode(mut e EditorConfig) {
	_ = C.tcsetattr(0, C.TCSAFLUSH, &e.orig_termios)
}

fn get_cursor_position() !(int, int) {
	mut buf := []u8{len: 32, init: 0}
	print('\x1b[6n')
	mut i := 0
	for i < buf.len - 1 {
		mut c := [1]u8{}
		if C.read(0, &c[0], 1) != 1 {
			break
		}
		buf[i] = c[0]
		if c[0] == `R` {
			break
		}
		i++
	}
	buf = buf[..i + 1].clone()
	if buf.len < 2 || buf[0] != `\x1b` || buf[1] != `[` {
		return error('failed cursor response')
	}
	mut row := 0
	mut col := 0
	mut j := 2
	for j < buf.len && buf[j] >= `0` && buf[j] <= `9` {
		row = row * 10 + int(buf[j] - `0`)
		j++
	}
	if j >= buf.len || buf[j] != `;` {
		return error('invalid cursor response')
	}
	j++
	for j < buf.len && buf[j] >= `0` && buf[j] <= `9` {
		col = col * 10 + int(buf[j] - `0`)
		j++
	}
	if row == 0 || col == 0 {
		return error('invalid cursor position')
	}
	return row, col
}

fn get_window_size() !(int, int) {
	cols, rows := term.get_terminal_size()
	if cols <= 0 || rows <= 0 {
		print('\x1b[999C\x1b[999B')
		row, col := get_cursor_position()!
		return row, col
	}
	return rows, cols
}

fn editor_row_cx_to_rx(row Erow, cx int) int {
	mut rx := 0
	for i in 0 .. cx {
		if i >= row.chars.len {
			break
		}
		if row.chars[i] == `\t` {
			rx += (tab_stop - 1) - (rx % tab_stop)
		}
		rx++
	}
	return rx
}

fn editor_row_rx_to_cx(row Erow, rx int) int {
	mut cur_rx := 0
	for cx in 0 .. row.chars.len {
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
		chars: s.bytes()
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
	return sb.str()
}

fn editor_load_buffer_lines(mut e EditorConfig, lines []string) {
	e.rows = []Erow{}
	for line in lines {
		mut row := Erow{
			chars: line.bytes()
			render: []u8{}
		}
		editor_update_row(mut row)
		e.rows << row
	}
	e.words_dirty = true
	editor_hl_carry_invalidate(mut e)
}

fn editor_open(mut e EditorConfig, filename string) ! {
	e.hl_cache_path = ''
	e.filename = filename
	content := os.read_file(filename)!
	editor_load_buffer_lines(mut e, content.split_into_lines())
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
	editor_load_buffer_lines(mut e, content.split_into_lines())
	e.filename = filename
	e.cx = 0
	e.cy = 0
	e.rx = 0
	e.rowoff = 0
	e.coloff = 0
	e.dirty = 0
}

fn editor_save(mut e EditorConfig) {
	if e.filename == '' {
		filename := editor_prompt(mut e, '> %s', true, fn (mut _e EditorConfig, _query string, _key int) {}) or {
			editor_set_status_message(mut e, '')
			return
		}
		e.filename = filename
	}

	data := editor_rows_to_string(e)
	os.write_file(e.filename, data) or {
		editor_set_status_message(mut e, 'Cannot save! I/O error')
		return
	}
	e.dirty = 0
	e.quit_times_left = quit_times
	editor_set_status_message(mut e, '${data.len} bytes written to disk')
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

	if e.hl_carry_valid && e.hl_carry_dirty_from >= 0 && e.hl_carry_lines == e.rows.len && e.hl_carry_rules == rl
		&& e.hl_carry_enter.len == e.rows.len && e.hl_carry_dirty_from < e.rows.len {
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

	if e.hl_carry_valid && e.hl_carry_dirty_from < 0 && e.hl_carry_lines == e.rows.len && e.hl_carry_rules == rl {
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
	if e.rx >= e.coloff + e.screencols {
		e.coloff = e.rx - e.screencols + 1
	}
}

fn editor_draw_rows(mut e EditorConfig, mut ab strings.Builder) {
	editor_ensure_syntax(mut e)
	editor_ensure_hl_carry(mut e)
	for y in 0 .. e.screenrows {
		filerow := y + e.rowoff
		if filerow >= e.rows.len {
			// Keep empty rows visually blank like a plain editor.
		} else {
			render := e.rows[filerow].render.bytestr()
			mut len := render.len - e.coloff
			if len < 0 {
				len = 0
			}
			if len > e.screencols {
				len = e.screencols
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

// Fast path: only redraw the bottom overlay line (command bar / status).
fn editor_refresh_bottom_line_only(mut e EditorConfig) {
	mut ab := strings.new_builder(256)
	ab.write_string('\x1b[${e.screenrows + 1};1H\x1b[K')
	editor_append_status_line(mut e, mut ab)
	cursor_x := editor_footer_caret_column(mut e)
	ab.write_string('\x1b[${e.screenrows + 1};${cursor_x}H\x1b[?25h')
	print(ab.str())
	tty_flush()
}

fn editor_refresh_screen(mut e EditorConfig) {
	editor_scroll(mut e)

	mut ab := strings.new_builder(4096)
	ab.write_string('\x1b[H')
	editor_draw_rows(mut e, mut ab)
	editor_draw_status_bar(mut e, mut ab)
	mut cursor_y := (e.cy - e.rowoff) + 1
	mut cursor_x := (e.rx - e.coloff) + 1
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

	print(ab.str())
	tty_flush()
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

type PromptCallback = fn (mut EditorConfig, string, int)

fn editor_prompt(mut e EditorConfig, prompt string, bottom_only bool, callback PromptCallback) ?string {
	mut buf := ''
	mut cmd_cx := 0
	pct := prompt.index('%s') or { prompt.len }
	prefix_len := pct
	saved_command_mode := e.command_mode
	saved_command_buffer := e.command_buffer
	e.command_mode = true
	for {
		e.command_buffer = prompt.replace('%s', buf)
		e.cmd_caret_bytes = prefix_len + cmd_cx
		if bottom_only {
			editor_refresh_bottom_line_only(mut e)
		} else {
			editor_refresh_screen(mut e)
		}

		inp := editor_read_input()
		if inp.kind == .mouse_ev {
			continue
		}
		c := inp.key

		if !bottom_only {
			if c == key_arrow_left || c == key_arrow_right || c == key_arrow_up || c == key_arrow_down {
				callback(mut e, buf, c)
				continue
			}
			if c == key_del || c == ctrl_key(`h`) || c == int(`\x7f`) {
				if buf.len > 0 {
					buf = buf[..buf.len - 1]
				}
				cmd_cx = buf.len
				callback(mut e, buf, c)
				continue
			}
			if c == int(`\x1b`) {
				e.command_mode = saved_command_mode
				e.command_buffer = saved_command_buffer
				e.cmd_caret_bytes = 0
				callback(mut e, buf, c)
				return none
			}
			if c == int(`\r`) {
				if buf.len != 0 {
					e.command_mode = saved_command_mode
					e.command_buffer = saved_command_buffer
					e.cmd_caret_bytes = 0
					callback(mut e, buf, c)
					return buf
				}
			}
			if c >= 32 && c <= 126 {
				buf += u8(c).ascii_str()
				cmd_cx = buf.len
			}
			callback(mut e, buf, c)
			continue
		}

		if c == key_arrow_left {
			if cmd_cx > 0 {
				cmd_cx--
			}
			callback(mut e, buf, c)
			continue
		}
		if c == key_arrow_right {
			if cmd_cx < buf.len {
				cmd_cx++
			}
			callback(mut e, buf, c)
			continue
		}
		if c == key_home {
			cmd_cx = 0
			callback(mut e, buf, c)
			continue
		}
		if c == key_end {
			cmd_cx = buf.len
			callback(mut e, buf, c)
			continue
		}
		if c == key_del {
			if cmd_cx < buf.len {
				buf = buf[..cmd_cx] + buf[cmd_cx + 1..]
			}
			callback(mut e, buf, c)
			continue
		}
		if c == ctrl_key(`h`) || c == int(`\x7f`) {
			if cmd_cx > 0 {
				buf = buf[..cmd_cx - 1] + buf[cmd_cx..]
				cmd_cx--
			}
			callback(mut e, buf, c)
			continue
		}
		if c == int(`\x1b`) {
			e.command_mode = saved_command_mode
			e.command_buffer = saved_command_buffer
			e.cmd_caret_bytes = 0
			callback(mut e, buf, c)
			return none
		}
		if c == int(`\r`) {
			if buf.len != 0 {
				e.command_mode = saved_command_mode
				e.command_buffer = saved_command_buffer
				e.cmd_caret_bytes = 0
				callback(mut e, buf, c)
				return buf
			}
		}
		if c >= 32 && c <= 126 {
			ch := u8(c).ascii_str()
			buf = buf[..cmd_cx] + ch + buf[cmd_cx..]
			cmd_cx++
		}
		callback(mut e, buf, c)
	}
	return none
}

struct FindState {
mut:
	last_match int = -1
	direction  int = 1
}

fn editor_find_callback(mut e EditorConfig, mut state FindState, query string, key int) {
	if key == int(`\r`) || key == int(`\x1b`) {
		state.last_match = -1
		state.direction = 1
		return
	} else if key == key_arrow_right || key == key_arrow_down {
		state.direction = 1
	} else if key == key_arrow_left || key == key_arrow_up {
		state.direction = -1
	} else {
		state.last_match = -1
		state.direction = 1
	}

	if state.last_match == -1 {
		state.direction = 1
	}
	mut current := state.last_match
	for _ in 0 .. e.rows.len {
		current += state.direction
		if current == -1 {
			current = e.rows.len - 1
		} else if current == e.rows.len {
			current = 0
		}

		row := e.rows[current]
		idx := row.render.bytestr().index(query) or { -1 }
		if idx != -1 {
			state.last_match = current
			e.cy = current
			e.cx = editor_row_rx_to_cx(row, idx)
			e.rowoff = e.rows.len
			break
		}
	}
}

fn editor_find(mut e EditorConfig) {
	saved_cx := e.cx
	saved_cy := e.cy
	saved_coloff := e.coloff
	saved_rowoff := e.rowoff

	mut state := FindState{}
	_ = editor_prompt(mut e, 'Search: %s (Use ESC/Arrows/Enter)', false, fn [mut state] (mut e EditorConfig, q string, k int) {
		editor_find_callback(mut e, mut state, q, k)
	}) or {
		e.cx = saved_cx
		e.cy = saved_cy
		e.coloff = saved_coloff
		e.rowoff = saved_rowoff
		return
	}
}

fn editor_command_bar(mut e EditorConfig) bool {
	input := editor_prompt(mut e, ': %s', true, fn (mut _e EditorConfig, _q string, _k int) {}) or {
		editor_set_status_message(mut e, '')
		return true
	}
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
			if args.len > 0 {
				e.filename = args
			}
			editor_save(mut e)
			if e.dirty > 0 {
				return true
			}
			print('\x1b[2J')
			print('\x1b[H')
			return false
		}
		'w', 'write', 'save' {
			if args.len > 0 {
				e.filename = args
			}
			editor_save(mut e)
		}
		'saveas' {
			if args.len == 0 {
				editor_set_status_message(mut e, 'Usage: saveas <path>')
				return true
			}
			e.filename = args
			editor_save(mut e)
		}
		'open', 'o' {
			if args.len == 0 {
				editor_set_status_message(mut e, 'Usage: open <path>')
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
				'open/o w/wq write/save saveas find goto/g quit/exit/x quit! help')
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
		'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr' {
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
		is_ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `-`
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
		print('\x1b[2J')
		print('\x1b[H')
		return false
	}
	e.quit_times_left--
	if e.quit_times_left > 0 {
		plural := if e.quit_times_left == 1 { '' } else { 's' }
		editor_set_status_message(mut e,
			'Unsaved (${e.quit_times_left} more Ctrl-Q press${plural} forces quit)')
		return true
	}
	print('\x1b[2J')
	print('\x1b[H')
	return false
}

fn editor_process_keypress(mut e EditorConfig) bool {
	inp := editor_read_input()
	if inp.kind == .mouse_ev {
		if !inp.mouse_press {
			return true
		}
		if !sgr_mouse_is_plain_press(inp.mouse_btn) {
			return true
		}
		editor_click_from_mouse(mut e, inp.mouse_row, inp.mouse_col)
		return true
	}
	c := inp.key
	if c == ctrl_key(`q`) {
		return editor_handle_ctrl_q(mut e)
	}
	match c {
		int(`\r`) {
			editor_complete_reset(mut e)
			editor_insert_newline(mut e)
		}
		ctrl_key(`s`) {
			editor_save(mut e)
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
				editor_move_cursor(mut e, if c == key_page_up { key_arrow_up } else { key_arrow_down })
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
			if c >= 32 && c <= 126 {
				editor_complete_reset(mut e)
				editor_insert_char(mut e, u8(c))
			}
		}
	}
	e.quit_times_left = quit_times
	return true
}

fn init_editor(mut e EditorConfig) {
	rows, cols := get_window_size() or {
		die(mut e, 'Unable to query terminal size')
		return
	}
	e.screenrows = rows - 1
	e.screencols = cols
	e.quit_times_left = quit_times
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

	mut editor := EditorConfig{}
	enable_raw_mode(mut editor)
	mouse_on := os.getenv('VRO_NO_MOUSE').len == 0
	if mouse_on {
		term_mouse_enable()
	}
	defer {
		if mouse_on {
			term_mouse_disable()
		}
		disable_raw_mode(mut editor)
	}

	init_editor(mut editor)
	editor.hl_disable = os.getenv('NO_COLOR').len > 0 || os.getenv('VRO_NO_HL') == '1'

	if args.len >= 2 {
		editor_open(mut editor, args[1]) or {
			editor_set_status_message(mut editor, 'Could not open file: ${err.msg()}')
		}
	}

	editor_refresh_screen(mut editor)
	for {
		if !editor_process_keypress(mut editor) {
			break
		}
		editor_refresh_screen(mut editor)
	}
}
