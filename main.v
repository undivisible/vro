module main

import os
import term
import strings
import time

#flag linux -D_DEFAULT_SOURCE
#flag darwin -D_DARWIN_C_SOURCE
#include <termios.h>
#include <unistd.h>
#include <time.h>

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
	word_count      int
	words_dirty     bool = true
	quit_times_left int
	orig_termios    C.termios
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
		raw.c_cc[16] = 0
		raw.c_cc[17] = 1
	} $else {
		raw.c_iflag &= ~(C.BRKINT | C.ICRNL | C.INPCK | C.ISTRIP | C.IXON)
		raw.c_oflag &= ~(C.OPOST)
		raw.c_cflag |= C.CS8
		raw.c_lflag &= ~(C.ECHO | C.ICANON | C.IEXTEN | C.ISIG)
		raw.c_cc[C.VMIN] = 0
		raw.c_cc[C.VTIME] = 1
	}

	if C.tcsetattr(0, C.TCSAFLUSH, &raw) == -1 {
		die(mut e, 'tcsetattr failed')
	}
}

fn disable_raw_mode(mut e EditorConfig) {
	_ = C.tcsetattr(0, C.TCSAFLUSH, &e.orig_termios)
}

fn editor_read_key() int {
	mut c := [1]u8{}
	for {
		nread := C.read(0, &c[0], 1)
		if nread == 1 {
			break
		}
		if nread == -1 {
			return -1
		}
	}

	if c[0] == `\x1b` {
		mut seq := [3]u8{}
		if C.read(0, &seq[0], 1) != 1 {
			return int(`\x1b`)
		}
		if C.read(0, &seq[1], 1) != 1 {
			return int(`\x1b`)
		}

		if seq[0] == `[` {
			if seq[1] >= `0` && seq[1] <= `9` {
				if C.read(0, &seq[2], 1) != 1 {
					return int(`\x1b`)
				}
				if seq[2] == `~` {
					match seq[1] {
						`1`, `7` { return key_home }
						`3` { return key_del }
						`4`, `8` { return key_end }
						`5` { return key_page_up }
						`6` { return key_page_down }
						else {}
					}
				}
			} else {
				match seq[1] {
					`A` { return key_arrow_up }
					`B` { return key_arrow_down }
					`C` { return key_arrow_right }
					`D` { return key_arrow_left }
					`H` { return key_home }
					`F` { return key_end }
					else {}
				}
			}
		} else if seq[0] == `O` {
			match seq[1] {
				`H` { return key_home }
				`F` { return key_end }
				else {}
			}
		}
		return int(`\x1b`)
	}

	return int(c[0])
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
}

fn editor_del_row(mut e EditorConfig, at int) {
	if at < 0 || at >= e.rows.len {
		return
	}
	e.rows.delete(at)
	e.dirty++
	e.words_dirty = true
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
	if e.cy == e.rows.len {
		editor_insert_row(mut e, e.rows.len, '')
	}
	mut row := e.rows[e.cy]
	editor_row_insert_char(mut row, e.cx, c)
	e.rows[e.cy] = row
	e.cx++
	e.dirty++
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
	}
	e.dirty++
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

fn editor_open(mut e EditorConfig, filename string) ! {
	e.filename = filename
	content := os.read_file(filename)!
	lines := content.split_into_lines()
	for line in lines {
		editor_insert_row(mut e, e.rows.len, line)
	}
	e.dirty = 0
}

