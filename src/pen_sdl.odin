#+build !windows
package pangolin

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Pen input from SDL3's own pen events (X11 and Wayland tablets: Wacom, Huion, ...).
// Run with PANGOLIN_PEN_DEBUG=1 to print every pen event.
// ---------------------------------------------------------------------------

@(private = "file")
pen_debug: bool

pen_win_init :: proc() {
	pen_debug = os.get_env_alloc("PANGOLIN_PEN_DEBUG", context.temp_allocator) != ""
}

// SDL may send the pressure axis before the pen-down event, so keep the last value
@(private = "file")
raw_pressure: f32

@(private = "file")
pen_place :: proc(x, y: f32) {
	pen.pos = Vec2{x, y} * gfx.density
}

@(private = "file")
pen_lift :: proc() {
	if pen.touching do pen.up_evt = true
	pen.touching = false
	pen.pressure = 0
}

// Called from gfx_poll for every SDL event.
pen_handle_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .PEN_PROXIMITY_IN:
		pen.seen, pen.in_range = true, true
		if pen_debug do fmt.println("pen: proximity in")
	case .PEN_PROXIMITY_OUT:
		pen_lift()
		pen.in_range = false
		if pen_debug do fmt.println("pen: proximity out")
	case .PEN_DOWN, .PEN_UP:
		t := e.ptouch
		pen.seen, pen.in_range = true, true
		pen.eraser = t.eraser || .ERASER_TIP in t.pen_state
		pen_place(t.x, t.y)
		if t.down {
			pen.touching, pen.down_evt = true, true
			pen.pressure = raw_pressure
		} else {
			pen_lift()
		}
		if pen_debug do fmt.println("pen: touch down =", t.down, "eraser =", pen.eraser, "at", pen.pos)
	case .PEN_MOTION:
		m := e.pmotion
		pen.seen, pen.in_range = true, true
		pen.eraser = .ERASER_TIP in m.pen_state
		pen_place(m.x, m.y)
	case .PEN_AXIS:
		a := e.paxis
		#partial switch a.axis {
		case .PRESSURE:
			raw_pressure = clamp(a.value, 0, 1)
			pen.pressure = pen.touching ? raw_pressure : 0
		case .XTILT:
			pen.tilt.x = a.value
		case .YTILT:
			pen.tilt.y = a.value
		}
		if pen_debug do fmt.println("pen: axis", a.axis, a.value)
	}
}
