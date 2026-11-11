package pangolin

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// Platform + drawing layer on top of SDL3's renderer.
//
// Everything the rest of the app draws is expressed in logical UI units; `gfx.scale` physical pixels make up one
// logical unit (SDL_SetRenderScale), so layout code never deals with the display resolution. Text is rasterised
// from the embedded Jersey 10 font at the physical size, so it stays sharp at every UI scale.
// ---------------------------------------------------------------------------

Color :: [4]u8

WHITE :: Color{255, 255, 255, 255}
BLACK :: Color{0, 0, 0, 255}
BLANK :: Color{}

FONT_DATA :: #load("../assets/fonts/Jersey10-Regular.ttf")

Texture :: struct {
	t:    ^sdl.Texture,
	w, h: i32,
}

Tex_Filter :: enum {
	Point,
	Linear,
}

MouseCursor :: enum {
	DEFAULT,
	IBEAM,
	CROSSHAIR,
	POINTING_HAND,
	RESIZE_EW,
	RESIZE_NS,
	RESIZE_NWSE,
	RESIZE_NESW,
	RESIZE_ALL,
	NOT_ALLOWED,
	TOOL, // one built from an icon: ui_tool_cursor (cursors.odin) sets it
}

// A cursor made from pixels (gfx_cursor_create).
Cursor_Handle :: distinct rawptr

KeyboardKey :: enum i32 {
	KEY_NULL      = 0,
	SPACE         = 32,
	APOSTROPHE    = 39,
	COMMA         = 44,
	MINUS         = 45,
	PERIOD        = 46,
	SLASH         = 47,
	SEMICOLON     = 59,
	ZERO          = 48,
	ONE,
	TWO,
	THREE,
	FOUR,
	FIVE,
	SIX,
	SEVEN,
	EIGHT,
	NINE,
	EQUAL         = 61,
	A             = 65,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	LEFT_BRACKET  = 91,
	BACKSLASH,
	RIGHT_BRACKET,
	ESCAPE        = 256,
	ENTER         = 257,
	TAB           = 258,
	BACKSPACE     = 259,
	DELETE        = 261,
	RIGHT         = 262,
	LEFT,
	DOWN,
	UP,
	PAGE_UP       = 266,
	PAGE_DOWN     = 267,
	HOME          = 268,
	END           = 269,
	F1            = 290,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	KP_SUBTRACT   = 333,
	KP_ADD,
	KP_ENTER,
	LEFT_SHIFT    = 340,
	LEFT_CONTROL,
	LEFT_ALT,
	RIGHT_SHIFT   = 344,
	RIGHT_CONTROL,
	RIGHT_ALT,
}

MAX_SCANCODES :: 512

Gfx :: struct {
	win:          ^sdl.Window,
	ren:          ^sdl.Renderer,
	scale:        f32, // physical pixels per logical unit
	density:      f32, // window coordinates -> physical pixels
	pw, ph:       i32, // output size in physical pixels
	cursors:      [MouseCursor]^sdl.Cursor,
	cursor_hidden: bool,
	screenshot:   string,
	shot_rect:    [4]int,
	shot_crop:    bool,
	// input, refreshed by gfx_poll()
	key_down:     [MAX_SCANCODES]bool,
	key_pressed:  [MAX_SCANCODES]bool,
	key_repeat:   [MAX_SCANCODES]bool,
	chars:        [dynamic]rune,
	mouse:        Vec2, // physical pixels
	mouse_prev:   Vec2,
	mouse_delta:  Vec2,
	m_down:       [3]bool, // left, right, middle
	m_pressed:    [3]bool,
	m_released:   [3]bool,
	wheel:        Vec2,
	dropped:      [dynamic]string,
	quit:         bool,
	last_ticks:   u64,
	dt:           f32,
	t0:           u64,
}

gfx: Gfx

gfx_error :: proc() -> string {
	return string(sdl.GetError())
}

