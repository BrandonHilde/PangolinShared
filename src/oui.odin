package pangolin

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

import oui "odinui:odinui"
import oui_fonts "odinui:backends/fonts"
import ocss "odinui:css"
import olay "odinui:css/layout"

// ---------------------------------------------------------------------------
// OdinUI host: the interface is laid out and styled by CSS (assets/ui/theme.css, plus theme.css
// next to the executable for the user's changes) and drawn here with the SDL renderer.
//
// - Icons are a font: family "icons", code point ICON_CP0 + the Icon value, so CSS colours and
//   sizes them like text.
// - Areas the program draws itself (the canvas, panels not built from CSS yet) are image nodes
//   whose source is "draw:<name>"; the backend calls the matching slot proc when the image comes
//   up in the display list, so they paint in the right order between CSS boxes.
// ---------------------------------------------------------------------------

THEME_CSS :: #load("../assets/ui/theme.css", string)

ICON_FONT :: olay.Font(0x7fff_0000)
ICON_CP0 :: 0xE000

uictx: ^oui.Context

// ui.input_layer while the CSS interface has the pointer: above every hand-drawn layer
OUI_INPUT_LAYER :: 8

@(private = "file")
fonts: oui_fonts.Fonts
@(private = "file")
base_fonts: olay.Font_Provider
@(private = "file")
glyphs: oui.Glyph_Source
@(private = "file")
glyph_tex: Texture
@(private = "file")
theme_seen := -1

Slot_Proc :: proc(r: Rect, arg: int)

@(private = "file")
Slot_Image :: struct {
	fn:  Slot_Proc,
	arg: int,
}

@(private = "file")
slot_procs: map[string]Slot_Proc
@(private = "file")
slot_images: [dynamic]Slot_Image // image handle - 1
@(private = "file")
slot_by_src: map[string]oui.Image

// The user's theme file: loaded over the default theme and watched.
user_theme_path :: proc() -> string {
	return fmt.tprintf("%stheme.css", gfx_app_dir())
}

oui_init :: proc() {
	oui_fonts.init(&fonts)
	oui_fonts.add_memory(&fonts, "Jersey 10", FONT_DATA)
	oui_fonts.set_default(&fonts, "Jersey 10")
	base_fonts = oui_fonts.provider(&fonts)
	glyphs = oui_fonts.glyph_source(&fonts)
	provider := base_fonts
	provider.match = font_match
	provider.advance = font_advance
	provider.kern = font_kern
	provider.vertical = font_vertical
	uictx = oui.init({
		backend = {draw = backend_draw, begin = backend_begin, fonts = provider, resolve_image = backend_resolve_image},
		theme = {base = THEME_CSS, path = strings.clone(user_theme_path()), watch = true},
		viewport = {f32(gfx.pw), f32(gfx.ph)},
	})
}

// Registers a proc that draws the area of "draw:<name>" image nodes.
oui_slot_register :: proc(name: string, fn: Slot_Proc) {
	slot_procs[name] = fn
}

// An area drawn by `name`'s slot proc, laid out by CSS (`#key` / `.slot`).
oui_slot :: proc(key, name: string, arg := 0, class := "slot", style := "") -> ^oui.Node {
	src := arg == 0 ? fmt.tprintf("draw:%s", name) : fmt.tprintf("draw:%s:%d", name, arg)
	return oui.image(uictx, key, src, {id = key, class = class, style = style})
}

