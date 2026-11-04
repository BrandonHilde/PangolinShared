package pangolin

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

FONT_SIZE :: 14 // logical em size of the UI font (Jersey 10)
FONT_CAP :: 8 // height of its capital letters, logical px

// Theme ----------------------------------------------------------------------
// Neutral charcoal surfaces in three steps (well < panel < raised control), a warm amber accent
// taken from the pangolin logo, and hairline rings instead of heavy black outlines.
// These are the defaults; the theme's custom properties replace them (theme_apply_palette).
C_BG := Color{21, 22, 26, 255} // window and gutters
C_PANEL := Color{35, 37, 43, 255} // docked panels
C_PANEL_DK := Color{26, 27, 32, 255} // wells: inputs, lists, bars
C_PANEL_LT := Color{52, 55, 64, 255} // raised controls
C_BORDER := Color{13, 14, 17, 255} // separators and outer edges
C_RING := Color{255, 255, 255, 18} // hairline ring around controls
C_RING_HI := Color{255, 255, 255, 40}
C_HOVER := Color{68, 72, 85, 255}
C_ACTIVE := Color{178, 100, 56, 255} // selected rows, pressed
C_ACCENT := Color{246, 170, 104, 255}
C_ACCENT_TINT := Color{246, 170, 104, 52} // toggled-on fill
C_TEXT := Color{229, 231, 237, 255}
C_TEXT_DIM := Color{140, 145, 160, 255}
C_TEXT_OFF := Color{88, 92, 106, 255}
C_VIEWPORT := Color{45, 47, 53, 255}
C_DANGER := Color{230, 98, 98, 255}

RADIUS: f32 = 3

// A palette colour with another alpha.
with_alpha :: proc(c: Color, a: u8) -> Color {
	return {c.r, c.g, c.b, a}
}

// A palette colour lightened (k > 1) or darkened (k < 1).
shade :: proc(c: Color, k: f32) -> Color {
	return {u8(clamp(f32(c.r) * k, 0, 255)), u8(clamp(f32(c.g) * k, 0, 255)), u8(clamp(f32(c.b) * k, 0, 255)), c.a}
}

UI :: struct {
	w, h:                int, // logical window size
	scale:               f32, // physical pixels per logical pixel
	mx, my:              i32,
	pmx, pmy:            i32,
	ptr:                 Vec2, // pointer in window pixels at full precision (the pen tip while the pen drives)
	down, pressed, released: [3]bool,
	wheel:               f32,
	wheel_h:             f32,
	active_id:           u32,
	focus_id:            u32,
	hover_id:            u32,
	hover_t:             f32,
	hover_seen:          bool,
	hover_next_id:       u32, // what was hovered this frame: the last control to ask wins
	hover_next_tip:      Tip,
	layer, input_layer:  int,
	chars:               [dynamic]rune,
	dt:                  f32,
	time:                f64,
	tip:                 Tip,
	tip_desc:            bool, // the pointer has stayed long enough for the description
	cursor:              MouseCursor,

	caret:               int,
	sel_all:             bool,
	edit:                Name,
	popup_result_id:     u32,
	popup_result_val:    int,
	last_click_t:        f64,
	last_click_x,
	last_click_y:        i32,
	last_click_id:       u32,
	dbl_click:           bool,
	ctrl, shift, alt:    bool,
	hide_cursor:         bool,
}

ui: UI