gfx_init :: proc(title: cstring, shot: bool, force_w := 0, force_h := 0) -> bool {
	sdl.SetHint("SDL_RENDER_VSYNC", "1")
	when ODIN_OS == .Linux {
		// X11 (XWayland on a Wayland desktop) first, as Krita does: SDL's Wayland backend never reports
		// the pen's eraser end. Setting SDL_VIDEO_DRIVER still picks the driver.
		sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "x11,wayland")
	}
	if !sdl.Init({.VIDEO, .EVENTS}) {
		return false
	}
	w, h: i32 = 1280, 800
	x, y: i32 = sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED
	if !shot {
		if dm := sdl.GetDesktopDisplayMode(sdl.GetPrimaryDisplay()); dm != nil {
			w, h = dm.w * 85 / 100, dm.h * 85 / 100
		}
	}
	if force_w > 0 && force_h > 0 {
		w, h = i32(force_w), i32(force_h)
	}
	gfx.win = sdl.CreateWindow(title, w, h, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if gfx.win == nil {
		return false
	}
	_ = x
	_ = y
	sdl.SetWindowPosition(gfx.win, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
	sdl.SetWindowMinimumSize(gfx.win, 900, 560)
	gfx.ren = sdl.CreateRenderer(gfx.win, nil)
	if gfx.ren == nil {
		return false
	}
	sdl.SetRenderVSync(gfx.ren, 1)
	sdl.SetRenderDrawBlendMode(gfx.ren, sdl.BLENDMODE_BLEND)
	_ = sdl.StartTextInput(gfx.win)
	gfx.scale = 1
	gfx.t0 = sdl.GetPerformanceCounter()
	gfx.last_ticks = gfx.t0
	return true
}

gfx_shutdown :: proc() {
	if gfx.ren != nil do sdl.DestroyRenderer(gfx.ren)
	if gfx.win != nil do sdl.DestroyWindow(gfx.win)
	sdl.Quit()
}

gfx_time :: proc() -> f64 {
	return f64(sdl.GetPerformanceCounter() - gfx.t0) / f64(sdl.GetPerformanceFrequency())
}

// The display the window is on now: its size in physical pixels, and the scale set for it in the system's display settings.
gfx_display_info :: proc() -> (width, height: int, system_scale: f32) {
	id := sdl.GetDisplayForWindow(gfx.win)
	if id == 0 do id = sdl.GetPrimaryDisplay()
	width, height = 1920, 1080
	if dm := sdl.GetDesktopDisplayMode(id); dm != nil {
		density := max(dm.pixel_density, 1)
		width, height = int(f32(dm.w) * density), int(f32(dm.h) * density)
	}
	return width, height, sdl.GetDisplayContentScale(id)
}

gfx_set_title :: proc(s: string) {
	sdl.SetWindowTitle(gfx.win, strings.clone_to_cstring(s, context.temp_allocator))
}

// The program's own folder (with a trailing separator).
gfx_app_dir :: proc() -> string {
	return string(sdl.GetBasePath())
}

@(private = "file")
data_dir: string

// Where the user's own files go: settings, workspaces, macros and theme.css (with a trailing separator).
// Next to the program when that folder can be written, so an unzipped folder stays portable; otherwise
// (Program Files, /opt, a read-only mount) the user's data folder: %APPDATA%\Pangolin\<program> on Windows,
// ~/.local/share/Pangolin/<program> on Linux. On macOS always the user's folder,
// ~/Library/Application Support/Pangolin/<program>: files written inside a signed .app break its signature,
// and a downloaded app can be run from a read-only copy.
gfx_data_dir :: proc() -> string {
	if data_dir != "" do return data_dir
	base := gfx_app_dir()
	use_base := ODIN_OS != .Darwin && dir_writable(base)
	if !use_base {
		// the program's file name, without .exe: PangolinPaints
		name := os.args[0]
		if i := strings.last_index_any(name, "/\\"); i >= 0 do name = name[i + 1:]
		name = strings.trim_suffix(name, ".exe")
		name = strings.trim_suffix(name, "-console")
		if name == "" do name = "Pangolin"
		cname := strings.clone_to_cstring(name, context.temp_allocator)
		if p := sdl.GetPrefPath("Pangolin", cname); p != nil {
			data_dir = strings.clone(string(cstring(p)))
			sdl.free(p)
			return data_dir
		}
	}
	data_dir = strings.clone(base)
	return data_dir
}

// Whether files can be made in `dir`: tries one.
@(private = "file")
dir_writable :: proc(dir: string) -> bool {
	probe := fmt.tprintf("%s.pangolin-write-test", dir)
	if os.write_entire_file_from_bytes(probe, {}) != nil do return false
	os.remove(probe)
	return true
}

gfx_hwnd :: proc() -> rawptr {
	props := sdl.GetWindowProperties(gfx.win)
	return sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
}

gfx_set_icon :: proc(pix: []Color, w, h: int) {
	surf := sdl.CreateSurfaceFrom(i32(w), i32(h), .RGBA32, raw_data(pix), i32(w * 4))
	if surf != nil {
		sdl.SetWindowIcon(gfx.win, surf)
		sdl.DestroySurface(surf)
	}
}

// Input ----------------------------------------------------------------------

key_scancode :: proc(k: KeyboardKey) -> sdl.Scancode {
	#partial switch k {
	case .A ..= .Z:
		return sdl.Scancode(int(sdl.Scancode.A) + int(k) - int(KeyboardKey.A))
	case .ONE ..= .NINE:
		return sdl.Scancode(int(sdl.Scancode._1) + int(k) - int(KeyboardKey.ONE))
	case .ZERO:
		return ._0
	case .F1 ..= .F12:
		return sdl.Scancode(int(sdl.Scancode.F1) + int(k) - int(KeyboardKey.F1))
	case .SPACE:
		return .SPACE
	case .APOSTROPHE:
		return .APOSTROPHE
	case .COMMA:
		return .COMMA
	case .PERIOD:
		return .PERIOD
	case .MINUS:
		return .MINUS
	case .SLASH:
		return .SLASH
	case .SEMICOLON:
		return .SEMICOLON
	case .EQUAL:
		return .EQUALS
	case .LEFT_BRACKET:
		return .LEFTBRACKET
	case .BACKSLASH:
		return .BACKSLASH
	case .RIGHT_BRACKET:
		return .RIGHTBRACKET
	case .ESCAPE:
		return .ESCAPE
	case .ENTER:
		return .RETURN
	case .TAB:
		return .TAB
	case .BACKSPACE:
		return .BACKSPACE
	case .DELETE:
		return .DELETE
	case .RIGHT:
		return .RIGHT
	case .LEFT:
		return .LEFT
	case .DOWN:
		return .DOWN
	case .UP:
		return .UP
	case .PAGE_UP:
		return .PAGEUP
	case .PAGE_DOWN:
		return .PAGEDOWN
	case .HOME:
		return .HOME
	case .END:
		return .END
	case .KP_SUBTRACT:
		return .KP_MINUS
	case .KP_ADD:
		return .KP_PLUS
	case .KP_ENTER:
		return .KP_ENTER
	case .LEFT_SHIFT:
		return .LSHIFT
	case .LEFT_CONTROL:
		return .LCTRL
	case .LEFT_ALT:
		return .LALT
	case .RIGHT_SHIFT:
		return .RSHIFT
	case .RIGHT_CONTROL:
		return .RCTRL
	case .RIGHT_ALT:
		return .RALT
	}
	return .UNKNOWN
}

IsKeyDown :: proc(k: KeyboardKey) -> bool {
	return gfx.key_down[key_scancode(k)]
}

IsKeyPressed :: proc(k: KeyboardKey) -> bool {
	return gfx.key_pressed[key_scancode(k)]
}

IsKeyPressedRepeat :: proc(k: KeyboardKey) -> bool {
	return gfx.key_repeat[key_scancode(k)]
}

@(private = "file")
eraser_as_left: bool

mouse_btn_index :: proc(b: u8) -> int {
	switch b {
	case 1:
		return 0
	case 3:
		return 1
	case 2:
		return 2
	}
	return -1
}