// Starts the CSS interface's frame. Mouse input goes to it only while no old-style popup or dialog
// is up; keys only while one of its text fields has focus, so Space, Enter and the arrows keep
// working as shortcuts.
oui_begin_frame :: proc() {
	oui.set_scale(uictx, ui.scale)
	inp: oui.Input
	inp.viewport = {f32(gfx.pw), f32(gfx.ph)}
	inp.dt = ui.dt
	inp.mouse = {-1e6, -1e6}
	if ui.input_layer == 0 {
		inp.mouse = ui.ptr
		btns := [3]oui.Mouse_Button{.Left, .Right, .Middle}
		for b, i in btns {
			if ui.down[i] do inp.mouse_down += {b}
			if ui.pressed[i] do inp.mouse_pressed += {b}
			if ui.released[i] do inp.mouse_released += {b}
		}
		inp.wheel = {ui.wheel_h, ui.wheel}
	}
	if oui.wants_keyboard(uictx) {
		sb := strings.builder_make(context.temp_allocator)
		for r in ui.chars do strings.write_rune(&sb, r)
		inp.text = strings.to_string(sb)
		keys := [?]struct {
			k:  oui.Key,
			kk: KeyboardKey,
		}{{.Tab, .TAB}, {.Enter, .ENTER}, {.Escape, .ESCAPE}, {.Backspace, .BACKSPACE}, {.Delete, .DELETE}, {.Left, .LEFT}, {.Right, .RIGHT}, {.Up, .UP}, {.Down, .DOWN}, {.Home, .HOME}, {.End, .END}, {.A, .A}, {.C, .C}, {.V, .V}, {.X, .X}}
		for k in keys {
			if IsKeyDown(k.kk) do inp.keys_down += {k.k}
			if key_hit(k.kk) do inp.keys_pressed += {k.k}
		}
		if ui.ctrl do inp.mods += {.Ctrl}
		if ui.shift do inp.mods += {.Shift}
		if ui.alt do inp.mods += {.Alt}
	}
	oui.begin_frame(uictx, inp)
	// the pointer is on one of its controls (or dragging one, or in an open list): the
	// hand-drawn widgets and the canvas leave it alone
	if oui.wants_mouse(uictx) {
		ui.input_layer = OUI_INPUT_LAYER
	}
	if v := oui.theme_version(uictx); v != theme_seen {
		theme_seen = v
		theme_apply_palette()
	}
}

oui_end_frame :: proc() {
	oui.end_frame(uictx)
}

oui_render :: proc() {
	oui.render(uictx)
	clip_depth = 0
	clip_clear()
}

// A node's last laid-out box in the interface's logical pixels.
oui_rect :: proc(n: ^oui.Node) -> Rect {
	if n == nil do return {}
	return irect(n.rect)
}

// Our tooltip for a node under the pointer.
oui_tip :: proc(n: ^oui.Node, tip: Tip) {
	if n != nil && n.hovered && (tip.title != "" || tip.desc != "") {
		tooltip_hover(u32(uintptr(n)) | 1, tip)
	}
}

Icon_Button_Opts :: struct {
	id:      string,
	class:   string, // added to "icon-btn"
	lit:     bool, // toggled on (:checked)
	enabled: bool,
	icon_lg: bool, // the large icon size (tool buttons)
}

// A button showing one icon. Returns whether it was clicked.
oui_icon_button :: proc(key: string, ic: Icon, tip: Tip, opts := Icon_Button_Opts{enabled = true}) -> (clicked: bool, n: ^oui.Node) {
	class := opts.class == "" ? "icon-btn" : fmt.tprintf("icon-btn %s", opts.class)
	n = oui.button_begin(uictx, key, {id = opts.id, class = class, checked = opts.lit, disabled = !opts.enabled})
	oui.label(uictx, "icon", icon_text(ic), {class = opts.icon_lg ? "icon lg" : "icon"})
	oui.end(uictx)
	oui_tip(n, tip)
	return n.clicked, n
}