in_rect :: proc(r: Rect, x, y: i32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

rect_inset :: proc(r: Rect, n: i32) -> Rect {
	return Rect{r.x + n, r.y + n, max(r.w - 2 * n, 0), max(r.h - 2 * n, 0)}
}

cut_left :: proc(r: ^Rect, w: i32) -> Rect {
	out := Rect{r.x, r.y, min(w, r.w), r.h}
	r.x += out.w
	r.w -= out.w
	return out
}

cut_right :: proc(r: ^Rect, w: i32) -> Rect {
	ww := min(w, r.w)
	out := Rect{r.x + r.w - ww, r.y, ww, r.h}
	r.w -= ww
	return out
}

cut_top :: proc(r: ^Rect, h: i32) -> Rect {
	out := Rect{r.x, r.y, r.w, min(h, r.h)}
	r.y += out.h
	r.h -= out.h
	return out
}

cut_bottom :: proc(r: ^Rect, h: i32) -> Rect {
	hh := min(h, r.h)
	out := Rect{r.x, r.y + r.h - hh, r.w, hh}
	r.h -= hh
	return out
}

// Drawing helpers --------------------------------------------------------------

fill_rect :: proc(r: Rect, c: Color) {
	draw_rect(f32(r.x), f32(r.y), f32(r.w), f32(r.h), c)
}

// One physical pixel wide border just inside `r`.
outline_rect :: proc(r: Rect, c: Color) {
	x, y, w, h := f32(r.x), f32(r.y), f32(r.w), f32(r.h)
	t := hair()
	draw_rect(x, y, w, t, c)
	draw_rect(x, y + h - t, w, t, c)
	draw_rect(x, y + t, t, h - 2 * t, c)
	draw_rect(x + w - t, y + t, t, h - 2 * t, c)
}

hline :: proc(x, y, w: i32, c: Color) {
	draw_rect(f32(x), f32(y), f32(w), hair(), c)
}

vline :: proc(x, y, h: i32, c: Color) {
	draw_rect(f32(x), f32(y), hair(), f32(h), c)
}

text :: proc(x, y: i32, s: string, c: Color) {
	draw_text(f32(x), f32(y), s, c)
}

text_w :: proc(s: string) -> i32 {
	return i32(math.ceil(text_width(s)))
}

textf :: proc(x, y: i32, c: Color, format: string, args: ..any) {
	text(x, y, fmt.tprintf(format, ..args), c)
}

text_centered :: proc(r: Rect, s: string, c: Color) {
	tw := text_w(s)
	text(r.x + (r.w - tw) / 2, r.y + (r.h - FONT_CAP) / 2, s, c)
}

text_clipped :: proc(r: Rect, s: string, c: Color) {
	clip_begin(r)
	text(r.x, r.y + (r.h - FONT_CAP) / 2, s, c)
	clip_end()
}

// Nested clips intersect, as scissor modes never did.
clip_stack: [8]Rect
clip_depth: int

clip_begin :: proc(r: Rect) {
	n := r
	if clip_depth > 0 {
		p := clip_stack[clip_depth - 1]
		x0, y0 := max(n.x, p.x), max(n.y, p.y)
		x1, y1 := min(n.x + n.w, p.x + p.w), min(n.y + n.h, p.y + p.h)
		n = Rect{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
	}
	if clip_depth < len(clip_stack) {
		clip_stack[clip_depth] = n
	}
	clip_depth += 1
	clip_set(n.x, n.y, n.w, n.h)
}

clip_end :: proc() {
	clip_depth -= 1
	if clip_depth > 0 && clip_depth <= len(clip_stack) {
		p := clip_stack[clip_depth - 1]
		clip_set(p.x, p.y, p.w, p.h)
	} else {
		clip_clear()
	}
}

icon :: proc(ic: Icon, x, y: i32, c: Color, size: i32 = ICON_SIZE) {
	tex, px := icon_atlas(size)
	// one atlas pixel to one screen pixel, whatever the scale
	ls := f32(px) / gfx.scale
	draw_tex(tex, {f32(int(ic) * int(px)), 0, f32(px), f32(px)}, {f32(x), f32(y), ls, ls}, c)
}

icon_centered :: proc(ic: Icon, r: Rect, c: Color, size: i32 = ICON_SIZE) {
	icon(ic, r.x + (r.w - size) / 2, r.y + (r.h - size) / 2, c, size)
}

// Buttons with room for them (tool buttons) get the large icons.
icon_fit :: proc(r: Rect) -> i32 {
	return min(r.w, r.h) >= 22 ? ICON_SIZE_LG : ICON_SIZE
}

// Frame / input ------------------------------------------------------------------

PEN_MOUSE_GRACE :: 0.25 // seconds: Windows' synthesised mouse events trail the pen by a moment

@(private = "file")
pen_drives_ptr: bool // the pen, not the mouse, is the pointer this frame
@(private = "file")
pen_contact_t: f64 // gfx_time() of the last frame the pen touched or lifted

// The pen owns the pointer while it hovers or touches, including the frame it lifts on, so a
// stroke ends where the pen did. A mouse button press hands the pointer to the mouse until it is up.
ui_pick_pointer :: proc() {
	mouse_pressed := gfx.m_pressed[0] || gfx.m_pressed[1] || gfx.m_pressed[2]
	mouse_held := gfx.m_down[0] || gfx.m_down[1] || gfx.m_down[2]
	mouse_released := gfx.m_released[0] || gfx.m_released[1] || gfx.m_released[2]
	switch {
	case pen.down_evt || pen.touching || pen.up_evt:
		pen_drives_ptr = true
		pen_contact_t = gfx_time()
	case gfx_time() - pen_contact_t < PEN_MOUSE_GRACE:
		// keep the current owner while the pen's synthesised mouse press is still on its way
	case mouse_pressed:
		pen_drives_ptr = false
	case pen.in_range:
		// hovering: the pen takes over again once the mouse button is up
		if !mouse_held && !mouse_released do pen_drives_ptr = true
	case:
		pen_drives_ptr = false
	}
}

ui_begin_frame :: proc() {
	ui_pick_pointer()
	m := gfx.mouse
	pen_tip := pen.touching || pen.down_evt
	if pen_drives_ptr {
		m = pen.pos
	}
	ui.ptr = m
	ui.pmx, ui.pmy = ui.mx, ui.my
	ui.mx = i32(m.x / ui.scale)
	ui.my = i32(m.y / ui.scale)
	for i in 0 ..< 3 {
		ui.down[i] = gfx.m_down[i]
		ui.pressed[i] = gfx.m_pressed[i]
		ui.released[i] = gfx.m_released[i]
	}
	if pen_drives_ptr {
		// the pen tip is the left button: read straight from the pen, the synthesised mouse events arrive late
		ui.down[0] = pen_tip
		ui.pressed[0] = pen.down_evt
		ui.released[0] = pen.up_evt
	}
	pen.down_evt, pen.up_evt = false, false
	ui.wheel = gfx.wheel.y
	ui.wheel_h = gfx.wheel.x
	clear(&ui.chars)
	append(&ui.chars, ..gfx.chars[:])
	ui.dt = gfx.dt
	ui.time = gfx_time()
	ui.cursor = .DEFAULT
	ui.hide_cursor = false
	ui.tip, ui.tip_desc = {}, false
	ui.hover_seen = false
	ui.ctrl = IsKeyDown(.LEFT_CONTROL) || IsKeyDown(.RIGHT_CONTROL)
	ui.shift = IsKeyDown(.LEFT_SHIFT) || IsKeyDown(.RIGHT_SHIFT)
	ui.alt = IsKeyDown(.LEFT_ALT) || IsKeyDown(.RIGHT_ALT)
	ui.dbl_click = false
	if ui.pressed[0] {
		// two quick clicks in different places are two clicks, not a double click
		if ui.time - ui.last_click_t < 0.35 && max(abs(ui.mx - ui.last_click_x), abs(ui.my - ui.last_click_y)) < 5 {
			ui.dbl_click = true
		}
		ui.last_click_t = ui.time
		ui.last_click_x, ui.last_click_y = ui.mx, ui.my
	}
	ui.layer = 0
}

ui_end_frame :: proc() {
	if ui.hover_seen {
		ui.hover_t += ui.dt
	} else {
		ui.hover_id = 0
		ui.hover_t = 0
	}
	if !ui.down[0] && !ui.down[1] {
		ui.active_id = 0
	}
	gfx_set_cursor(ui.cursor)
	@(static) hidden: bool
	if ui.hide_cursor != hidden {
		hidden = ui.hide_cursor
		if hidden {
			gfx_show_cursor(false)
		} else {
			gfx_show_cursor(true)
		}
	}
}

make_id :: proc(r: Rect, s: string) -> u32 {
	h: u32 = 2166136261
	for i in 0 ..< len(s) {
		h = (h ~ u32(s[i])) * 16777619
	}
	h = (h ~ u32(r.x)) * 16777619
	h = (h ~ u32(r.y)) * 16777619
	h = (h ~ u32(ui.layer)) * 16777619
	return h | 1
}

ui_hover :: proc(r: Rect) -> bool {
	return ui.layer == ui.input_layer && in_rect(r, ui.mx, ui.my)
}

// What a tooltip says. The title shows first, and the description joins it under the title if the pointer stays.
// A control whose own text would repeat the title has none: its tooltip is just the description.
Tip :: struct {
	title, desc: string,
}

// Drops a title that only repeats the text on the control.
tip_for_label :: proc(tip: Tip, label: string) -> Tip {
	if strings.equal_fold(tip.title, strings.trim_suffix(label, "...")) do return {"", tip.desc}
	return tip
}

TIP_TITLE_DELAY :: 0.45
TIP_DESC_DELAY :: 1.2

// The control under the pointer offers its tooltip. A control inside another asks after it and wins.
tooltip_hover :: proc(id: u32, tip: Tip) {
	ui.hover_seen = true
	ui.hover_next_id, ui.hover_next_tip = id, tip
}

// Decides what to show this frame: the longer the pointer stays on a control, the more of its tooltip appears.
tooltip_resolve :: proc() {
	if !ui.hover_seen do return
	if ui.hover_next_id != ui.hover_id {
		ui.hover_id = ui.hover_next_id
		ui.hover_t = 0
	} else if ui.hover_t > TIP_TITLE_DELAY {
		ui.tip = ui.hover_next_tip
		ui.tip_desc = ui.hover_t > TIP_DESC_DELAY
	}
}

// Text that explains itself when the pointer rests on it.
tip_text :: proc(x, y: i32, s: string, c: Color, tip: Tip) {
	text(x, y, s, c)
	r := Rect{x, y - 2, text_w(s), FONT_CAP + 4}
	if ui_hover(r) do tooltip_hover(make_id(r, s), tip)
}

// A tooltip for a hand-drawn area that is not a control.
tip_area :: proc(r: Rect, key: string, tip: Tip) {
	if ui_hover(r) do tooltip_hover(make_id(r, key), tip)
}

key_hit :: proc(k: KeyboardKey) -> bool {
	return IsKeyPressed(k) || IsKeyPressedRepeat(k)
}

// Generic press/hold/click behaviour.
button_behavior :: proc(id: u32, r: Rect, tip: Tip) -> (clicked, held, hover: bool) {
	hover = ui_hover(r)
	if hover {
		tooltip_hover(id, tip)
		if ui.pressed[0] {
			ui.active_id = id
		}
	}
	if ui.active_id == id {
		held = ui.down[0]
		if ui.released[0] {
			if hover {
				clicked = true
			}
			ui.active_id = 0
		}
	}
	return
}

// Widgets ----------------------------------------------------------------------

// Rounded control surface with a hairline ring.
ctl_surface :: proc(r: Rect, fill, ring: Color) {
	draw_rrect(f32(r.x), f32(r.y), f32(r.w), f32(r.h), RADIUS, fill)
	draw_rrect_outline(f32(r.x), f32(r.y), f32(r.w), f32(r.h), RADIUS, ring)
}

// Sunken field (inputs, sliders, lists).
ctl_well :: proc(r: Rect, ring_in := Color{}) {
	ring := ring_in == {} ? C_RING : ring_in
	draw_rrect(f32(r.x), f32(r.y), f32(r.w), f32(r.h), RADIUS, C_PANEL_DK)
	draw_rrect_outline(f32(r.x), f32(r.y), f32(r.w), f32(r.h), RADIUS, ring)
}

// Raised surface for the current interaction state; returns the foreground colour to use on it.
ctl_state :: proc(r: Rect, hover, held, on, enabled: bool) -> Color {
	fill, ring, fg := C_PANEL_LT, C_RING, C_TEXT
	switch {
	case !enabled:
		fill, fg = C_PANEL, C_TEXT_OFF
	case held:
		fill, ring = C_PANEL_DK, C_RING_HI
		if on do fg = C_ACCENT
	case on:
		fill, ring, fg = C_ACCENT_TINT, with_alpha(C_ACCENT, 150), C_ACCENT
		if hover do fill = with_alpha(C_ACCENT, 78)
	case hover:
		fill, ring = C_HOVER, C_RING_HI
	}
	if on && !enabled do fg = C_TEXT_OFF
	// the tinted fills are translucent: lay them on the plain surface first
	if on && enabled {
		draw_rrect(f32(r.x), f32(r.y), f32(r.w), f32(r.h), RADIUS, C_PANEL_LT)
	}
	ctl_surface(r, fill, ring)
	return fg
}

button :: proc(r: Rect, label: string, tip: Tip, enabled := true, highlight := false) -> bool {
	id := make_id(r, label)
	clicked, held, hover := button_behavior(id, r, tip_for_label(tip, label))
	if !enabled {
		clicked, held, hover = false, false, false
	}
	fg := ctl_state(r, hover, held, highlight, enabled)
	text_centered(r, label, fg)
	return clicked
}

// Filled call-to-action button (dialog OK).
button_primary :: proc(r: Rect, label: string, tip: Tip) -> bool {
	id := make_id(r, label)
	clicked, held, hover := button_behavior(id, r, tip_for_label(tip, label))
	fill := C_ACTIVE
	if hover do fill = shade(C_ACTIVE, 1.13)
	if held do fill = shade(C_ACTIVE, 0.84)
	ctl_surface(r, fill, Color{255, 255, 255, 46})
	text_centered(r, label, WHITE)
	return clicked
}

icon_button :: proc(r: Rect, ic: Icon, tip: Tip, active := false, enabled := true) -> bool {
	id := make_id(r, tip.title)
	clicked, held, hover := button_behavior(id, r, tip)
	if !enabled {
		clicked, held, hover = false, false, false
	}
	fg := ctl_state(r, hover, held, active, enabled)
	icon_centered(ic, r, fg, icon_fit(r))
	return clicked
}

// Small "+" / "-" badge in the top-right corner of a 12x12 icon.
icon_badge :: proc(x, y: i32, plus: bool, c: Color) {
	bx := x + 8
	fill_rect(Rect{bx, y + 2, 5, 1}, c)
	if plus {
		fill_rect(Rect{bx + 2, y, 1, 5}, c)
	}
}

// Icon button with a +/- badge (new layer, delete frame ...).
badge_button :: proc(r: Rect, ic: Icon, plus: bool, tip: Tip, enabled := true) -> bool {
	clicked := icon_button(r, ic, tip, false, enabled)
	x := r.x + (r.w - ICON_SIZE) / 2
	y := r.y + (r.h - ICON_SIZE) / 2
	icon_badge(x, y, plus, enabled ? C_ACCENT : C_TEXT_OFF)
	return clicked
}

toggle_button :: proc(r: Rect, ic: Icon, v: ^bool, tip: Tip) -> bool {
	if icon_button(r, ic, tip, v^) {
		v^ = !v^
		return true
	}
	return false
}

checkbox :: proc(x, y: i32, label: string, v: ^bool, tip: Tip) -> bool {
	r := Rect{x, y, 18 + text_w(label), 12}
	id := make_id(r, label)
	clicked, held, hover := button_behavior(id, r, tip_for_label(tip, label))
	box := Rect{x, y, 12, 12}
	if v^ {
		draw_rrect(f32(box.x), f32(box.y), 12, 12, 2, C_ACCENT_TINT)
		draw_rrect_outline(f32(box.x), f32(box.y), 12, 12, 2, with_alpha(C_ACCENT, 170))
		icon(.Check, box.x, box.y, C_ACCENT)
	} else {
		draw_rrect(f32(box.x), f32(box.y), 12, 12, 2, held ? C_PANEL : C_PANEL_DK)
		draw_rrect_outline(f32(box.x), f32(box.y), 12, 12, 2, hover ? C_RING_HI : C_RING)
	}
	text(x + 17, y + 2, label, hover ? WHITE : C_TEXT)
	if clicked {
		v^ = !v^
		return true
	}
	return false
}

// Horizontal slider with value drawn inside. `suffix` is appended to the value
// ("%", "px"); `curve` > 1 gives finer control at the low end (brush sizes).
// Round values that sliders with a curve (sizes) step through while Shift is held.
SLIDER_STAIRS := [?]int{
	1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 150, 200, 250, 300, 400, 500,
	600, 800, 1000, 1200, 1500, 2000, 2500, 3000, 4000, 5000,
}

// Shift on a slider moves in chunks: angles by 5 degrees, curved (size) sliders along SLIDER_STAIRS,
// everything else by a round step of about a twentieth of the range (5 for 0..100).
slider_chunk :: proc(v, lo, hi: int, suffix: string, curve: f32, dir := 0) -> int {
	if curve != 1 {
		// nearest stair (by ratio), or the next one up / down
		best := v
		if dir == 0 {
			bd := max(f32)
			for s in SLIDER_STAIRS {
				if s < lo || s > hi do continue
				dd := abs(math.ln(f32(max(v, 1)) / f32(s)))
				if dd < bd do best, bd = s, dd
			}
		} else if dir > 0 {
			for s in SLIDER_STAIRS do if s > v && s <= hi {best = s; break}
		} else {
			#reverse for s in SLIDER_STAIRS do if s < v && s >= lo {best = s; break}
		}
		return clamp(best, lo, hi)
	}
	step := 5
	if !strings.contains(suffix, "deg") {
		step = 1
		target := f32(hi - lo) / 20
		for s in ([?]int{1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000}) {
			if f32(s) <= target * 1.3 do step = s
		}
	}
	n := int(math.round(f32(v) / f32(step)))
	if dir != 0 {
		// from an off-step value, the first step lands on the next multiple
		n = int(math.floor(f32(v) / f32(step))) + (dir > 0 ? 1 : 0)
		if dir < 0 && v % step == 0 do n -= 1
	}
	return clamp(n * step, lo, hi)
}

// `tint` colours the filled part (the colour picker uses its channel colours). The value stays on multiples of
// `step` counted from `lo`.
slider :: proc(r: Rect, v: ^int, lo, hi: int, label: string, tip: Tip, suffix := "", curve: f32 = 1, div := 1, tint_in := Color{}, step := 1) -> bool {
	on_step :: proc(v, lo, hi, step: int) -> int {
		return clamp(lo + (clamp(v, lo, hi) - lo + step / 2) / step * step, lo, hi)
	}
	tint := tint_in == {} ? C_ACCENT : tint_in
	id := make_id(r, label)
	_, held, hover := button_behavior(id, r, tip)
	changed := false
	if held || (hover && ui.pressed[0]) {
		t := clamp(f32(ui.mx - r.x) / f32(max(r.w - 1, 1)), 0, 1)
		if curve != 1 {
			t = math.pow(t, curve)
		}
		nv := lo + int(t * f32(hi - lo) + 0.5)
		nv = clamp(nv, lo, hi)
		if ui.shift do nv = slider_chunk(nv, lo, hi, suffix, curve)
		nv = on_step(nv, lo, hi, step)
		if nv != v^ {
			v^ = nv
			changed = true
		}
	}
	if hover && ui.wheel != 0 {
		wheel_step := step
		if curve != 1 {
			wheel_step = max(v^ / 10, 1)
		}
		nv := clamp(v^ + (ui.wheel > 0 ? wheel_step : -wheel_step), lo, hi)
		if ui.shift do nv = slider_chunk(v^, lo, hi, suffix, curve, ui.wheel > 0 ? 1 : -1)
		nv = on_step(nv, lo, hi, step)
		if nv != v^ {
			v^ = nv
			changed = true
		}
	}
	ctl_well(r, hover || held ? C_RING_HI : C_RING)
	frac := f32(v^ - lo) / f32(max(hi - lo, 1))
	if curve != 1 {
		frac = math.pow(clamp(frac, 0, 1), 1 / curve)
	}
	// a translucent fill up to the value, ending in a bright handle
	fw := f32(r.w) * clamp(frac, 0, 1)
	if fw >= 1 {
		fill := tint
		fill.a = hover || held ? 96 : 66
		draw_rrect(f32(r.x), f32(r.y), fw, f32(r.h), RADIUS, fill)
	}
	hx := clamp(f32(r.x) + fw - 2, f32(r.x) + 1, f32(r.x + r.w) - 3)
	draw_rrect(hx, f32(r.y) + 2, 2, f32(r.h) - 4, 1, hover || held ? WHITE : tint)
	vs := div > 1 ? fmt.tprintf("%.*f", div >= 100 ? 2 : 1, f32(v^) / f32(div)) : fmt.tprintf("%d", v^)
	s := label == "" ? fmt.tprintf("%s%s", vs, suffix) : fmt.tprintf("%s: %s%s", label, vs, suffix)
	text_centered(r, s, C_TEXT)
	return changed
}

// Editing core shared by text and numeric fields. Returns (submitted, blurred, cancelled).
edit_core :: proc(buf: ^Name, r: Rect, id: u32, ascii_only := true) -> (submitted, blurred, cancelled: bool) {
	// focus loss by clicking elsewhere
	hover := ui_hover(r)
	if ui.pressed[0] && !hover {
		ui.focus_id = 0
		return false, true, false
	}
	if ui.pressed[0] && hover {
		// place caret
		rel := ui.mx - r.x - 3
		best := 0
		for i in 0 ..= buf.n {
			if text_w(string(buf.b[:i])) <= rel {
				best = i
			}
		}
		ui.caret = best
		ui.sel_all = false
	}
	ui.caret = clamp(ui.caret, 0, buf.n)

	insert :: proc(buf: ^Name, s: string) {
		if ui.sel_all {
			buf.n = 0
			ui.caret = 0
			ui.sel_all = false
		}
		for i in 0 ..< len(s) {
			if buf.n >= len(buf.b) {
				break
			}
			ch := s[i]
			if ch < 32 || ch > 126 {
				continue
			}
			copy(buf.b[ui.caret + 1:buf.n + 1], buf.b[ui.caret:buf.n])
			buf.b[ui.caret] = ch
			buf.n += 1
			ui.caret += 1
		}
	}

	for ch in ui.chars {
		if ch >= 32 && ch < 127 {
			tmp := [1]u8{u8(ch)}
			insert(buf, string(tmp[:]))
		}
	}
	if ui.ctrl && IsKeyPressed(.V) {
		insert(buf, gfx_clipboard_get())
	}
	if ui.ctrl && IsKeyPressed(.C) {
		gfx_clipboard_set(name_str(buf))
	}
	if ui.ctrl && IsKeyPressed(.A) {
		ui.sel_all = true
	}
	if key_hit(.BACKSPACE) {
		if ui.sel_all {
			buf.n = 0
			ui.caret = 0
			ui.sel_all = false
		} else if ui.caret > 0 {
			copy(buf.b[ui.caret - 1:buf.n - 1], buf.b[ui.caret:buf.n])
			buf.n -= 1
			ui.caret -= 1
		}
	}
	if key_hit(.DELETE) {
		if ui.sel_all {
			buf.n = 0
			ui.caret = 0
			ui.sel_all = false
		} else if ui.caret < buf.n {
			copy(buf.b[ui.caret:buf.n - 1], buf.b[ui.caret + 1:buf.n])
			buf.n -= 1
		}
	}
	if key_hit(.LEFT) {
		ui.sel_all = false
		ui.caret = max(ui.caret - 1, 0)
	}
	if key_hit(.RIGHT) {
		ui.sel_all = false
		ui.caret = min(ui.caret + 1, buf.n)
	}
	if IsKeyPressed(.HOME) {
		ui.sel_all = false
		ui.caret = 0
	}
	if IsKeyPressed(.END) {
		ui.sel_all = false
		ui.caret = buf.n
	}
	if IsKeyPressed(.ENTER) || IsKeyPressed(.KP_ENTER) {
		ui.focus_id = 0
		submitted = true
	}
	if IsKeyPressed(.ESCAPE) {
		ui.focus_id = 0
		cancelled = true
	}
	return
}

draw_edit_box :: proc(r: Rect, buf: ^Name, focused: bool) {
	ctl_well(r, focused ? C_ACCENT : C_RING)
	s := name_str(buf)
	clip_begin(rect_inset(r, 2))
	off: i32 = 0
	cw := text_w(string(buf.b[:clamp(ui.caret, 0, buf.n)]))
	if focused && cw > r.w - 10 {
		off = cw - (r.w - 10)
	}
	if focused && ui.sel_all && buf.n > 0 {
		fill_rect(Rect{r.x + 3 - off, r.y + 2, text_w(s) + 2, r.h - 4}, C_ACTIVE)
	}
	text(r.x + 4 - off, r.y + (r.h - FONT_CAP) / 2, s, C_TEXT)
	if focused && !ui.sel_all && i32(ui.time * 2) % 2 == 0 {
		fill_rect(Rect{r.x + 4 - off + cw, r.y + 3, 1, r.h - 6}, C_TEXT)
	}
	clip_end()
}

// Single-line text field. Returns (changed, submitted).
text_field :: proc(r: Rect, buf: ^Name, tip: Tip) -> (changed, submitted: bool) {
	id := make_id(r, "text")
	focused := ui.focus_id == id
	hover := ui_hover(r)
	if hover {
		ui.cursor = .IBEAM
		tooltip_hover(id, tip)
	}
	if focused {
		before := buf^
		sub, _, _ := edit_core(buf, r, id)
		submitted = sub
		changed = before.n != buf.n || before.b != buf.b
	} else if hover && ui.pressed[0] {
		ui.focus_id = id
		ui.sel_all = true
		ui.caret = buf.n
	}
	draw_edit_box(r, buf, ui.focus_id == id)
	return
}

// Numeric field: click to type, mouse wheel to nudge.
field_int :: proc(r: Rect, v: ^int, lo, hi: int, tip: Tip) -> bool {
	id := make_id(r, "int")
	focused := ui.focus_id == id
	hover := ui_hover(r)
	changed := false
	if hover {
		ui.cursor = .IBEAM
		tooltip_hover(id, tip)
	}
	if focused {
		before := ui.edit
		sub, blur, _ := edit_core(&ui.edit, r, id)
		typed := before.n != ui.edit.n || before.b != ui.edit.b
		if sub || blur || typed {
			n, ok := strconv.parse_int(name_str(&ui.edit))
			// While typing only accept values already inside the range, so that
			// e.g. typing "1" then "6" into a field with minimum 10 works.
			if ok && (sub || blur || (n >= lo && n <= hi)) {
				nv := clamp(n, lo, hi)
				if nv != v^ {
					v^ = nv
					changed = true
				}
			}
		}
		draw_edit_box(r, &ui.edit, ui.focus_id == id)
	} else {
		if hover && ui.pressed[0] {
			ui.focus_id = id
			name_set(&ui.edit, fmt.tprintf("%d", v^))
			ui.sel_all = true
			ui.caret = ui.edit.n
		}
		if hover && ui.wheel != 0 {
			nv := clamp(v^ + (ui.wheel > 0 ? 1 : -1), lo, hi)
			if nv != v^ {
				v^ = nv
				changed = true
			}
		}
		ctl_well(r, hover ? C_RING_HI : C_RING)
		s := fmt.tprintf("%d", v^)
		text(r.x + 4, r.y + (r.h - FONT_CAP) / 2, s, C_TEXT)
	}
	return changed
}

label :: proc(x, y: i32, s: string, c := Color{}) {
	text(x, y, s, c == {} ? C_TEXT : c)
}

// Popup menus / combos -----------------------------------------------------------

Popup_Item :: struct {
	label:   Name,
	value:   int,
	cmd:     Cmd,
	checked: bool,
	enabled: bool,
	sep:     bool,
	tip:     string, // the tooltip's description: a constant, it outlives the frame
	// grid popups only
	icon:     Icon,
	has_icon: bool,
	color:    Color, // swatch shown beside the label
	has_color: bool,
	half:     bool, // text item taking half a row
	// a strip of colours at the right edge (palette presets). Copied, so the source can be a temporary.
	pal:      [8]Color,
	pal_n:    int,
}

Popup :: struct {
	scroll: i32, // a list taller than the window
	open:      bool,
	owner:     u32,
	menu_idx:  int, // menubar index or -1
	anchor:    Rect,
	min_w:     i32,
	items:     [dynamic]Popup_Item,
	above:     bool,
	side:      bool, // open to the right of the anchor
	grid:      bool, // visual picker: icon items in a grid, other items as full-width rows
	cols:      int,
}

popup: Popup

popup_begin :: proc(owner: u32, anchor: Rect, min_w: i32 = 0, menu_idx := -1) {
	popup.scroll = 0
	popup.open = true
	popup.owner = owner
	popup.anchor = anchor
	popup.min_w = max(min_w, anchor.w)
	popup.menu_idx = menu_idx
	popup.above = false
	popup.side = false
	popup.grid = false
	clear(&popup.items)
}

// Turns the popup just begun into an icon grid.
popup_grid :: proc(cols: int) {
	popup.grid = true
	popup.cols = cols
}

popup_item_icon :: proc(label: string, value: int, ic: Icon, tip: string) {
	popup_item(label, value, tip = tip)
	popup.items[len(popup.items) - 1].icon = ic
	popup.items[len(popup.items) - 1].has_icon = true
}

popup_item_half :: proc(label: string, value: int) {
	popup_item(label, value)
	popup.items[len(popup.items) - 1].half = true
}

popup_item_swatch :: proc(label: string, value: int, c: Color) {
	popup_item(label, value)
	popup.items[len(popup.items) - 1].color = c
	popup.items[len(popup.items) - 1].has_color = true
}

// An item with a preview of a palette's colours.
popup_item_palette :: proc(label: string, value: int, colors: []Color, tip := "") {
	popup_item(label, value, tip = tip)
	it := &popup.items[len(popup.items) - 1]
	it.pal_n = min(len(colors), len(it.pal))
	for k in 0 ..< it.pal_n do it.pal[k] = colors[k * len(colors) / it.pal_n]
}

popup_item :: proc(label: string, value := 0, cmd := Cmd.None, checked := false, enabled := true, tip := "") {
	it := Popup_Item {
		label   = make_name(label),
		value   = value,
		cmd     = cmd,
		checked = checked,
		enabled = enabled,
		tip     = tip != "" ? tip : cmd_help(cmd),
	}
	append(&popup.items, it)
}

popup_sep :: proc() {
	append(&popup.items, Popup_Item{sep = true})
}

popup_close :: proc() {
	popup.open = false
	clear(&popup.items)
}

POPUP_ITEM_H :: 16

popup_run :: proc() {
	if !popup.open {
		return
	}
	ui.layer = ui.input_layer
	if popup.grid {
		popup_run_grid()
		return
	}
	w := popup.min_w
	h: i32 = 8
	for &it in popup.items {
		if it.sep {
			h += 7
			continue
		}
		iw := text_w(name_str(&it.label)) + 34
		if it.cmd != .None {
			sc := shortcut_text(it.cmd)
			if sc != "" {
				iw += text_w(sc) + 16
			}
		}
		w = max(w, iw)
		h += POPUP_ITEM_H
	}
	x := popup.anchor.x
	y := popup.anchor.y + popup.anchor.h
	if popup.side {
		x = popup.anchor.x + popup.anchor.w
		y = popup.anchor.y
	}
	// never wider or taller than the window: a list that does not fit scrolls with the wheel
	w = min(w, i32(ui.w))
	full_h := h
	h = min(h, i32(ui.h))
	x = max(min(x, i32(ui.w) - w), 0)
	if y + h > i32(ui.h) {
		y = max(popup.anchor.y - h, 0)
		if popup.side || y + h > i32(ui.h) {
			y = i32(ui.h) - h
		}
	}
	box := Rect{x, y, w, h}
	if full_h > h {
		popup.scroll = clamp(popup.scroll - i32(ui.wheel) * POPUP_ITEM_H * 2, 0, full_h - h)
	} else {
		popup.scroll = 0
	}
	// shadow + frame
	draw_shadow(f32(box.x), f32(box.y + 3), f32(box.w), f32(box.h), 6, 10, Color{0, 0, 0, 150})
	draw_rrect(f32(box.x), f32(box.y), f32(box.w), f32(box.h), 6, C_PANEL)
	draw_rrect_outline(f32(box.x), f32(box.y), f32(box.w), f32(box.h), 6, C_RING_HI)
	clip_begin(box)
	defer clip_end()
	cy := box.y + 4 - popup.scroll
	for &it in popup.items {
		if it.sep {
			hline(box.x + 8, cy + 3, box.w - 16, C_RING_HI)
			cy += 7
			continue
		}
		ir := Rect{box.x + 4, cy, box.w - 8, POPUP_ITEM_H}
		tip_area(ir, "popup", Tip{"", it.tip}) // the item's own text is the title
		hover := ui_hover(ir) && it.enabled
		if hover {
			draw_rrect(f32(ir.x), f32(ir.y), f32(ir.w), f32(ir.h), RADIUS, C_ACTIVE)
		}
		col := it.enabled ? (hover ? WHITE : C_TEXT) : C_TEXT_OFF
		if it.checked {
			icon(.Check, ir.x + 2, ir.y + 2, hover ? WHITE : C_ACCENT)
		}
		text(ir.x + 17, ir.y + (POPUP_ITEM_H - FONT_CAP) / 2, name_str(&it.label), col)
		if it.pal_n > 0 {
			cw := i32(7)
			sx := ir.x + ir.w - i32(it.pal_n) * cw - 6
			for k in 0 ..< it.pal_n {
				fill_rect(Rect{sx + i32(k) * cw, ir.y + 4, cw, ir.h - 8}, it.pal[k])
			}
		}
		if it.cmd != .None {
			sc := shortcut_text(it.cmd)
			if sc != "" {
				text(ir.x + ir.w - text_w(sc) - 7, ir.y + (POPUP_ITEM_H - FONT_CAP) / 2, sc, hover ? C_TEXT : C_TEXT_DIM)
			}
		}
		if hover && ui.pressed[0] {
			cmd := it.cmd
			if cmd == .None {
				ui.popup_result_id = popup.owner
				ui.popup_result_val = it.value
			}
			popup_close()
			if cmd != .None {
				run_cmd(cmd)
			}
			return
		}
		cy += POPUP_ITEM_H
	}
	if (ui.pressed[0] || ui.pressed[1]) && !in_rect(box, ui.mx, ui.my) {
		// Clicking the menubar title is handled by the menubar itself.
		if !(popup.menu_idx >= 0 && in_rect(popup.anchor, ui.mx, ui.my)) {
			popup_close()
		}
	}
	if IsKeyPressed(.ESCAPE) {
		popup_close()
	}
}

GRID_CELL :: 28
GRID_GAP :: 2
GRID_ROW_H :: 20
GRID_FOOT_H :: 18

// Visual picker: icon items flow in a grid, a separator or a plain item starts a new row.
popup_run_grid :: proc() {
	cols := max(popup.cols, 1)
	pitch := i32(GRID_CELL + GRID_GAP)
	w := i32(cols) * pitch - GRID_GAP + 8
	rects := make([]Rect, len(popup.items), context.temp_allocator)
	cy: i32 = 4
	col := 0
	hcol := 0
	hw := (w - 8 - GRID_GAP) / 2
	for &it, i in popup.items {
		if it.half {
			if col > 0 {
				col = 0
				cy += pitch
			}
			rects[i] = Rect{4 + i32(hcol) * (hw + GRID_GAP), cy, hw, GRID_ROW_H}
			hcol += 1
			if hcol == 2 {
				hcol = 0
				cy += GRID_ROW_H + GRID_GAP
			}
			continue
		}
		if hcol > 0 {
			hcol = 0
			cy += GRID_ROW_H + GRID_GAP
		}
		if it.has_icon {
			rects[i] = Rect{4 + i32(col) * pitch, cy, GRID_CELL, GRID_CELL}
			col += 1
			if col == cols {
				col = 0
				cy += pitch
			}
			continue
		}
		if col > 0 {
			col = 0
			cy += pitch
		}
		if it.sep {
			rects[i] = Rect{4, cy + 2, w - 8, 1}
			cy += 7
		} else {
			rects[i] = Rect{4, cy, w - 8, GRID_ROW_H}
			cy += GRID_ROW_H + GRID_GAP
		}
	}
	if col > 0 {
		cy += pitch
	}
	if hcol > 0 {
		cy += GRID_ROW_H + GRID_GAP
	}
	h := cy + 2 + GRID_FOOT_H

	x := popup.anchor.x
	y := popup.anchor.y + popup.anchor.h
	if x + w > i32(ui.w) {
		x = i32(ui.w) - w
	}
	if y + h > i32(ui.h) {
		y = max(i32(ui.h) - h, 0)
	}
	box := Rect{x, y, w, h}
	draw_shadow(f32(box.x), f32(box.y + 3), f32(box.w), f32(box.h), 6, 10, Color{0, 0, 0, 150})
	draw_rrect(f32(box.x), f32(box.y), f32(box.w), f32(box.h), 6, C_PANEL)
	draw_rrect_outline(f32(box.x), f32(box.y), f32(box.w), f32(box.h), 6, C_RING_HI)

	hovered := -1
	for &it, i in popup.items {
		ir := rects[i]
		ir.x += box.x
		ir.y += box.y
		if it.sep {
			hline(ir.x, ir.y, ir.w, C_RING_HI)
			continue
		}
		tip_area(ir, "popup", Tip{name_str(&it.label), it.tip})
		hover := ui_hover(ir) && it.enabled
		if hover {
			hovered = i
		}
		ctl_surface(ir, hover ? C_HOVER : C_PANEL_LT, hover ? C_RING_HI : C_RING)
		if it.has_icon {
			icon_centered(it.icon, ir, hover ? WHITE : C_TEXT, ICON_SIZE_LG)
		} else {
			tx := ir.x + 8
			if it.has_color {
				sw := Rect{ir.x + 5, ir.y + 4, 12, ir.h - 8}
				draw_rrect(f32(sw.x), f32(sw.y), f32(sw.w), f32(sw.h), 2, it.color)
				draw_rrect_outline(f32(sw.x), f32(sw.y), f32(sw.w), f32(sw.h), 2, C_RING_HI)
				tx = sw.x + sw.w + 6
			}
			text(tx, ir.y + (ir.h - FONT_CAP) / 2, name_str(&it.label), hover ? WHITE : C_TEXT)
		}
		if hover && ui.pressed[0] {
			ui.popup_result_id = popup.owner
			ui.popup_result_val = it.value
			popup_close()
			return
		}
	}
	// the hovered item's name in the footer
	if hovered >= 0 {
		text(box.x + 8, box.y + box.h - GRID_FOOT_H + (GRID_FOOT_H - FONT_CAP) / 2 - 1, name_str(&popup.items[hovered].label), C_TEXT_DIM)
	}
	if (ui.pressed[0] || ui.pressed[1]) && !in_rect(box, ui.mx, ui.my) {
		popup_close()
	}
	if IsKeyPressed(.ESCAPE) {
		popup_close()
	}
}

// Drop-down selector. Returns the newly picked index (one frame after the click).
combo :: proc(r: Rect, items: []string, cur: int, tip: Tip) -> (new_val: int, changed: bool) {
	id := make_id(r, "combo")
	clicked, held, hover := button_behavior(id, r, tip)
	fg := ctl_state(r, hover, held || popup.open && popup.owner == id, false, true)
	s := cur >= 0 && cur < len(items) ? items[cur] : ""
	text_clipped(Rect{r.x + 5, r.y, r.w - 20, r.h}, s, fg)
	icon(.Down, r.x + r.w - 14, r.y + (r.h - ICON_SIZE) / 2, C_TEXT_DIM)
	if ui.popup_result_id == id {
		new_val = ui.popup_result_val
		changed = true
		ui.popup_result_id = 0
	}
	// Cycle through the options with the mouse wheel or up/down arrows.
	if !changed && len(items) > 1 {
		is_open := popup.open && popup.owner == id
		dir := 0
		if hover && ui.wheel != 0 {
			dir = ui.wheel > 0 ? -1 : 1
		} else if hover || is_open {
			if IsKeyPressed(.UP) {
				dir = -1
			} else if IsKeyPressed(.DOWN) {
				dir = 1
			}
		}
		if dir != 0 {
			nv := clamp(cur + dir, 0, len(items) - 1)
			if is_open {
				popup_close()
			}
			if nv != cur {
				return nv, true
			}
			return
		}
	}
	if clicked {
		popup_begin(id, r, r.w)
		for it, i in items {
			popup_item(it, i, checked = i == cur, tip = tip.desc)
		}
	}
	return
}

combo_enum :: proc(r: Rect, names: [$E]string, v: ^E, tip: Tip) -> bool {
	items: [len(E)]string
	for n, i in names {
		items[i] = n
	}
	nv, ch := combo(r, items[:], int(v^), tip)
	if ch {
		v^ = E(nv)
	}
	return ch
}

// Tooltip overlay --------------------------------------------------------------

TIP_MAX_W :: 300
TIP_LINE_H :: 13
TIP_DESC_GAP :: 6 // between the title and the description

// Breaks text at spaces into lines no wider than `max_w`. A single word wider than that stays whole.
tooltip_wrap :: proc(s: string, max_w: i32, measure: proc(_: string) -> i32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	start, last_space := 0, -1
	for i := 0; i <= len(s); i += 1 {
		if i < len(s) && s[i] != ' ' do continue
		if measure(s[start:i]) > max_w && last_space > start {
			append(&lines, s[start:last_space])
			start = last_space + 1
		}
		last_space = i
	}
	if start < len(s) do append(&lines, s[start:])
	return lines[:]
}

tooltip_draw :: proc() {
	tooltip_resolve()
	has_title := ui.tip.title != ""
	if !has_title && !ui.tip_desc {
		return
	}
	max_w := min(TIP_MAX_W, i32(ui.w) - 14)
	title := tooltip_wrap(ui.tip.title, max_w, text_w)
	desc := tooltip_wrap(ui.tip.desc, max_w, text_w)
	title_w, desc_w: i32
	for l in title do title_w = max(title_w, text_w(l))
	for l in desc do desc_w = max(desc_w, text_w(l))
	show_desc := ui.tip_desc && len(desc) > 0
	if !has_title && !show_desc {
		return
	}
	title_h := has_title ? i32(len(title)) * TIP_LINE_H + 5 : 0
	desc_h := len(desc) > 0 ? i32(len(desc)) * TIP_LINE_H + (has_title ? TIP_DESC_GAP : 5) : 0
	w := (show_desc ? max(title_w, desc_w) : title_w) + 14
	h := show_desc ? title_h + desc_h : title_h
	// beside the pointer. It grows down and to the right unless the window's edge makes it grow the other way.
	x := ui.mx + 10
	y := ui.my + 14
	if x + w > i32(ui.w) {
		x = i32(ui.w) - w
	}
	if y + h > i32(ui.h) {
		y = ui.my - h - 4
	}
	x, y = max(x, 0), max(y, 0)
	draw_shadow(f32(x), f32(y + 2), f32(w), f32(h), 4, 6, Color{0, 0, 0, 130})
	draw_rrect(f32(x), f32(y), f32(w), f32(h), 4, with_alpha(shade(C_PANEL_DK, 0.55), 248))
	draw_rrect_outline(f32(x), f32(y), f32(w), f32(h), 4, C_RING_HI)
	for l, i in title {
		text(x + 7, y + 3 + i32(i) * TIP_LINE_H + (TIP_LINE_H - FONT_CAP) / 2, l, WHITE)
	}
	if show_desc {
		dy := has_title ? y + title_h + TIP_DESC_GAP - 2 : y + 3
		if has_title do hline(x + 7, y + title_h + TIP_DESC_GAP / 2 - 1, w - 14, C_RING_HI)
		for l, i in desc {
			text(x + 7, dy + i32(i) * TIP_LINE_H + (TIP_LINE_H - FONT_CAP) / 2, l, C_TEXT)
		}
	}
}

// ---------------------------------------------------------------------------
// Dialog windows
// ---------------------------------------------------------------------------

@(private = "file")
dialog_scroll: i32
@(private = "file")
dialog_scroll_id: u32
@(private = "file")
dialog_clipped: bool

// Draws the dim background and the window frame; returns the content area. A window is never larger than
// the program's: one that does not fit gets narrower, and its content scrolls with the mouse wheel.
// The main loop calls dialog_frame_end after the dialog's content.
dialog_frame :: proc(title: string, w_in, h_in: i32, dim := true, docked := false) -> Rect {
	ui.layer = 2
	if dim && !docked {
		fill_rect(Rect{0, 0, i32(ui.w), i32(ui.h)}, Color{6, 7, 10, 130})
	}
	w := min(w_in, i32(ui.w) - 8)
	h := min(h_in, i32(ui.h) - 8)
	x := (i32(ui.w) - w) / 2
	y := (i32(ui.h) - h) / 2
	if docked {
		x = max(canvas_vp.x + canvas_vp.w - w - 12, 4)
		y = min(canvas_vp.y + 12, i32(ui.h) - h - 4)
	}
	box := Rect{x, y, w, h}
	draw_shadow(f32(x), f32(y + 6), f32(w), f32(h), 7, 22, Color{0, 0, 0, 190})
	draw_rrect(f32(x), f32(y), f32(w), f32(h), 7, C_PANEL)
	// title bar: rounded on top only (the lower half is clipped away)
	clip_begin(Rect{x, y, w, 20})
	draw_rrect(f32(x), f32(y), f32(w), 40, 7, C_PANEL_DK)
	clip_end()
	hline(x, y + 20, w, C_BORDER)
	draw_rrect_outline(f32(x), f32(y), f32(w), f32(h), 7, C_RING_HI)
	text(x + 12, y + (20 - FONT_CAP) / 2, title, C_TEXT)
	c := Rect{x + 12, y + 26, w - 24, h - 34}
	id := make_id({}, title)
	if id != dialog_scroll_id {
		dialog_scroll_id = id
		dialog_scroll = 0
	}
	extra := h_in - h
	if extra <= 0 {
		dialog_scroll = 0
		return c
	}
	if in_rect(box, ui.mx, ui.my) do dialog_scroll -= i32(ui.wheel) * 24
	dialog_scroll = clamp(dialog_scroll, 0, extra)
	th := max(c.h * c.h / (c.h + extra), 12)
	draw_rrect(f32(x + w - 5), f32(c.y + dialog_scroll * (c.h - th) / extra), 3, f32(th), 1, C_RING_HI)
	clip_begin(Rect{x + 1, y + 21, w - 2, h - 22})
	dialog_clipped = true
	c.y -= dialog_scroll
	c.h += extra
	return c
}

dialog_frame_end :: proc() {
	if dialog_clipped {
		clip_end()
		dialog_clipped = false
	}
}