// Drains the event queue into `gfx` (call once per frame, first thing).
gfx_poll :: proc() {
	gfx.key_pressed = {}
	gfx.key_repeat = {}
	gfx.m_pressed = {}
	gfx.m_released = {}
	gfx.wheel = {}
	clear(&gfx.chars)
	for s in gfx.dropped do delete(s)
	clear(&gfx.dropped)

	now := sdl.GetPerformanceCounter()
	gfx.dt = f32(f64(now - gfx.last_ticks) / f64(sdl.GetPerformanceFrequency()))
	gfx.last_ticks = now

	gfx.density = max(sdl.GetWindowPixelDensity(gfx.win), 0.01)
	e: sdl.Event
	for sdl.PollEvent(&e) {
		when ODIN_OS != .Windows {
			pen_handle_event(&e)
		}
		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			gfx.quit = true
		case .KEY_DOWN:
			sc := int(e.key.scancode)
			if sc < MAX_SCANCODES {
				if e.key.repeat {
					gfx.key_repeat[sc] = true
				} else {
					gfx.key_pressed[sc] = true
				}
				gfx.key_down[sc] = true
			}
		case .KEY_UP:
			sc := int(e.key.scancode)
			if sc < MAX_SCANCODES do gfx.key_down[sc] = false
		case .WINDOW_FOCUS_LOST:
			gfx.key_down = {}
			gfx.m_down = {}
		case .TEXT_INPUT:
			for r in string(e.text.text) {
				append(&gfx.chars, r)
			}
		case .MOUSE_MOTION:
			gfx.mouse = {e.motion.x, e.motion.y} * gfx.density
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			gfx.mouse = {e.button.x, e.button.y} * gfx.density
			if i := mouse_btn_index(e.button.button); i >= 0 {
				// Windows reports the pen's eraser end as a middle click: treat it as a plain
				// press so it erases instead of panning
				if i == 2 {
					if e.button.down && pen_eraser_active() do eraser_as_left = true
					if eraser_as_left do i = 0
					if !e.button.down do eraser_as_left = false
				}
				if e.button.down {
					gfx.m_down[i] = true
					gfx.m_pressed[i] = true
				} else {
					gfx.m_down[i] = false
					gfx.m_released[i] = true
				}
			}
		case .MOUSE_WHEEL:
			gfx.wheel += {e.wheel.x, e.wheel.y}
		case .DROP_FILE:
			if e.drop.data != nil {
				append(&gfx.dropped, strings.clone(string(e.drop.data)))
			}
		}
	}
	gfx.mouse_delta = gfx.mouse - gfx.mouse_prev
	gfx.mouse_prev = gfx.mouse

	pw, ph: c.int
	sdl.GetRenderOutputSize(gfx.ren, &pw, &ph)
	gfx.pw, gfx.ph = pw, ph
}

gfx_clipboard_get :: proc() -> string {
	p := sdl.GetClipboardText()
	if p == nil do return ""
	defer sdl.free(p)
	return strings.clone(string(cstring(p)), context.temp_allocator)
}

gfx_clipboard_set :: proc(s: string) {
	sdl.SetClipboardText(strings.clone_to_cstring(s, context.temp_allocator))
}

gfx_set_cursor :: proc(c: MouseCursor) {
	c := c
	if c == .TOOL do c = .CROSSHAIR // the tool cursor itself is set with gfx_cursor_set; this is its stand-in
	if gfx.cursors[c] == nil {
		id: sdl.SystemCursor
		switch c {
		case .DEFAULT:
			id = .DEFAULT
		case .IBEAM:
			id = .TEXT
		case .CROSSHAIR:
			id = .CROSSHAIR
		case .POINTING_HAND:
			id = .POINTER
		case .RESIZE_EW:
			id = .EW_RESIZE
		case .RESIZE_NS:
			id = .NS_RESIZE
		case .RESIZE_NWSE:
			id = .NWSE_RESIZE
		case .RESIZE_NESW:
			id = .NESW_RESIZE
		case .RESIZE_ALL:
			id = .MOVE
		case .NOT_ALLOWED:
			id = .NOT_ALLOWED
		case .TOOL:
			id = .CROSSHAIR
		}
		gfx.cursors[c] = sdl.CreateSystemCursor(id)
	}
	_ = sdl.SetCursor(gfx.cursors[c])
}

// A cursor from straight-alpha pixels, `w` x `h`, pointing with the pixel at (hot_x, hot_y). Nil if the system refuses.
gfx_cursor_create :: proc(pix: []Color, w, h, hot_x, hot_y: int) -> Cursor_Handle {
	surf := sdl.CreateSurfaceFrom(i32(w), i32(h), .RGBA32, raw_data(pix), i32(w * 4))
	if surf == nil do return nil
	defer sdl.DestroySurface(surf)
	return Cursor_Handle(sdl.CreateColorCursor(surf, i32(hot_x), i32(hot_y)))
}

// How big the system draws its own cursors, as a multiple of the usual 24 pixels, in the units a cursor's pixels are
// given in. It follows the display's scale setting, not the app's UI scale.
gfx_cursor_scale :: proc() -> f32 {
	id := sdl.GetDisplayForWindow(gfx.win)
	if id == 0 do id = sdl.GetPrimaryDisplay()
	s := sdl.GetDisplayContentScale(id)
	if s <= 0 do s = 1
	// where window coordinates are not physical pixels the system scales the cursor up itself
	return max(s / max(sdl.GetWindowPixelDensity(gfx.win), 1), 1)
}

gfx_cursor_set :: proc(c: Cursor_Handle) {
	_ = sdl.SetCursor((^sdl.Cursor)(c))
}

gfx_cursor_destroy :: proc(c: Cursor_Handle) {
	if c != nil do sdl.DestroyCursor((^sdl.Cursor)(c))
}

gfx_show_cursor :: proc(show: bool) {
	if show {
		_ = sdl.ShowCursor()
	} else {
		_ = sdl.HideCursor()
	}
}

// Frame ----------------------------------------------------------------------

gfx_set_scale :: proc(s: f32) {
	if s != gfx.scale {
		shape_clear_cache()
	}
	gfx.scale = s
	sdl.SetRenderScale(gfx.ren, gfx.scale, gfx.scale)
}

gfx_begin :: proc(bg: Color) {
	sdl.SetRenderTarget(gfx.ren, nil)
	sdl.SetRenderClipRect(gfx.ren, nil)
	sdl.SetRenderDrawColor(gfx.ren, bg.r, bg.g, bg.b, 255)
	sdl.RenderClear(gfx.ren)
}

