package pangolin


// ---------------------------------------------------------------------------
// Graphics tablet / pen input
//
// SDL reports the pen as a mouse here, so on Windows the window procedure is
// hooked to read the WM_POINTER messages (Windows Ink: Wacom, Huion, Surface, ...)
// that carry pressure, tilt and the eraser end. SDL's own window procedure still runs
// afterwards, so its mouse handling keeps working. Elsewhere (Linux) pen_sdl.odin
// fills the same struct from SDL's native pen events.
// ---------------------------------------------------------------------------

Pen :: struct {
	seen:     bool, // a pen has been used at least once
	in_range: bool, // pen is hovering or touching
	touching: bool,
	eraser:   bool, // the eraser end is in use
	pressure: f32, // 0..1
	tilt:     Vec2, // degrees, -90..90
	pos:      Vec2, // window client pixels, valid while touching
	// edges since the last frame (Windows delays the synthesised mouse-down of a pen)
	down_evt: bool,
	up_evt:   bool,
}

pen: Pen

// The pen is driving the mouse right now (hovering over, or touching, the tablet).
pen_active :: proc() -> bool {
	return pen.in_range
}

pen_init :: proc() {
	pen_win_init()
}

// Whether the eraser end should turn the paint brushes into the eraser.
pen_eraser_active :: proc() -> bool {
	return pen.in_range && pen.eraser
}

pen_status :: proc() -> string {
	if !pen.seen {
		return ""
	}
	return pen.in_range ? "Pen" : "Pen (out of range)"
}

