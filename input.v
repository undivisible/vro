module main
// SPDX-License-Identifier: MPL-2.0

#include <unistd.h>

fn C.usleep(u32) int

enum EditorInputKind {
	key_ev
	mouse_ev
}

struct EditorInput {
	kind EditorInputKind
	key  int
	// Terminal cell coordinates (1-based from SGR mouse reports).
	mouse_row int
	mouse_col int
	mouse_btn int
	// true for SGR suffix M (press/drag), false for m (release).
	mouse_press bool
}

fn tty_read_u8() int {
	mut b := [1]u8{}
	for {
		n := C.read(0, &b[0], 1)
		if n == 1 {
			return int(b[0])
		}
		if n == -1 {
			return -1
		}
		C.usleep(1000)
	}
	return -1
}

// True for a normal button press (0–2). Ignores wheel (≥64), motion/drag (≥32), release codes.
fn sgr_mouse_is_plain_press(btn int) bool {
	if btn >= 64 {
		return false
	}
	if btn >= 32 {
		return false
	}
	return btn >= 0 && btn <= 2
}

fn parse_sgr_mouse(body string) ?EditorInput {
	if body.len < 5 {
		return none
	}
	if body[0] != `<` {
		return none
	}
	last := body[body.len - 1]
	if last != `M` && last != `m` {
		return none
	}
	inner := body[1..body.len - 1]
	parts := inner.split(';')
	if parts.len != 3 {
		return none
	}
	btn := parts[0].int()
	col := parts[1].int()
	row := parts[2].int()
	return EditorInput{
		kind:        .mouse_ev
		mouse_row:   row
		mouse_col:   col
		mouse_btn:   btn
		mouse_press: last == `M`
	}
}

fn parse_csi_body(body string) EditorInput {
	if body.len >= 2 && body[0] == `<` && (body[body.len - 1] == `M` || body[body.len - 1] == `m`) {
		if m := parse_sgr_mouse(body) {
			return m
		}
	}
	if body.len == 1 {
		match body[0] {
			`A` { return EditorInput{ kind: .key_ev, key: key_arrow_up } }
			`B` { return EditorInput{ kind: .key_ev, key: key_arrow_down } }
			`C` { return EditorInput{ kind: .key_ev, key: key_arrow_right } }
			`D` { return EditorInput{ kind: .key_ev, key: key_arrow_left } }
			`H` { return EditorInput{ kind: .key_ev, key: key_home } }
			`F` { return EditorInput{ kind: .key_ev, key: key_end } }
			else {}
		}
	}
	if body == '1~' || body == '7~' {
		return EditorInput{ kind: .key_ev, key: key_home }
	}
	if body == '3~' {
		return EditorInput{ kind: .key_ev, key: key_del }
	}
	if body == '4~' || body == '8~' {
		return EditorInput{ kind: .key_ev, key: key_end }
	}
	if body == '5~' {
		return EditorInput{ kind: .key_ev, key: key_page_up }
	}
	if body == '6~' {
		return EditorInput{ kind: .key_ev, key: key_page_down }
	}
	return EditorInput{ kind: .key_ev, key: int(`\x1b`) }
}

fn editor_read_input() EditorInput {
	b := tty_read_u8()
	if b < 0 {
		return EditorInput{ kind: .key_ev, key: -1 }
	}
	if b != 0x1b {
		return EditorInput{ kind: .key_ev, key: b }
	}
	b2 := tty_read_u8()
	if b2 < 0 {
		return EditorInput{ kind: .key_ev, key: int(`\x1b`) }
	}
	if b2 == `[` {
		mut body := ''
		for {
			c := tty_read_u8()
			if c < 0 {
				return EditorInput{ kind: .key_ev, key: int(`\x1b`) }
			}
			body += u8(c).ascii_str()
			if c >= 0x40 && c <= 0x7e {
				break
			}
		}
		return parse_csi_body(body)
	}
	if b2 == `O` {
		c := tty_read_u8()
		if c < 0 {
			return EditorInput{ kind: .key_ev, key: int(`\x1b`) }
		}
		cc := u8(c)
		if cc == `H` {
			return EditorInput{ kind: .key_ev, key: key_home }
		}
		if cc == `F` {
			return EditorInput{ kind: .key_ev, key: key_end }
		}
		return EditorInput{ kind: .key_ev, key: int(`\x1b`) }
	}
	return EditorInput{.key_ev, int(`\x1b`), 0, 0, 0, false}
}

fn editor_read_key() int {
	inp := editor_read_input()
	if inp.kind == .mouse_ev {
		return int(`\x1b`)
	}
	return inp.key
}

fn term_mouse_enable() {
	// 1002 (cell motion) floods events and broke quit countdown; 1000+1006 is enough for clicks.
	print('\x1b[?1000h\x1b[?1006h')
}

fn term_mouse_disable() {
	print('\x1b[?1006l\x1b[?1000l')
}