gfx_present :: proc() {
	if gfx.screenshot != "" {
		surf: ^sdl.Surface
		if gfx.shot_crop {
			rc := sdl.Rect{i32(gfx.shot_rect[0]), i32(gfx.shot_rect[1]), i32(gfx.shot_rect[2]), i32(gfx.shot_rect[3])}
			surf = sdl.RenderReadPixels(gfx.ren, &rc)
		} else {
			surf = sdl.RenderReadPixels(gfx.ren, nil)
		}
		if surf != nil {
			conv := sdl.ConvertSurface(surf, .RGBA32)
			if conv != nil {
				stbi.write_png(strings.clone_to_cstring(gfx.screenshot, context.temp_allocator), conv.w, conv.h, 4, conv.pixels, conv.pitch)
				sdl.DestroySurface(conv)
			}
			sdl.DestroySurface(surf)
		}
		gfx.screenshot = ""
	}
	sdl.RenderPresent(gfx.ren)
	// safety net for drivers that ignore vsync (occluded windows, remote sessions): never spin faster than ~144 fps
	freq := sdl.GetPerformanceFrequency()
	spent := sdl.GetPerformanceCounter() - gfx.last_ticks
	if min_ticks := freq / 144; spent < min_ticks {
		sdl.DelayNS((min_ticks - spent) * 1_000_000_000 / freq)
	}
}

// Clipping takes logical coordinates.
clip_set :: proc(x, y, w, h: i32) {
	// SDL applies the render scale to the clip rectangle, so logical units go in unchanged
	r := sdl.Rect{x, y, max(w, 0), max(h, 0)}
	sdl.SetRenderClipRect(gfx.ren, &r)
}

clip_clear :: proc() {
	sdl.SetRenderClipRect(gfx.ren, nil)
}

// Primitives (logical units) -------------------------------------------------

set_draw_color :: #force_inline proc(c: Color) {
	sdl.SetRenderDrawColor(gfx.ren, c.r, c.g, c.b, c.a)
}

// A box with its edges on whole physical pixels, at least one pixel wide and tall, so edges stay crisp and
// hairlines show at fractional UI scales.
snap_box :: proc(x, y, w, h: f32) -> (sx, sy, sw, sh: f32) {
	s := gfx.scale
	x0, y0 := math.round(x * s), math.round(y * s)
	x1, y1 := math.round((x + w) * s), math.round((y + h) * s)
	if w > 0 do x1 = max(x1, x0 + 1)
	if h > 0 do y1 = max(y1, y0 + 1)
	return x0 / s, y0 / s, (x1 - x0) / s, (y1 - y0) / s
}

draw_rect :: proc(x, y, w, h: f32, c: Color) {
	if c.a == 0 || w <= 0 || h <= 0 do return
	set_draw_color(c)
	sx, sy, sw, sh := snap_box(x, y, w, h)
	r := sdl.FRect{sx, sy, sw, sh}
	sdl.RenderFillRect(gfx.ren, &r)
}

// One physical pixel, in logical units: hairlines stay thin at every UI scale.
hair :: #force_inline proc() -> f32 {
	return 1 / gfx.scale
}

draw_line :: proc(a, b: Vec2, c: Color) {
	set_draw_color(c)
	sdl.RenderLine(gfx.ren, a.x, a.y, b.x, b.y)
}

fcolor :: #force_inline proc(c: Color) -> sdl.FColor {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

// Vertical (top -> bottom) or horizontal (left -> right) two-colour gradient.
draw_gradient :: proc(x, y, w, h: f32, c0, c1: Color, vertical := true) {
	a, b := fcolor(c0), fcolor(c1)
	v := [4]sdl.Vertex {
		{position = {x, y}, color = a},
		{position = {x + w, y}, color = vertical ? a : b},
		{position = {x + w, y + h}, color = b},
		{position = {x, y + h}, color = vertical ? b : a},
	}
	idx := [6]c.int{0, 1, 2, 0, 2, 3}
	sdl.RenderGeometry(gfx.ren, nil, &v[0], 4, &idx[0], 6)
}

// Textures -------------------------------------------------------------------

tex_create :: proc(w, h: int, filter := Tex_Filter.Point) -> Texture {
	t := sdl.CreateTexture(gfx.ren, .RGBA32, .STATIC, i32(w), i32(h))
	sdl.SetTextureBlendMode(t, sdl.BLENDMODE_BLEND)
	sdl.SetTextureScaleMode(t, filter == .Point ? .NEAREST : .LINEAR)
	return Texture{t, i32(w), i32(h)}
}

tex_from_pixels :: proc(pix: []Color, w, h: int, filter := Tex_Filter.Point) -> Texture {
	t := tex_create(w, h, filter)
	sdl.UpdateTexture(t.t, nil, raw_data(pix), i32(w * 4))
	return t
}

tex_valid :: proc(t: Texture) -> bool {
	return t.t != nil
}

tex_destroy :: proc(t: ^Texture) {
	if t.t != nil do sdl.DestroyTexture(t.t)
	t^ = {}
}

tex_set_filter :: proc(t: Texture, f: Tex_Filter) {
	sdl.SetTextureScaleMode(t.t, f == .Point ? .NEAREST : .LINEAR)
}

// Upload `pix` (a w*h buffer) to the whole texture.
tex_update :: proc(t: Texture, pix: []Color) {
	sdl.UpdateTexture(t.t, nil, raw_data(pix), t.w * 4)
}

// Upload a sub-rectangle; `pix` starts at the rectangle's first pixel and rows are `stride` pixels apart.
tex_update_rect :: proc(t: Texture, x, y, w, h: int, pix: [^]Color, stride: int) {
	r := sdl.Rect{i32(x), i32(y), i32(w), i32(h)}
	sdl.UpdateTexture(t.t, &r, pix, i32(stride * 4))
}

draw_tex :: proc(t: Texture, src: sdl.FRect, dst: sdl.FRect, tint := WHITE) {
	sdl.SetTextureColorMod(t.t, tint.r, tint.g, tint.b)
	sdl.SetTextureAlphaMod(t.t, tint.a)
	s := src
	d: sdl.FRect
	d.x, d.y, d.w, d.h = snap_box(dst.x, dst.y, dst.w, dst.h)
	sdl.RenderTexture(gfx.ren, t.t, &s, &d)
}

