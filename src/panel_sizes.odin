package pangolin

import "core:fmt"
import "core:strconv"
import "core:strings"

import oui "odinui:odinui"

// ---------------------------------------------------------------------------
// Panels the user resizes: drag the edge of the tool bar or a side panel that faces the canvas, or
// the top of the bottom panel (timeline / file browser). Double-click an edge to give the panel its
// theme size back.
//
// A size of 0 is the theme's (assets/ui/theme.css). A dragged size is set on the panel inline, so it
// wins over the theme, and is kept in the preferences. Each size stays between its panel's minimum
// and maximum, and the maximum also shrinks with the window.
//
// Each app builds its tool bar and side panels with panel_element; panel_timeline does the bottom
// panel. Panels the program draws itself (the macro editor's) use panel_width and panel_track_drawn.
// oui_begin_frame runs the edges before anything else sees the pointer, and oui_render
// draws them.
// ---------------------------------------------------------------------------

Panel_Edge :: enum {
	Toolbar,
	Right,
	Font, // Pangolin Scales' glyph panel, font documents only
	Bottom,
	Macro_Nodes, // the macro editor's node list, on its left
	Macro_Side, // the macro editor's settings and document preview, on its right
}

@(private = "file")
Panel_Limit :: struct {
	key:      string, // the preferences key
	min, max: i32, // logical pixels
	frac:     f32, // and never more than this much of the window
}

@(private = "file")
PANEL_LIMITS := [Panel_Edge]Panel_Limit {
	.Toolbar = {"panel_toolbar", 100, 360, 0.3},
	.Right   = {"panel_right", 250, 560, 0.4},
	.Font    = {"panel_font", 220, 560, 0.4},
	.Bottom  = {"panel_bottom", 110, 900, 0.6},
	.Macro_Nodes = {"panel_macro_nodes", 130, 400, 0.3},
	.Macro_Side  = {"panel_macro_side", 200, 600, 0.45},
}

PANEL_CANVAS_MIN :: 200 // dragging a side panel leaves the canvas column at least this wide
PANEL_GRIP :: 3 // an edge can be grabbed this far to either side of it

panel_size: [Panel_Edge]i32 // 0: the theme's size

@(private = "file")
panel_nodes: [Panel_Edge]^oui.Node
@(private = "file")
panel_built: [Panel_Edge]int // the frame the panel was last built in
@(private = "file")
center_node: ^oui.Node // the column the canvas is in (the bottom panel spans it), to tell which side a panel is on
@(private = "file")
center_built: int
@(private = "file")
panel_frame := 1
@(private = "file")
drawn_rect, drawn_canvas: [Panel_Edge]Rect // panels the program draws: where, and the area they give room to

@(private = "file")
Edge :: struct {
	grip, line: Rect, // where it can be grabbed, and the edge itself
	vertical:   bool, // a side panel's edge, dragged left and right
	grow:       i32, // +1: the panel grows as the pointer moves right / down, -1: left / up
	size:       i32, // the panel's size on screen
	room:       i32, // how much it may still grow before the canvas gets too small
}

@(private = "file")
Edge_Drag :: struct {
	on:         bool,
	e:          Panel_Edge,
	from, size: i32, // the pointer and the panel's size when the drag started
	grow, room: i32,
	vertical:   bool,
}

@(private = "file")
edge_drag: Edge_Drag
@(private = "file")
edge_lit: Maybe(Rect) // the edge to highlight this frame

// The smallest and largest the panel can be in a window this size.
panel_limits :: proc(e: Panel_Edge) -> (lo, hi: i32) {
	l := PANEL_LIMITS[e]
	room := e == .Bottom ? ui.h : ui.w
	hi = max(min(l.max, i32(f32(room) * l.frac)), 1)
	lo = min(l.min, hi)
	return
}

// The panel's inline style: its dragged size, or nothing for the theme's.
panel_style :: proc(e: Panel_Edge) -> string {
	if panel_size[e] <= 0 do return ""
	lo, hi := panel_limits(e)
	v := clamp(panel_size[e], lo, hi)
	if e == .Bottom do return fmt.tprintf("height: %dpx; max-height: none", v)
	return fmt.tprintf("width: %dpx; max-width: none", v)
}

// Notes that the panel `n` is up this frame, so its edge can be dragged next frame.
panel_track :: proc(e: Panel_Edge, n: ^oui.Node) {
	panel_nodes[e], panel_built[e] = n, panel_frame
}

// The canvas column, here the bottom panel (which spans it).
panel_track_center :: proc(n: ^oui.Node) {
	center_node, center_built = n, panel_frame
}

// The width of a panel the program draws itself: its dragged width, or `fallback`.
panel_width :: proc(e: Panel_Edge, fallback: i32) -> i32 {
	if panel_size[e] <= 0 do return fallback
	lo, hi := panel_limits(e)
	return clamp(panel_size[e], lo, hi)
}