// The palette the hand-drawn parts of the interface use, from the theme's custom properties.
theme_apply_palette :: proc() {
	col :: proc(name: string, fallback: Color) -> Color {
		return Color(oui.theme_color(uictx, name, ocss.Color(fallback)))
	}
	C_BG = col("--bg", C_BG)
	C_PANEL = col("--panel", C_PANEL)
	C_PANEL_DK = col("--panel-dark", C_PANEL_DK)
	C_PANEL_LT = col("--panel-light", C_PANEL_LT)
	C_BORDER = col("--border", C_BORDER)
	C_RING = col("--ring", C_RING)
	C_RING_HI = col("--ring-hi", C_RING_HI)
	C_HOVER = col("--hover", C_HOVER)
	C_ACTIVE = col("--active", C_ACTIVE)
	C_ACCENT = col("--accent", C_ACCENT)
	C_ACCENT_TINT = col("--accent-tint", C_ACCENT_TINT)
	C_TEXT = col("--text", C_TEXT)
	C_TEXT_DIM = col("--text-dim", C_TEXT_DIM)
	C_TEXT_OFF = col("--text-off", C_TEXT_OFF)
	C_VIEWPORT = col("--viewport", C_VIEWPORT)
	C_DANGER = col("--danger", C_DANGER)
	RADIUS = oui.theme_number(uictx, "--radius", RADIUS)
}

// Fonts ------------------------------------------------------------------------

@(private = "file")
font_match :: proc(data: rawptr, family: string, weight: u16, italic: bool) -> olay.Font {
	if strings.contains(family, "icons") {
		return ICON_FONT
	}
	return base_fonts.match(base_fonts.data, family, weight, italic)
}

@(private = "file")
font_advance :: proc(data: rawptr, font: olay.Font, size: f32, r: rune) -> f32 {
	if font == ICON_FONT do return size
	return base_fonts.advance(base_fonts.data, font, size, r)
}

@(private = "file")
font_kern :: proc(data: rawptr, font: olay.Font, size: f32, left, right: rune) -> f32 {
	if font == ICON_FONT || base_fonts.kern == nil do return 0
	return base_fonts.kern(base_fonts.data, font, size, left, right)
}

@(private = "file")
font_vertical :: proc(data: rawptr, font: olay.Font, size: f32) -> (ascent, descent, gap: f32) {
	if font == ICON_FONT do return size, 0, 0
	return base_fonts.vertical(base_fonts.data, font, size)
}