// A texture tiled over `dst` (each repeat is `cell` logical units wide and tall).
draw_tex_tiled :: proc(t: Texture, dst: sdl.FRect, cell: f32) {
	sdl.SetTextureColorMod(t.t, 255, 255, 255)
	sdl.SetTextureAlphaMod(t.t, 255)
	u, v := dst.w / cell, dst.h / cell
	col := sdl.FColor{1, 1, 1, 1}
	vs := [4]sdl.Vertex {
		{position = {dst.x, dst.y}, color = col, tex_coord = {0, 0}},
		{position = {dst.x + dst.w, dst.y}, color = col, tex_coord = {u, 0}},
		{position = {dst.x + dst.w, dst.y + dst.h}, color = col, tex_coord = {u, v}},
		{position = {dst.x, dst.y + dst.h}, color = col, tex_coord = {0, v}},
	}
	idx := [6]c.int{0, 1, 2, 0, 2, 3}
	sdl.SetRenderTextureAddressMode(gfx.ren, .WRAP, .WRAP)
	sdl.RenderGeometry(gfx.ren, t.t, &vs[0], 4, &idx[0], 6)
	sdl.SetRenderTextureAddressMode(gfx.ren, .CLAMP, .CLAMP)
}

// Anti-aliased rounded shapes (9-slice from cached corner textures) -----------

Shape_Kind :: enum u8 {
	Fill,
	Ring,
	Shadow,
}

Shape_Key :: struct {
	kind: Shape_Kind,
	r, t: i32, // radius, ring thickness / blur (physical pixels)
}

shape_cache: map[Shape_Key]Texture

shape_clear_cache :: proc() {
	for _, &t in shape_cache {
		tex_destroy(&t)
	}
	clear(&shape_cache)
}

// Coverage of a rounded square of half-size `h` and corner radius `r` at pixel centre (px, py).
@(private = "file")
rr_cover :: proc(px, py, h, r: f32) -> f32 {
	qx := abs(px - h) - (h - r)
	qy := abs(py - h) - (h - r)
	dx, dy := max(qx, 0), max(qy, 0)
	d := math.sqrt(dx * dx + dy * dy) + min(max(qx, qy), 0) - r
	return clamp(0.5 - d, 0, 1)
}

shape_texture :: proc(key: Shape_Key) -> Texture {
	if t, ok := shape_cache[key]; ok {
		return t
	}
	r := key.r
	size: int
	pix: []Color
	switch key.kind {
	case .Fill, .Ring:
		size = int(max(r, 1)) * 2
		pix = make([]Color, size * size, context.temp_allocator)
		h := f32(size) / 2
		rf := f32(max(r, 1))
		for y in 0 ..< size {
			for x in 0 ..< size {
				a := rr_cover(f32(x) + 0.5, f32(y) + 0.5, h, rf)
				if key.kind == .Ring {
					a -= rr_cover(f32(x) + 0.5 - f32(key.t), f32(y) + 0.5 - f32(key.t), h - f32(key.t), max(rf - f32(key.t), 0))
					a = clamp(a, 0, 1)
				}
				pix[y * size + x] = {255, 255, 255, u8(a * 255 + 0.5)}
			}
		}
	case .Shadow:
		// rounded square blurred with a box filter run three times (a decent gaussian)
		bl := int(key.t)
		core := int(max(r, 2)) * 2 + 2
		size = core + bl * 4
		mask := make([]f32, size * size, context.temp_allocator)
		tmp := make([]f32, size * size, context.temp_allocator)
		h := f32(core) / 2
		for y in 0 ..< core {
			for x in 0 ..< core {
				mask[(y + bl * 2) * size + x + bl * 2] = rr_cover(f32(x) + 0.5, f32(y) + 0.5, h, f32(max(r, 1)))
			}
		}
		rad := max(bl / 3, 1)
		for _ in 0 ..< 3 {
			for y in 0 ..< size {
				for x in 0 ..< size {
					s: f32
					for k in -rad ..= rad {
						xx := clamp(x + k, 0, size - 1)
						s += mask[y * size + xx]
					}
					tmp[y * size + x] = s / f32(2 * rad + 1)
				}
			}
			for y in 0 ..< size {
				for x in 0 ..< size {
					s: f32
					for k in -rad ..= rad {
						yy := clamp(y + k, 0, size - 1)
						s += tmp[yy * size + x]
					}
					mask[y * size + x] = s / f32(2 * rad + 1)
				}
			}
		}
		pix = make([]Color, size * size, context.temp_allocator)
		for i in 0 ..< size * size {
			pix[i] = {255, 255, 255, u8(clamp(mask[i], 0, 1) * 255 + 0.5)}
		}
	}
	t := tex_from_pixels(pix, size, size, .Point)
	shape_cache[key] = t
	return t
}

// Snap a logical coordinate to a whole physical pixel.
snap :: #force_inline proc(v: f32) -> f32 {
	return math.round(v * gfx.scale) / gfx.scale
}

// A logical size in whole physical pixels, for textures rendered at the screen's resolution.
phys_size :: proc(size: i32) -> i32 {
	return i32(math.round(f32(size) * gfx.scale))
}

// Part of a texture, texel for physical pixel: stays crisp at fractional UI scales.
draw_tex_exact :: proc(t: Texture, src: sdl.FRect, x, y: f32, tint := WHITE) {
	draw_tex(t, src, {snap(x), snap(y), src.w / gfx.scale, src.h / gfx.scale}, tint)
}

// A corner radius in whole physical pixels that fits a box already snapped to them.
rrect_radius :: proc(w, h, radius: f32) -> i32 {
	s := gfx.scale
	return i32(min(math.round(radius * s), math.floor(math.round(min(w, h) * s) / 2)))
}