// Notes that a panel the program draws is at `r` this frame, beside `canvas` (what it gives room to), so its edge
// facing the canvas can be dragged next frame.
panel_track_drawn :: proc(e: Panel_Edge, r, canvas: Rect) {
	panel_nodes[e], panel_built[e] = nil, panel_frame
	drawn_rect[e], drawn_canvas[e] = r, canvas
}

// A resizable panel: an element with id `key`, at its dragged size.
panel_element :: proc(e: Panel_Edge, key, tag: string, class := "", loc := #caller_location) -> ^oui.Node {
	n := oui.element(uictx, key, tag, {id = key, class = class, style = panel_style(e)}, loc)
	panel_track(e, n)
	return n
}

// The panel's draggable edge, if the panel was up last frame.
@(private = "file")
panel_edge :: proc(e: Panel_Edge) -> (edge: Edge, ok: bool) {
	if panel_built[e] != panel_frame do return
	n := panel_nodes[e]
	r := n != nil ? oui_rect(n) : drawn_rect[e]
	if r.w <= 0 || r.h <= 0 do return
	if e == .Bottom {
		edge.line = {r.x, r.y, r.w, 0}
		edge.grip = {r.x, r.y - PANEL_GRIP, r.w, 2 * PANEL_GRIP}
		edge.grow, edge.size = -1, r.h
		edge.room = max(i32(ui.h), r.h) // the theme and panel_limits keep it from taking the window
		return edge, true
	}
	c: Rect
	if n == nil {
		c = drawn_canvas[e]
	} else if center_node != nil && center_built == panel_frame {
		c = oui_rect(center_node)
	}
	if c.w <= 0 do return
	// the edge that faces the canvas: the tool bar may be on either side (#body can be reversed)
	on_left := r.x + r.w <= c.x + 1
	x := on_left ? r.x + r.w : r.x
	edge.vertical = true
	edge.line = {x, r.y, 0, r.h}
	edge.grip = {x - PANEL_GRIP, r.y, 2 * PANEL_GRIP, r.h}
	edge.grow, edge.size = on_left ? 1 : -1, r.w
	edge.room = max(c.w - PANEL_CANVAS_MIN, 0)
	return edge, true
}

// Drags the edges. Runs before the interface and the canvas look at the pointer: while an edge is
// under the pointer or being dragged, they don't get it.
panel_edges_update :: proc() {
	defer panel_frame += 1
	edge_lit = nil
	if edge_drag.on {
		d := &edge_drag
		if !ui.down[0] {
			d.on = false
		} else {
			moved := (d.vertical ? ui.mx : ui.my) - d.from
			lo, hi := panel_limits(d.e)
			hi = min(hi, d.size + d.room)
			panel_size[d.e] = clamp(d.size + moved * d.grow, lo, max(hi, lo))
			if edge, ok := panel_edge(d.e); ok do edge_lit = edge.line
			ui.cursor = d.vertical ? .RESIZE_EW : .RESIZE_NS
			ui.input_layer = OUI_INPUT_LAYER
			return
		}
	}
	// only a free pointer finds an edge: not while a dialog or menu is up, or a button is held
	if ui.input_layer != 0 || ui.down[0] && !ui.pressed[0] || ui.down[1] || ui.down[2] do return
	for e in Panel_Edge {
		edge, ok := panel_edge(e)
		if !ok || !in_rect(edge.grip, ui.mx, ui.my) do continue
		edge_lit = edge.line
		ui.cursor = edge.vertical ? .RESIZE_EW : .RESIZE_NS
		ui.input_layer = OUI_INPUT_LAYER
		tooltip_hover(make_id(edge.grip, "panel-edge"), {"", "Drag to resize this panel. Double-click to give it its usual size."})
		if ui.pressed[0] {
			if ui.dbl_click {
				panel_size[e] = 0
			} else {
				edge_drag = {
					on       = true,
					e        = e,
					from     = edge.vertical ? ui.mx : ui.my,
					size     = edge.size,
					grow     = edge.grow,
					room     = edge.room,
					vertical = edge.vertical,
				}
			}
		}
		return
	}
}

// Highlights the edge under the pointer, or being dragged.
panel_edges_draw :: proc() {
	l, ok := edge_lit.?
	if !ok do return
	if l.w == 0 {
		fill_rect({l.x - 1, l.y, 2, l.h}, C_ACCENT)
	} else {
		fill_rect({l.x, l.y - 1, l.w, 2}, C_ACCENT)
	}
}

panel_sizes_prefs_write :: proc(sb: ^strings.Builder) {
	for e in Panel_Edge {
		if panel_size[e] > 0 do fmt.sbprintf(sb, "%s=%d\n", PANEL_LIMITS[e].key, panel_size[e])
	}
}

// Takes a panel size from the preferences; false if `key` is not one.
panel_sizes_prefs_read :: proc(key, val: string) -> bool {
	for e in Panel_Edge {
		if key != PANEL_LIMITS[e].key do continue
		if v, ok := strconv.parse_int(val); ok do panel_size[e] = i32(clamp(v, 0, 10000))
		return true
	}
	return false
}
