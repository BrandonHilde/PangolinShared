package pangolin

import "core:math"

// Tool cursors, built from the app's own icons so the pointer says which tool is in hand. The app supplies
// icon_pixels(icon, px, allocator): the icon as white pixels with its coverage in alpha, `px` square.

Tool_Cursor_Kind :: enum {
	Badge, // a small crosshair marks the exact spot, with the tool's icon below and to the right of it
	Tag, // the icon in the same place without the crosshair: for where the canvas marks the spot itself
	Icon, // the icon alone, pointing with `hot`: tools that act on the view, not on a spot (hand, zoom)
}

Tool_Cursor :: struct {
	icon: Icon,
	kind: Tool_Cursor_Kind,
	hot:  [2]f32, // .Icon: the point of the icon's 24 x 24 grid that points
}

@(private = "file")
Built_Cursor :: struct {
	handle: Cursor_Handle,
	px:     i32, // the size it was built for: rebuilt when the UI scale changes
}

@(private = "file")
built_cursors: map[Tool_Cursor]Built_Cursor

// The cursor for this frame, as `ui.cursor = ...` is for the system's: the last one to set a cursor wins.
ui_tool_cursor :: proc(ic: Icon, kind := Tool_Cursor_Kind.Badge, hot := [2]f32{12, 12}) {
	ui.cursor = .TOOL
	ui.tool_cursor = {ic, kind, kind == .Icon ? hot : {}}
}

tool_cursor_apply :: proc(tc: Tool_Cursor) {
	// the size of the system's own cursors, so these sit naturally beside the arrow shown over the panels
	px := max(i32(math.round(16 * gfx_cursor_scale())), 8)
	b, ok := built_cursors[tc]
	if !ok || b.px != px {
		gfx_cursor_destroy(b.handle)
		b = Built_Cursor{tool_cursor_build(tc, f32(px) / 16), px}
		built_cursors[tc] = b
	}
	if b.handle == nil {
		gfx_set_cursor(.CROSSHAIR)
		return
	}
	gfx_cursor_set(b.handle)
}

// White shapes inside a dark outline, so the cursor shows on any artwork.
@(private = "file")
tool_cursor_build :: proc(tc: Tool_Cursor, s: f32) -> Cursor_Handle {
	o := max(int(math.round(s)), 1) // outline width
	t := max(int(math.round(s)), 1) // crosshair line width
	w: int
	hot: [2]int
	isz, ioff: int // the icon's size, and where its top left corner goes
	arm, gap: int
	switch tc.kind {
	case .Badge, .Tag:
		arm = max(int(math.round(5 * s)), 3)
		gap = max(int(math.round(2 * s)), 1)
		c := o + arm + gap // the crosshair's middle block starts here
		hot = {c + t / 2, c + t / 2}
		isz = int(math.round(14 * s))
		ioff = c + t + gap
		w = max(c + t + gap + arm, ioff + isz) + o
	case .Icon:
		isz = int(math.round(20 * s))
		ioff = o
		w = isz + 2 * o
		for i in 0 ..< 2 do hot[i] = clamp(o + int(tc.hot[i] / 24 * f32(isz)), 0, w - 1)
	}
	white := make([]u8, w * w, context.temp_allocator)
	if tc.kind == .Badge {
		c := o + arm + gap
		for i in 0 ..< arm {
			for k in 0 ..< t {
				white[(c + k) * w + o + i] = 255 // left
				white[(c + k) * w + c + t + gap + i] = 255 // right
				white[(o + i) * w + c + k] = 255 // up
				white[(c + t + gap + i) * w + c + k] = 255 // down
			}
		}
	}
	icon := icon_pixels(tc.icon, isz, context.temp_allocator)
	for y in 0 ..< isz {
		for x in 0 ..< isz {
			i := (ioff + y) * w + ioff + x
			white[i] = max(white[i], icon[y * isz + x].a)
		}
	}
	pix := make([]Color, w * w, context.temp_allocator)
	for y in 0 ..< w {
		for x in 0 ..< w {
			// the outline: the white shapes grown by `o` pixels
			dark: u8
			for dy in -o ..= o {
				for dx in -o ..= o {
					xx, yy := x + dx, y + dy
					if xx < 0 || yy < 0 || xx >= w || yy >= w || dx * dx + dy * dy > o * o + 1 do continue
					dark = max(dark, white[yy * w + xx])
				}
			}
			wa := f32(white[y * w + x]) / 255
			da := f32(dark) / 255 * 0.9
			a := wa + da * (1 - wa)
			if a <= 0 do continue
			v := u8(math.round(wa / a * 255))
			pix[y * w + x] = Color{v, v, v, u8(math.round(a * 255))}
		}
	}
	return gfx_cursor_create(pix, w, w, hot.x, hot.y)
}