draw_rrect :: proc(x_in, y_in, w_in, h_in, radius: f32, c: Color) {
	if c.a == 0 || w_in <= 0 || h_in <= 0 do return
	s := gfx.scale
	x, y, w, h := snap_box(x_in, y_in, w_in, h_in)
	R := rrect_radius(w, h, radius)
	if R <= 0 {
		draw_rect(x, y, w, h, c)
		return
	}
	t := shape_texture({.Fill, R, 0})
	rr := f32(R) / s
	quad_nine(t, x, y, w, h, rr, c)
}

// Border `th` physical pixels thick.
draw_rrect_outline :: proc(x_in, y_in, w_in, h_in, radius: f32, c: Color, th: i32 = 1) {
	if c.a == 0 || w_in <= 0 || h_in <= 0 do return
	s := gfx.scale
	x, y, w, h := snap_box(x_in, y_in, w_in, h_in)
	R := rrect_radius(w, h, radius)
	tt := f32(th) / s
	if R <= 0 {
		draw_rect(x, y, w, tt, c)
		draw_rect(x, y + h - tt, w, tt, c)
		draw_rect(x, y + tt, tt, h - 2 * tt, c)
		draw_rect(x + w - tt, y + tt, tt, h - 2 * tt, c)
		return
	}
	t := shape_texture({.Ring, R, th})
	rr := f32(R) / s
	// corners
	src_c := f32(R)
	sdl.SetTextureColorMod(t.t, c.r, c.g, c.b)
	sdl.SetTextureAlphaMod(t.t, c.a)
	corner :: proc(t: Texture, sx, sy, sz: f32, dx, dy, dsz: f32) {
		src := sdl.FRect{sx, sy, sz, sz}
		dst := sdl.FRect{dx, dy, dsz, dsz}
		sdl.RenderTexture(gfx.ren, t.t, &src, &dst)
	}
	corner(t, 0, 0, src_c, x, y, rr)
	corner(t, src_c, 0, src_c, x + w - rr, y, rr)
	corner(t, 0, src_c, src_c, x, y + h - rr, rr)
	corner(t, src_c, src_c, src_c, x + w - rr, y + h - rr, rr)
	draw_rect(x + rr, y, w - 2 * rr, tt, c)
	draw_rect(x + rr, y + h - tt, w - 2 * rr, tt, c)
	draw_rect(x, y + rr, tt, h - 2 * rr, c)
	draw_rect(x + w - tt, y + rr, tt, h - 2 * rr, c)
}

@(private = "file")
quad_nine :: proc(t: Texture, x, y, w, h, rr: f32, c: Color) {
	sdl.SetTextureColorMod(t.t, c.r, c.g, c.b)
	sdl.SetTextureAlphaMod(t.t, c.a)
	half := f32(t.w) / 2
	corner :: proc(t: Texture, sx, sy, sz: f32, dx, dy, dsz: f32) {
		src := sdl.FRect{sx, sy, sz, sz}
		dst := sdl.FRect{dx, dy, dsz, dsz}
		sdl.RenderTexture(gfx.ren, t.t, &src, &dst)
	}
	corner(t, 0, 0, half, x, y, rr)
	corner(t, half, 0, half, x + w - rr, y, rr)
	corner(t, 0, half, half, x, y + h - rr, rr)
	corner(t, half, half, half, x + w - rr, y + h - rr, rr)
	draw_rect(x + rr, y, w - 2 * rr, rr, c)
	draw_rect(x + rr, y + h - rr, w - 2 * rr, rr, c)
	draw_rect(x, y + rr, w, h - 2 * rr, c)
}

// Soft drop shadow behind a rounded rectangle; `blur` and `radius` in logical units.
draw_shadow :: proc(x, y, w, h, radius, blur: f32, c: Color) {
	if c.a == 0 do return
	s := gfx.scale
	R := i32(math.round(radius * s))
	B := max(i32(math.round(blur * s)), 1)
	t := shape_texture({.Shadow, R, B})
	sdl.SetTextureColorMod(t.t, c.r, c.g, c.b)
	sdl.SetTextureAlphaMod(t.t, c.a)
	core := f32(max(R, 2) * 2 + 2)
	pad := f32(B) * 2 // transparent margin baked into the texture
	cs := f32(max(R, 2)) + pad // size of one corner patch (the 2 px between them stretch)
	cs_l := cs / s
	pad_l := pad / s
	// outer rect of the shadow (shape plus its blur margin)
	ox, oy, ow, oh := x - pad_l, y - pad_l, w + 2 * pad_l, h + 2 * pad_l
	slice :: proc(t: Texture, sx, sy, sw, sh, dx, dy, dw, dh: f32) {
		if dw <= 0 || dh <= 0 do return
		src := sdl.FRect{sx, sy, sw, sh}
		dst := sdl.FRect{dx, dy, dw, dh}
		sdl.RenderTexture(gfx.ren, t.t, &src, &dst)
	}
	tw := f32(t.w)
	mw := tw - 2 * cs // middle strip in the texture (may be 0)
	slice(t, 0, 0, cs, cs, ox, oy, cs_l, cs_l)
	slice(t, tw - cs, 0, cs, cs, ox + ow - cs_l, oy, cs_l, cs_l)
	slice(t, 0, tw - cs, cs, cs, ox, oy + oh - cs_l, cs_l, cs_l)
	slice(t, tw - cs, tw - cs, cs, cs, ox + ow - cs_l, oy + oh - cs_l, cs_l, cs_l)
	if mw > 0 {
		slice(t, cs, 0, mw, cs, ox + cs_l, oy, ow - 2 * cs_l, cs_l)
		slice(t, cs, tw - cs, mw, cs, ox + cs_l, oy + oh - cs_l, ow - 2 * cs_l, cs_l)
		slice(t, 0, cs, cs, mw, ox, oy + cs_l, cs_l, oh - 2 * cs_l)
		slice(t, tw - cs, cs, cs, mw, ox + ow - cs_l, oy + cs_l, cs_l, oh - 2 * cs_l)
		slice(t, cs, cs, mw, mw, ox + cs_l, oy + cs_l, ow - 2 * cs_l, oh - 2 * cs_l)
	}
}

// Text -----------------------------------------------------------------------

Glyph :: struct {
	x, y, w, h: i32, // atlas rectangle
	ox, oy:     i32, // offset from the pen position / baseline (physical)
	adv:        f32, // physical pixels
}