fn editor_open_into_buffer(mut e EditorConfig, filename string) ! {
	content := os.read_file(filename)!
	lines := content.split_into_lines()
	e.rows = []Erow{}
	for line in lines {
		editor_insert_row(mut e, e.rows.len, line)
	}
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
		filename := editor_prompt(mut e, '%s', fn (mut _e EditorConfig, _query string, _key int) {}) or {
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

fn editor_draw_rows(e EditorConfig, mut ab strings.Builder) {
	for y in 0 .. e.screenrows {
		filerow := y + e.rowoff
		if filerow >= e.rows.len {
			// Keep empty rows visually blank like a plain editor.
		} else {
			render := e.rows[filerow].render
			mut len := render.len - e.coloff
			if len < 0 {
				len = 0
			}
			if len > e.screencols {
				len = e.screencols
			}
			if len > 0 {
				ab.write_string(render[e.coloff..e.coloff + len].bytestr())
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

// One bottom line: default background (no reverse video). Command mode: input left, dim metadata right.
fn editor_append_status_line(mut e EditorConfig, mut ab strings.Builder) {
	mut left := ''
	if e.command_mode {
		left = e.command_buffer
	} else if time.now().unix() - e.statusmsg_time < 3 {
		left = e.statusmsg
	}

	mut right := ''
	if e.command_mode {
		filename := if e.filename == '' { '[No Name]' } else { e.filename }
		modified := if e.dirty > 0 { '*' } else { '' }
		total_lines := if e.rows.len == 0 { 1 } else { e.rows.len }
		wc := editor_word_count_get(mut e)
		right = '${filename}${modified} ${wc}w ${e.cy + 1}/${total_lines}'
	}

	mut l := left
	if l.len > e.screencols {
		l = l[..e.screencols]
	}
	ab.write_string(l)
	mut used := l.len
	for used < e.screencols {
		if right.len > 0 && e.screencols - used == right.len {
			ab.write_string('\x1b[90m')
			ab.write_string(right)
			ab.write_string('\x1b[0m')
			break
		}
		ab.write_u8(` `)
		used++
	}
}

fn editor_draw_status_bar(mut e EditorConfig, mut ab strings.Builder) {
	editor_append_status_line(mut e, mut ab)
}

// Fast path: only redraw the bottom overlay line (command bar / status).
fn editor_refresh_bottom_line_only(mut e EditorConfig) {
	mut ab := strings.new_builder(256)
	ab.write_string('\x1b[${e.screenrows + 1};1H\x1b[K')
	editor_append_status_line(mut e, mut ab)
	mut cursor_x := 1
	if e.command_mode {
		cursor_x = e.command_buffer.len + 1
		if cursor_x < 1 {
			cursor_x = 1
		}
		if cursor_x > e.screencols {
			cursor_x = e.screencols
		}
	}
	ab.write_string('\x1b[${e.screenrows + 1};${cursor_x}H\x1b[?25h')
	print(ab.str())
}

fn editor_refresh_screen(mut e EditorConfig) {
	editor_scroll(mut e)

	mut ab := strings.new_builder(4096)
	ab.write_string('\x1b[H')
	editor_draw_rows(e, mut ab)
	editor_draw_status_bar(mut e, mut ab)
	mut cursor_y := (e.cy - e.rowoff) + 1
	mut cursor_x := (e.rx - e.coloff) + 1
	if e.command_mode {
		cursor_y = e.screenrows + 1
		cursor_x = e.command_buffer.len + 1
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
}

fn editor_set_status_message(mut e EditorConfig, msg string) {
	e.statusmsg = msg
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

fn editor_prompt(mut e EditorConfig, prompt string, callback PromptCallback) ?string {
	mut buf := ''
	saved_command_mode := e.command_mode
	saved_command_buffer := e.command_buffer
	e.command_mode = true
	fast_bottom_only := prompt == '%s'
	for {
		e.command_buffer = prompt.replace('%s', buf)
		if fast_bottom_only {
			editor_refresh_bottom_line_only(mut e)
		} else {
			editor_refresh_screen(mut e)
		}

		c := editor_read_key()
		if c == key_del || c == ctrl_key(`h`) || c == int(`\x7f`) {
			if buf.len > 0 {
				buf = buf[..buf.len - 1]
			}
		} else if c == int(`\x1b`) {
			e.command_mode = saved_command_mode
			e.command_buffer = saved_command_buffer
			callback(mut e, buf, c)
			return none
		} else if c == int(`\r`) {
			if buf.len != 0 {
				e.command_mode = saved_command_mode
				e.command_buffer = saved_command_buffer
				callback(mut e, buf, c)
				return buf
			}
		} else if c >= 32 && c <= 126 {
			buf += u8(c).ascii_str()
		}
		callback(mut e, buf, c)
	}
	e.command_mode = saved_command_mode
	e.command_buffer = saved_command_buffer
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
	_ = editor_prompt(mut e, 'Search: %s (Use ESC/Arrows/Enter)', fn [mut state] (mut e EditorConfig, q string, k int) {
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
	input := editor_prompt(mut e, '%s', fn (mut _e EditorConfig, _q string, _k int) {}) or {
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
		'q', 'quit' {
			if e.dirty > 0 {
				editor_set_status_message(mut e, 'Unsaved changes. Use "quit!" to force.')
				return true
			}
			print('\x1b[2J')
			print('\x1b[H')
			return false
		}
		'q!', 'quit!' {
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
			line := args.int()
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
				'Commands: open/o, write/w/save, saveas, find//, goto/g, quit/q, quit!')
		}
		else {
			editor_set_status_message(mut e, 'Unknown command: ${cmd}')
		}
	}

	return true
}

fn editor_process_keypress(mut e EditorConfig) bool {
	c := editor_read_key()
	match c {
		int(`\r`) {
			editor_insert_newline(mut e)
		}
		ctrl_key(`q`) {
			if e.dirty > 0 && e.quit_times_left > 0 {
				editor_set_status_message(mut e,
					'WARNING!!! File has unsaved changes. Press Ctrl-Q ${e.quit_times_left} more times to quit.')
				e.quit_times_left--
				return true
			}
			print('\x1b[2J')
			print('\x1b[H')
			return false
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
		key_home {
			e.cx = 0
		}
		key_end {
			if e.cy < e.rows.len {
				e.cx = e.rows[e.cy].chars.len
			}
		}
		ctrl_key(`l`), int(`\x1b`) {}
		key_page_up, key_page_down {
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
			editor_move_cursor(mut e, c)
		}
		key_del, ctrl_key(`h`), int(`\x7f`) {
			if c == key_del {
				editor_move_cursor(mut e, key_arrow_right)
			}
			editor_del_char(mut e)
		}
		ctrl_key(`u`) {
			for _ in 0 .. 16 {
				editor_del_char(mut e)
			}
		}
		else {
			if c >= 32 && c <= 126 {
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

fn main() {
	mut editor := EditorConfig{}
	enable_raw_mode(mut editor)
	defer {
		disable_raw_mode(mut editor)
	}

	init_editor(mut editor)

	args := os.args
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