// The text of an icon glyph, for labels in the "icons" font.
icon_text :: proc(ic: Icon) -> string {
	buf, n := utf8.encode_rune(rune(ICON_CP0 + int(ic)))
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// Backend ----------------------------------------------------------------------

// Hairlines (0.5px at 2x) always show.
@(private = "file")
frect :: proc(r: olay.Rect) -> (x, y, w, h: f32) {
	return snap_box(r.x, r.y, r.z, r.w)
}

@(private = "file")
irect :: proc(r: olay.Rect) -> Rect {
	x0, y0 := i32(math.floor(r.x + 0.01)), i32(math.floor(r.y + 0.01))
	x1, y1 := i32(math.ceil(r.x + r.z - 0.01)), i32(math.ceil(r.y + r.w - 0.01))
	return Rect{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

@(private = "file")
backend_begin :: proc(data: rawptr, frame: oui.Render_Frame) {
	clip_depth = 0
	clip_clear()
}

@(private = "file")
backend_resolve_image :: proc(data: rawptr, src: string) -> (image: oui.Image, size: oui.V2, ok: bool) {
	if h, found := slot_by_src[src]; found {
		return h, {}, true
	}
	if !strings.has_prefix(src, "draw:") {
		return 0, {}, false
	}
	rest := src[5:]
	name, arg := rest, 0
	if i := strings.index_byte(rest, ':'); i >= 0 {
		name = rest[:i]
		for ch in rest[i + 1:] do arg = arg * 10 + int(ch - '0')
	}
	fn, have := slot_procs[name]
	if !have {
		fmt.eprintln("odinui: no slot named", name)
		return 0, {}, false
	}
	append(&slot_images, Slot_Image{fn, arg})
	h := oui.Image(len(slot_images))
	slot_by_src[strings.clone(src)] = h
	return h, {}, true
}

@(private = "file")
backend_draw :: proc(data: rawptr, cmd: olay.Command) {
	switch c in cmd {
	case olay.Fill_Cmd:
		x, y, w, h := frect(c.rect)
		draw_rrect(x, y, w, h, c.radius, Color(c.color))
	case olay.Shadow_Cmd:
		x, y, w, h := frect(c.rect)
		draw_shadow(x, y, w, h, c.radius, max(c.blur / 2, 1), Color(c.color))
	case olay.Border_Cmd:
		draw_border(c)
	case olay.Gradient_Cmd:
		draw_css_gradient(c)
	case olay.Text_Cmd:
		draw_css_text(c)
	case olay.Image_Cmd:
		idx := int(c.image) - 1
		if idx < 0 || idx >= len(slot_images) do break
		s := slot_images[idx]
		clip_begin(irect(c.clip))
		s.fn(irect(c.rect), s.arg)
		clip_end()
	case olay.Clip_Cmd:
		clip_begin(irect(c.rect))
	case olay.Unclip_Cmd:
		clip_end()
	}
}

@(private = "file")
draw_border :: proc(c: olay.Border_Cmd) {
	x, y, w, h := frect(c.rect)
	wd := c.width
	uniform := wd[0] == wd[1] && wd[1] == wd[2] && wd[2] == wd[3] && c.color[0] == c.color[1] && c.color[1] == c.color[2] && c.color[2] == c.color[3]
	if uniform && wd[0] > 0 && c.style[0] != .None {
		draw_rrect_outline(x, y, w, h, c.radius, Color(c.color[0]), max(i32(math.round(wd[0] * gfx.scale)), 1))
		return
	}
	// per side, square corners
	if c.style[0] != .None do draw_rect(x, y, w, wd[0], Color(c.color[0]))
	if c.style[2] != .None do draw_rect(x, y + h - wd[2], w, wd[2], Color(c.color[2]))
	if c.style[3] != .None do draw_rect(x, y + wd[0], wd[3], h - wd[0] - wd[2], Color(c.color[3]))
	if c.style[1] != .None do draw_rect(x + w - wd[1], y + wd[0], wd[1], h - wd[0] - wd[2], Color(c.color[1]))
}

// Gradient stops along the gradient line as fractions, filled in as CSS does.
@(private = "file")
stop_positions :: proc(g: ocss.Gradient, length: f32) -> []f32 {
	n := len(g.stops)
	pos := make([]f32, n, context.temp_allocator)
	known := make([]bool, n, context.temp_allocator)
	for st, i in g.stops {
		if !st.has_pos do continue
		known[i] = true
		if st.pos.unit == .Percent {
			pos[i] = st.pos.value / 100 + (length > 0 ? st.pos.offset / length : 0)
		} else {
			pos[i] = length > 0 ? st.pos.value / length : 0
		}
	}
	if !known[0] do pos[0], known[0] = 0, true
	if !known[n - 1] do pos[n - 1], known[n - 1] = 1, true
	for i := 1; i < n; i += 1 {
		if known[i] {
			pos[i] = max(pos[i], pos[i - 1])
			continue
		}
		j := i
		for !known[j] do j += 1
		for k in i ..< j do pos[k] = pos[i - 1] + (pos[j] - pos[i - 1]) * f32(k - i + 1) / f32(j - i + 1)
	}
	return pos
}

@(private = "file")
gradient_at :: proc(g: ocss.Gradient, pos: []f32, t_in: f32) -> [4]f32 {
	n := len(g.stops)
	t := t_in
	if g.repeating {
		span := max(pos[n - 1], 1e-4)
		t = t - span * math.floor(t / span)
	}
	cf :: proc(c: ocss.Color) -> [4]f32 {return {f32(c.r), f32(c.g), f32(c.b), f32(c.a)} / 255}
	if t <= pos[0] do return cf(g.stops[0].color)
	if t >= pos[n - 1] do return cf(g.stops[n - 1].color)
	for i in 1 ..< n {
		if t > pos[i] do continue
		d := pos[i] - pos[i - 1]
		k := d > 0 ? (t - pos[i - 1]) / d : 1
		return math.lerp(cf(g.stops[i - 1].color), cf(g.stops[i].color), k)
	}
	return cf(g.stops[n - 1].color)
}

// Linear and radial gradients as a grid of vertex colours, clipped to the element's box.
@(private = "file")
draw_css_gradient :: proc(c: olay.Gradient_Cmd) {
	g := c.gradient
	if len(g.stops) == 0 do return
	lx, ly, lw, lh := frect(c.rect)
	if lw <= 0 || lh <= 0 do return
	// the visible part
	x0, y0 := max(lx, c.clip.x), max(ly, c.clip.y)
	x1, y1 := min(lx + lw, c.clip.x + c.clip.z), min(ly + lh, c.clip.y + c.clip.w)
	if x1 <= x0 || y1 <= y0 do return

	dir: [2]f32
	length, rx, ry, cx, cy: f32
	if !g.radial {
		a := g.angle * math.PI / 180
		dir = {math.sin(a), -math.cos(a)}
		length = abs(lw * dir.x) + abs(lh * dir.y)
	} else {
		lp :: proc(l: ocss.Length, base: f32) -> f32 {return l.unit == .Percent ? base * l.value / 100 + l.offset : l.value}
		cx, cy = lx + lp(g.center[0], lw), ly + lp(g.center[1], lh)
		rx, ry = max(g.radius[0], 0.01), max(g.radius[1], 0.01)
		length = rx
	}
	pos := stop_positions(g, length)
	t_of :: proc(g: ocss.Gradient, p, center, dir: [2]f32, length, cx, cy, rx, ry: f32) -> f32 {
		if !g.radial {
			d := p - center
			return (d.x * dir.x + d.y * dir.y) / length + 0.5
		}
		dx, dy := (p.x - cx) / rx, (p.y - cy) / ry
		return math.sqrt(dx * dx + dy * dy)
	}
	center := [2]f32{lx + lw / 2, ly + lh / 2}
	// axis-aligned linear gradients are exact with one strip per stop; others use a fine grid
	nx, ny := 24, 24
	if !g.radial && !g.repeating && (abs(dir.x) < 1e-4 || abs(dir.y) < 1e-4) {
		if abs(dir.x) < 1e-4 do nx = 1
		if abs(dir.y) < 1e-4 do ny = 1
	}
	xs := make([dynamic]f32, context.temp_allocator)
	ys := make([dynamic]f32, context.temp_allocator)
	for i in 0 ..= nx do append(&xs, x0 + (x1 - x0) * f32(i) / f32(nx))
	for i in 0 ..= ny do append(&ys, y0 + (y1 - y0) * f32(i) / f32(ny))
	// exact stop lines for the axis-aligned case
	if nx == 1 || ny == 1 {
		for p in pos {
			if nx == 1 {
				v := dir.y > 0 ? ly + p * lh : ly + lh - p * lh
				if v > y0 && v < y1 do append(&ys, v)
			} else {
				v := dir.x > 0 ? lx + p * lw : lx + lw - p * lw
				if v > x0 && v < x1 do append(&xs, v)
			}
		}
		sort_f32(xs[:])
		sort_f32(ys[:])
	}
	alpha := clamp(c.alpha, 0, 1)
	verts := make([dynamic]sdl.Vertex, context.temp_allocator)
	idx := make([dynamic]i32, context.temp_allocator)
	W := len(xs)
	for y in ys {
		for x in xs {
			col := gradient_at(g, pos, t_of(g, {x, y}, center, dir, length, cx, cy, rx, ry))
			append(&verts, sdl.Vertex{position = {x, y}, color = {col[0], col[1], col[2], col[3] * alpha}})
		}
	}
	for j in 0 ..< len(ys) - 1 {
		for i in 0 ..< W - 1 {
			a := i32(j * W + i)
			b, cc, d := a + 1, a + i32(W) + 1, a + i32(W)
			append(&idx, a, b, cc, a, cc, d)
		}
	}
	sdl.RenderGeometry(gfx.ren, nil, raw_data(verts), i32(len(verts)), raw_data(idx), i32(len(idx)))
}

@(private = "file")
sort_f32 :: proc(a: []f32) {
	for i in 1 ..< len(a) {
		for j := i; j > 0 && a[j - 1] > a[j]; j -= 1 {
			a[j - 1], a[j] = a[j], a[j - 1]
		}
	}
}

@(private = "file")
upload_glyph_atlas :: proc() {
	pixels, w, h, dirty, changed, resized := glyphs.atlas(glyphs.data)
	if !changed || len(pixels) == 0 do return
	if resized || !tex_valid(glyph_tex) {
		tex_destroy(&glyph_tex)
		glyph_tex = tex_create(w, h, .Linear)
		dirty = {0, 0, w, h}
	}
	dw, dh := dirty[2] - dirty[0], dirty[3] - dirty[1]
	if dw <= 0 || dh <= 0 do return
	buf := make([]Color, dw * dh, context.temp_allocator)
	for y in 0 ..< dh {
		for x in 0 ..< dw {
			buf[y * dw + x] = {255, 255, 255, pixels[(dirty[1] + y) * w + dirty[0] + x]}
		}
	}
	tex_update_rect(glyph_tex, dirty[0], dirty[1], dw, dh, raw_data(buf), dw)
}

@(private = "file")
draw_css_text :: proc(c: olay.Text_Cmd) {
	col := Color(c.color)
	if col.a == 0 do return
	if c.font == ICON_FONT {
		size := i32(math.round(c.size))
		for g in c.glyphs {
			ic := int(g.cp) - ICON_CP0
			if ic < 0 || ic >= len(Icon) do continue
			icon(Icon(ic), i32(math.round(g.x)), i32(math.round(c.y)), col, size)
		}
		return
	}
	s := gfx.scale
	px := c.size * s
	ascent := glyphs.ascent(glyphs.data, c.font, c.size)
	blur := c.blur * s * 0.5
	baseline := math.round((c.y + ascent) * s)
	fc := fcolor(col)
	verts := make([dynamic]sdl.Vertex, context.temp_allocator)
	idx := make([dynamic]i32, context.temp_allocator)
	for g in c.glyphs {
		if g.cp == ' ' || g.cp == '\t' || g.cp == '\n' do continue
		q, ok := glyphs.glyph(glyphs.data, c.font, px, g.cp, blur)
		if !ok do continue
		x := math.round(g.x * s)
		bx0, by0 := (x + q.x0) / s, (baseline + q.y0) / s
		bx1, by1 := (x + q.x1) / s, (baseline + q.y1) / s
		base := i32(len(verts))
		append(&verts, sdl.Vertex{position = {bx0, by0}, color = fc, tex_coord = {q.u0, q.v0}})
		append(&verts, sdl.Vertex{position = {bx1, by0}, color = fc, tex_coord = {q.u1, q.v0}})
		append(&verts, sdl.Vertex{position = {bx1, by1}, color = fc, tex_coord = {q.u1, q.v1}})
		append(&verts, sdl.Vertex{position = {bx0, by1}, color = fc, tex_coord = {q.u0, q.v1}})
		append(&idx, base, base + 1, base + 2, base, base + 2, base + 3)
	}
	if len(verts) == 0 do return
	upload_glyph_atlas()
	sdl.SetTextureColorMod(glyph_tex.t, 255, 255, 255)
	sdl.SetTextureAlphaMod(glyph_tex.t, 255)
	sdl.RenderGeometry(gfx.ren, glyph_tex.t, raw_data(verts), i32(len(verts)), raw_data(idx), i32(len(idx)))
}