Font_Inst :: struct {
	size:    i32, // logical size
	phys:    f32, // physical size (size * scale)
	sc:      f32, // stb scale
	cap:     i32, // cap height, physical
	asc:     i32,
	atlas:   ^sdl.Texture,
	aw:      i32,
	cx, cy:  i32,
	row_h:   i32,
	glyphs:  map[rune]Glyph,
}

font_info: stbtt.fontinfo
font_ready: bool
fonts: [dynamic]^Font_Inst

FONT_ATLAS :: 1024

font_init :: proc() {
	stbtt.InitFont(&font_info, raw_data(FONT_DATA), 0)
	font_ready = true
}

font_reset :: proc() {
	for f in fonts {
		if f.atlas != nil do sdl.DestroyTexture(f.atlas)
		delete(f.glyphs)
		free(f)
	}
	clear(&fonts)
}

font_get :: proc(size: i32) -> ^Font_Inst {
	if !font_ready do font_init()
	for f in fonts {
		if f.size == size {
			if f.phys == f32(size) * gfx.scale do return f
			// the UI scale changed: rebuild every instance
			font_reset()
			break
		}
	}
	f := new(Font_Inst)
	f.size = size
	f.phys = f32(size) * gfx.scale
	f.sc = stbtt.ScaleForMappingEmToPixels(&font_info, f.phys)
	a, d, g: c.int
	stbtt.GetFontVMetrics(&font_info, &a, &d, &g)
	f.asc = i32(math.round(f32(a) * f.sc))
	x0, y0, x1, y1: c.int
	stbtt.GetCodepointBitmapBox(&font_info, 'H', f.sc, f.sc, &x0, &y0, &x1, &y1)
	f.cap = -y0
	f.aw = FONT_ATLAS
	f.atlas = sdl.CreateTexture(gfx.ren, .RGBA32, .STATIC, FONT_ATLAS, FONT_ATLAS)
	sdl.SetTextureBlendMode(f.atlas, sdl.BLENDMODE_BLEND)
	sdl.SetTextureScaleMode(f.atlas, .NEAREST)
	blank := make([]u8, FONT_ATLAS * FONT_ATLAS * 4, context.temp_allocator)
	sdl.UpdateTexture(f.atlas, nil, raw_data(blank), FONT_ATLAS * 4)
	append(&fonts, f)
	return f
}

// Rasterise a glyph to an 8-bit coverage bitmap.
glyph_bitmap :: proc(sc: f32, r: rune, allocator := context.temp_allocator) -> (bm: []u8, w, h, ox, oy: i32, adv: f32) {
	x0, y0, x1, y1: c.int
	stbtt.GetCodepointBitmapBox(&font_info, r, sc, sc, &x0, &y0, &x1, &y1)
	w, h = x1 - x0, y1 - y0
	ox, oy = x0, y0
	ad, lsb: c.int
	stbtt.GetCodepointHMetrics(&font_info, r, &ad, &lsb)
	adv = math.round(f32(ad) * sc)
	if w > 0 && h > 0 {
		bm = make([]u8, int(w * h), allocator)
		stbtt.MakeCodepointBitmap(&font_info, raw_data(bm), w, h, w, sc, sc, r)
	}
	return
}

font_glyph :: proc(f: ^Font_Inst, r: rune) -> Glyph {
	if g, ok := f.glyphs[r]; ok {
		return g
	}
	bm, w, h, ox, oy, adv := glyph_bitmap(f.sc, r)
	g := Glyph {
		ox  = ox,
		oy  = oy,
		adv = adv,
	}
	if w > 0 && h > 0 {
		if f.cx + w + 1 > f.aw {
			f.cx = 0
			f.cy += f.row_h + 1
			f.row_h = 0
		}
		if f.cy + h + 1 > f.aw {
			// atlas full: start over (glyphs are re-rasterised on demand)
			clear(&f.glyphs)
			f.cx, f.cy, f.row_h = 0, 0, 0
		}
		rgba := make([]Color, int(w * h), context.temp_allocator)
		for i in 0 ..< int(w * h) {
			rgba[i] = {255, 255, 255, bm[i]}
		}
		rc := sdl.Rect{f.cx, f.cy, w, h}
		sdl.UpdateTexture(f.atlas, &rc, raw_data(rgba), w * 4)
		g.x, g.y, g.w, g.h = f.cx, f.cy, w, h
		f.cx += w + 1
		f.row_h = max(f.row_h, h)
	}
	f.glyphs[r] = g
	return g
}

// Width of `s` in logical units.
text_width :: proc(s: string, size: i32 = FONT_SIZE) -> f32 {
	f := font_get(size)
	w: f32
	for r in s {
		w += font_glyph(f, r).adv
	}
	return w / gfx.scale
}

// Cap height in logical units (the vertical extent of capital letters).
text_cap :: proc(size: i32 = FONT_SIZE) -> f32 {
	return f32(font_get(size).cap) / gfx.scale
}

// Draws `s` with the top of the capital letters at y.
draw_text :: proc(x, y: f32, s: string, c: Color, size: i32 = FONT_SIZE) {
	if len(s) == 0 || c.a == 0 do return
	f := font_get(size)
	sc := gfx.scale
	pen := math.round(x * sc)
	base := math.round(y * sc) + f32(f.cap)
	sdl.SetTextureColorMod(f.atlas, c.r, c.g, c.b)
	sdl.SetTextureAlphaMod(f.atlas, c.a)
	for r in s {
		g := font_glyph(f, r)
		if g.w > 0 {
			src := sdl.FRect{f32(g.x), f32(g.y), f32(g.w), f32(g.h)}
			dst := sdl.FRect{(pen + f32(g.ox)) / sc, (base + f32(g.oy)) / sc, f32(g.w) / sc, f32(g.h) / sc}
			sdl.RenderTexture(gfx.ren, f.atlas, &src, &dst)
		}
		pen += g.adv
	}
}

// Draws text into a CPU pixel buffer (used by the brush-sheet export); `px` is the em size in pixels.
image_draw_text :: proc(pix: []Color, w, h: int, x, y: int, s: string, px: f32, c: Color) {
	if !font_ready do font_init()
	sc := stbtt.ScaleForMappingEmToPixels(&font_info, px)
	x0, y0, x1, y1: i32
	stbtt.GetCodepointBitmapBox(&font_info, 'H', sc, sc, &x0, &y0, &x1, &y1)
	base := y + int(-y0)
	pen := x
	for r in s {
		bm, gw, gh, ox, oy, adv := glyph_bitmap(sc, r)
		for yy in 0 ..< int(gh) {
			for xx in 0 ..< int(gw) {
				a := bm[yy * int(gw) + xx]
				px_x, px_y := pen + int(ox) + xx, base + int(oy) + yy
				if a == 0 || px_x < 0 || px_y < 0 || px_x >= w || px_y >= h do continue
				d := &pix[px_y * w + px_x]
				k := f32(a) / 255
				for ch in 0 ..< 3 {
					d[ch] = u8(f32(d[ch]) * (1 - k) + f32(c[ch]) * k + 0.5)
				}
			}
		}
		pen += int(adv)
	}
}

// Image files -----------------------------------------------------------------

// Decode any format stb_image knows (PNG, BMP, GIF, TGA, ...) into RGBA8.
stb_decode :: proc(data: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	iw, ih, ch: c.int
	p := stbi.load_from_memory(raw_data(data), c.int(len(data)), &iw, &ih, &ch, 4)
	if p == nil || iw <= 0 || ih <= 0 {
		return
	}
	defer stbi.image_free(p)
	w, h = int(iw), int(ih)
	pix = make([]Color, w * h)
	copy(pix, ([^]Color)(p)[:w * h])
	ok = true
	return
}

@(private = "file")
png_sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	context = runtime.default_context()
	b := (^[dynamic]u8)(ctx)
	append(b, ..([^]u8)(data)[:size])
}

encode_png :: proc(pix: []Color, w, h: int) -> []u8 {
	buf := make([dynamic]u8, context.temp_allocator)
	if stbi.write_png_to_func(png_sink, &buf, c.int(w), c.int(h), 4, raw_data(pix), c.int(w * 4)) == 0 {
		return nil
	}
	return buf[:]
}

// Small drawing conveniences -----------------------------------------------------

FRect :: sdl.FRect

draw_frect :: proc(r: FRect, c: Color) {
	draw_rect(r.x, r.y, r.w, r.h, c)
}

// One physical pixel wide outline of a float rectangle.
draw_rect_outline :: proc(r: FRect, c: Color) {
	t := hair()
	draw_rect(r.x, r.y, r.w, t, c)
	draw_rect(r.x, r.y + r.h - t, r.w, t, c)
	draw_rect(r.x, r.y + t, t, r.h - 2 * t, c)
	draw_rect(r.x + r.w - t, r.y + t, t, r.h - 2 * t, c)
}

draw_line_i :: proc(x0, y0, x1, y1: i32, c: Color) {
	draw_line({f32(x0), f32(y0)}, {f32(x1), f32(y1)}, c)
}

draw_tex_at :: proc(t: Texture, x, y: i32, tint := WHITE) {
	draw_tex(t, {0, 0, f32(t.w), f32(t.h)}, {f32(x), f32(y), f32(t.w), f32(t.h)}, tint)
}

draw_circle_outline :: proc(cx, cy, r: f32, c: Color) {
	n := clamp(int(r * gfx.scale * 2), 12, 96)
	pts := make([]sdl.FPoint, n + 1, context.temp_allocator)
	for i in 0 ..= n {
		a := f32(i) / f32(n) * math.TAU
		pts[i] = {cx + math.cos(a) * r, cy + math.sin(a) * r}
	}
	set_draw_color(c)
	sdl.RenderLines(gfx.ren, raw_data(pts), i32(n + 1))
}

// A line `w` logical pixels wide (a quad, so it keeps its width at every UI scale).
draw_thick_line :: proc(a, b: Vec2, w: f32, color: Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.001 do return
	n := Vec2{-d.y, d.x} * (w / 2 / l)
	col := fcolor(color)
	v := [4]sdl.Vertex{{position = sdl.FPoint(a + n), color = col}, {position = sdl.FPoint(b + n), color = col}, {position = sdl.FPoint(b - n), color = col}, {position = sdl.FPoint(a - n), color = col}}
	idx := [6]c.int{0, 1, 2, 0, 2, 3}
	sdl.RenderGeometry(gfx.ren, nil, &v[0], 4, &idx[0], 6)
}

// A cubic Bezier curve from `a` to `b` with control points `ca` and `cb`, `w` logical pixels wide.
draw_bezier :: proc(a, ca, cb, b: Vec2, w: f32, color: Color) {
	steps := clamp(int((abs(b.x - a.x) + abs(b.y - a.y)) / 8), 8, 48)
	prev := a
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		u := 1 - t
		p := a * (u * u * u) + ca * (3 * u * u * t) + cb * (3 * u * t * t) + b * (t * t * t)
		draw_thick_line(prev, p, w, color)
		// fill the joint so a bend has no notch
		if i < steps do draw_dot(p, w / 2, color)
		prev = p
	}
}

// A filled circle.
draw_dot :: proc(p: Vec2, r: f32, color: Color) {
	n := clamp(int(r * gfx.scale * 1.5), 8, 48)
	col := fcolor(color)
	vs := make([]sdl.Vertex, n + 1, context.temp_allocator)
	idx := make([]c.int, n * 3, context.temp_allocator)
	vs[0] = {position = sdl.FPoint(p), color = col}
	for i in 0 ..< n {
		a := f32(i) / f32(n) * math.TAU
		vs[i + 1] = {position = sdl.FPoint(p + Vec2{math.cos(a), math.sin(a)} * r), color = col}
		idx[i * 3], idx[i * 3 + 1], idx[i * 3 + 2] = 0, c.int(i + 1), c.int((i + 1) % n + 1)
	}
	sdl.RenderGeometry(gfx.ren, nil, raw_data(vs), c.int(n + 1), raw_data(idx), c.int(n * 3))
}

// Native dialogs swallow the key / button releases that happen while they are open.
gfx_reset_input :: proc() {
	gfx.key_down = {}
	gfx.key_pressed = {}
	gfx.m_down = {}
	gfx.m_pressed = {}
}
