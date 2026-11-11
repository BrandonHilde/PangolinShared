package pangolin

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// The node editor, in the style of ComfyUI: macros are built as graphs of nodes on a canvas that pans and zooms.
//
//   - The Document wire (white) runs from Start through the action nodes, in the order they run. Drag a second wire
//     out of a node to start a branch: branches run top to bottom (numbered on the canvas), each from the document as
//     it was where the wire splits. Branch 1 keeps its changes; the others are side trips (exports) that are put back.
//   - Every setting is a widget on its node, with a socket on the left: wire a value node's output into it and the
//     setting takes the wired value instead.
//   - Drag from a socket to connect; drop a wire on empty canvas to pick a node that fits it. Drag a wire off an input
//     to move or remove it. Start typing on the canvas (or double-click it, or press Tab) to find a node: the search
//     also offers nodes with one of their choices already picked, so "soft light" finds Layer Blend Mode set to it.
//   - Drag empty canvas, or with the middle button, to pan; the wheel zooms. Ctrl-drag selects with a box.
//   - Widgets are on the nodes at 100%; zoomed out, the panel on the right edits the selected node.
//
// The app shows it with `macro_editor_ui(r)` in place of its canvas while `macro_editor_on()`, and leaves the keyboard
// to it then. The graph being edited is a copy: Save (or closing, or picking another macro) writes it to the library.

ME_NODE_W :: 210
ME_HEAD_H :: 20
ME_ROW_H :: 20
ME_PORT_R :: 4.5
ME_LIB_W :: 180
ME_SIDE_W :: 230
ME_BAR_H :: 26
ME_SEARCH_W :: 300
ME_SEARCH_ROWS :: 14
ME_LABEL_W :: 0 // widgets show their own label
ME_CURVE_ROWS :: 7 // rows a curve takes on its node
ME_SCROLL_W :: 6 // the side panel's scroll bar
ME_LINE_H :: 14 // a line of text on a node (the Start node's "Where this applies")

Me_Drag :: enum {
	None,
	Pan,
	Nodes,
	Wire,
	Box,
}

// A socket: a node's Document input or output (`key` ""), its value output (`out`, key "out"), or a setting's input.
Me_Port :: struct {
	node: int,
	out:  bool,
	key:  string,
}

Macro_Editor :: struct {
	open:         bool,
	m:            ^Macro, // the graph being edited
	lib_name:     Name, // the macro it was loaded from; empty: not saved yet
	name:         Name, // the name field
	dirty:        bool,
	pan:          Vec2, // graph position at the canvas's top left
	zoom:         f32,
	origin:       Vec2, // the canvas's top left on screen
	canvas:       Rect,
	sel:          [dynamic]int,
	drag:         Me_Drag,
	drag_from:    Vec2, // where the drag started (screen)
	drag_prev:    Vec2,
	wire:         Me_Port, // the socket a wire is being dragged from
	search:       bool,
	search_at:    Vec2, // where the new node goes (graph)
	search_text:  Name,
	search_pick:  int,
	search_focus: bool,
	search_wire:  bool, // the new node gets connected to `wire`
	lib_filter:   Name,
	lib_scroll:   i32,
	side_scroll:  i32,
	side_h:       i32, // how tall the selected node's settings are, for scrolling
	msg:          Name,
	msg_bad:      bool,
	err_node:     int,
	edit_buf:     Name, // the text being typed into a node's field
	edit_node:    int,
	edit_key:     string,
	fit:          bool, // frame the whole graph once the canvas size is known
	curve_id:     u32, // the curve whose point is being dragged
	curve_pt:     int,
}

me: Macro_Editor

macro_editor_on :: proc() -> bool {
	return me.open
}

// Opens the editor on the named macro, or on a new one with "".
macro_editor_open :: proc(name := "") {
	me.open = true
	if me.zoom == 0 do me.zoom = 1
	m := macro_find(name)
	if m != nil {
		me_load(m)
	} else if me.m == nil {
		me_new()
	}
}

macro_editor_close :: proc() {
	if !me.open do return
	me_autosave()
	me.open = false
	me.search = false
	me.drag = .None
	ui.focus_id = 0
}

@(private = "file")
me_set_msg :: proc(bad: bool, format: string, args: ..any) {
	name_set(&me.msg, fmt.tprintf(format, ..args))
	me.msg_bad = bad
}

@(private = "file")
me_reset_view :: proc() {
	me.pan, me.zoom = {-40, -60}, 1
	clear(&me.sel)
	me.err_node = 0
	me.search = false
	me.drag = .None
	me.edit_node = 0
	me.fit = true
}

@(private = "file")
me_load :: proc(m: ^Macro) {
	me_autosave()
	macro_free(me.m)
	me.m = macro_clone(m)
	name_set(&me.lib_name, m.name)
	name_set(&me.name, m.name)
	me.dirty = false
	me_reset_view()
	me_set_msg(false, "Editing %s", m.name)
}

@(private = "file")
me_new :: proc() {
	me_autosave()
	macro_free(me.m)
	me.m = macro_new("New macro")
	name_set(&me.lib_name, "")
	name_set(&me.name, macro_unique_name("New macro"))
	me.dirty = false
	me_reset_view()
	me_set_msg(false, "A new macro: add nodes and wire them from Start")
}

@(private = "file")
me_autosave :: proc() {
	if me.m != nil && me.dirty do me_save()
}

// Writes the graph to the library under the name in the name field.
@(private = "file")
me_save :: proc() -> bool {
	want := macro_clean_name(name_str(&me.name))
	if want == "" do want = "Macro"
	old := macro_find(name_str(&me.lib_name))
	if old != nil && !strings.equal_fold(old.name, want) {
		if other := macro_find(want); other != nil {
			me_set_msg(true, "There is already a macro called %s", want)
			return false
		}
		old_name := strings.clone(old.name, context.temp_allocator)
		if ok, msg := macro_rename(old, want); !ok {
			me_set_msg(true, "%s", msg)
			return false
		}
		macro_renamed(old_name, old.name)
	}
	c := macro_clone(me.m)
	if c == nil do return false
	if old != nil {
		macro_set_name(c, old.name)
		if !macro_save(c) {
			macro_free(c)
			me_set_msg(true, "Could not write the macro file")
			return false
		}
		for x, i in macro_lib do if x == old do macro_lib[i] = c
		macro_free(old)
	} else {
		macro_set_name(c, want)
		if !macro_add(c) {
			macro_free(c)
			me_set_msg(true, "Could not write the macro file")
			return false
		}
	}
	name_set(&me.lib_name, c.name)
	name_set(&me.name, c.name)
	macro_set_name(me.m, c.name)
	me.dirty = false
	me_set_msg(false, "Saved %s", c.name)
	return true
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

@(private = "file")
to_screen :: proc(g: Vec2) -> Vec2 {
	return me.origin + (g - me.pan) * me.zoom
}

@(private = "file")
to_graph :: proc(s: Vec2) -> Vec2 {
	return (s - me.origin) / me.zoom + me.pan
}

// The settings a node shows, in order (temp memory): all but those that only apply to another choice, unless wired.
// With no node (one about to be added), as its defaults would show.
@(private = "file")
shown_rows :: proc(n: ^Macro_Node, def: ^Macro_Def) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	if def == nil do return out[:]
	vals: []Macro_Value
	if n != nil {
		vals = macro_node_own_values(n, def)
	} else {
		vals = make([]Macro_Value, len(def.settings), context.temp_allocator)
		for s, i in def.settings do vals[i] = s.def
	}
	for &s, i in def.settings {
		if macro_setting_shown(def, &s, vals) || (n != nil && macro_wire_from(me.m, n.id, s.key) != 0) do append(&out, i)
	}
	return out[:]
}

// A setting's place on its node: `top` rows down from the header, `units` rows tall (a curve takes several).
Me_Row :: struct {
	si, top, units: int,
}

// Where each shown setting sits on the node (temp memory).
@(private = "file")
node_rows :: proc(n: ^Macro_Node, def: ^Macro_Def) -> []Me_Row {
	out := make([dynamic]Me_Row, context.temp_allocator)
	top := 0
	for si in shown_rows(n, def) {
		units := def.settings[si].type == .Curve ? ME_CURVE_ROWS : 1
		append(&out, Me_Row{si, top, units})
		top += units
	}
	return out[:]
}

@(private = "file")
node_h :: proc(n: ^Macro_Node, def: ^Macro_Def) -> f32 {
	rows := node_rows(n, def)
	units := len(rows) > 0 ? rows[len(rows) - 1].top + rows[len(rows) - 1].units : 0
	h := ME_HEAD_H + f32(units) * ME_ROW_H + (units > 0 ? 6 : 0)
	if places := start_places(def); len(places) > 0 do h += f32(len(places) + 1) * ME_LINE_H + 6
	return h
}

// Where the macro can be used, as its Start node lists them under its settings: they follow the Trigger.
// Only in an app whose macros have triggers (the others can't run macros yet).
@(private = "file")
start_places :: proc(def: ^Macro_Def) -> []string {
	HOTKEY :: [?]string{"- A tool group (its + button, Macros)", "- The Macros menu", "- Macros > Manage Macros"}
	LAYER :: [?]string{"- A layer, as a layer effect:", "  Layer > Layer Effects"}
	@(static) hotkey := HOTKEY
	@(static) layer := LAYER
	if def == nil || def.kind != .Start || !macro_layer_effects || me.m == nil do return nil
	t, _ := macro_trigger(me.m)
	return t == .Hotkey ? hotkey[:] : layer[:]
}

// The node's box on screen.
@(private = "file")
node_box :: proc(n: ^Macro_Node, def: ^Macro_Def) -> FRect {
	p := to_screen({n.x, n.y})
	return {p.x, p.y, ME_NODE_W * me.zoom, node_h(n, def) * me.zoom}
}

// Where a socket is on screen.
@(private = "file")
port_pos :: proc(n: ^Macro_Node, def: ^Macro_Def, p: Me_Port) -> Vec2 {
	b := node_box(n, def)
	head := b.y + ME_HEAD_H * me.zoom / 2
	if p.out do return {b.x + b.w, head}
	if p.key == "" do return {b.x, head}
	for row in node_rows(n, def) {
		if def.settings[row.si].key == p.key do return {b.x, b.y + (ME_HEAD_H + f32(row.top) * ME_ROW_H + ME_ROW_H / 2) * me.zoom}
	}
	return {b.x, head}
}

// A setting's area on screen (the widget's area at 100%).
@(private = "file")
row_rect :: proc(b: FRect, row: Me_Row) -> Rect {
	y := b.y + (ME_HEAD_H + f32(row.top) * ME_ROW_H + 2) * me.zoom
	return {i32(math.round(b.x + 10 * me.zoom)), i32(math.round(y)), i32(math.round((ME_NODE_W - 18) * me.zoom)), i32(math.round((f32(row.units) * ME_ROW_H - 4) * me.zoom))}
}

// What a socket carries: the Document (`doc`), or a value of type `t`.
@(private = "file")
port_type :: proc(p: Me_Port) -> (t: Macro_Type, doc: bool, ok: bool) {
	n := macro_node(me.m, p.node)
	if n == nil do return
	def := macro_def_find(n.kind)
	if def == nil do return
	if p.out {
		if def.kind == .Value do return def.out, false, true
		return {}, true, true
	}
	if p.key == "" do return {}, true, def.kind == .Action
	for s in def.settings do if s.key == p.key do return s.type, false, true
	return
}

// The sockets a node has.
@(private = "file")
node_ports :: proc(n: ^Macro_Node, def: ^Macro_Def) -> []Me_Port {
	out := make([dynamic]Me_Port, context.temp_allocator)
	if def == nil do return out[:]
	switch def.kind {
	case .Action:
		append(&out, Me_Port{n.id, false, ""}, Me_Port{n.id, true, ""})
	case .Start:
		append(&out, Me_Port{n.id, true, ""})
	case .Value:
		append(&out, Me_Port{n.id, true, "out"})
	}
	for si in shown_rows(n, def) do if !def.settings[si].no_wire do append(&out, Me_Port{n.id, false, def.settings[si].key})
	return out[:]
}

// Can a wire join these two sockets? `a` and `b` in either order.
@(private = "file")
ports_fit :: proc(a, b: Me_Port) -> bool {
	if a.node == b.node || a.out == b.out do return false
	o, i := a.out ? a : b, a.out ? b : a
	ot, odoc, ook := port_type(o)
	it, idoc, iok := port_type(i)
	if !ook || !iok || odoc != idoc do return false
	if odoc do return !macro_link_loops(me.m, o.node, i.node)
	return macro_can_feed(ot, it)
}

@(private = "file")
connect :: proc(a, b: Me_Port) {
	if !ports_fit(a, b) do return
	o, i := a.out ? a : b, a.out ? b : a
	_, doc, _ := port_type(o)
	if doc {
		macro_link(me.m, o.node, i.node)
	} else {
		macro_wire(me.m, o.node, i.node, i.key)
	}
	me.dirty = true
}

// The socket under the pointer, topmost node first.
@(private = "file")
port_at :: proc(p: Vec2) -> (Me_Port, bool) {
	r := max(8, ME_PORT_R * me.zoom + 4)
	#reverse for &n in me.m.nodes {
		def := macro_def_find(n.kind)
		for port in node_ports(&n, def) {
			q := port_pos(&n, def, port)
			d := q - p
			if d.x * d.x + d.y * d.y <= r * r do return port, true
		}
	}
	return {}, false
}

@(private = "file")
node_at :: proc(p: Vec2) -> int {
	#reverse for &n in me.m.nodes {
		b := node_box(&n, macro_def_find(n.kind))
		if p.x >= b.x && p.y >= b.y && p.x < b.x + b.w && p.y < b.y + b.h do return n.id
	}
	return 0
}

@(private = "file")
is_selected :: proc(id: int) -> bool {
	for s in me.sel do if s == id do return true
	return false
}

@(private = "file")
select_only :: proc(id: int) {
	if len(me.sel) != 1 || me.sel[0] != id do me.side_scroll = 0
	clear(&me.sel)
	if id != 0 do append(&me.sel, id)
}

// Moves node `id` to the end of the list, so it draws on top.
@(private = "file")
raise :: proc(id: int) {
	for n, i in me.m.nodes {
		if n.id == id && i < len(me.m.nodes) - 1 {
			ordered_remove(&me.m.nodes, i)
			append(&me.m.nodes, n)
			return
		}
	}
}

TYPE_COLORS := [Macro_Type]Color {
	.Number = {120, 200, 130, 255},
	.Bool   = {230, 120, 120, 255},
	.Color  = {235, 195, 95, 255},
	.Choice = {120, 165, 235, 255},
	.Text   = {195, 145, 235, 255},
	.Curve  = {95, 205, 200, 255},
}
DOC_COLOR :: Color{225, 228, 235, 255}

@(private = "file")
port_color :: proc(p: Me_Port) -> Color {
	t, doc, ok := port_type(p)
	if !ok do return C_TEXT_OFF
	return doc ? DOC_COLOR : TYPE_COLORS[t]
}

// A header colour per category, so nodes of a kind read together.
@(private = "file")
category_color :: proc(cat: string) -> Color {
	switch cat {
	case "Flow":
		return {70, 110, 80, 255}
	case "Values":
		return {70, 80, 110, 255}
	case "Select":
		return {110, 90, 60, 255}
	case "Adjust", "Filter":
		return {100, 65, 105, 255}
	case "Develop":
		return {125, 85, 45, 255}
	case "Layer":
		return {60, 95, 115, 255}
	case "File":
		return {115, 70, 70, 255}
	}
	return {72, 76, 88, 255}
}

// ---------------------------------------------------------------------------
// The editor
// ---------------------------------------------------------------------------

macro_editor_ui :: proc(r: Rect) {
	if !me.open do return
	if me.m == nil do me_new()
	fill_rect(r, C_BG)
	body := r
	bar := cut_top(&body, ME_BAR_H)
	// the side panels give way on a small window, so the canvas keeps most of it; their inner edges can be dragged
	lib := cut_left(&body, panel_width(.Macro_Nodes, clamp(body.w / 6, 130, ME_LIB_W)))
	side := cut_right(&body, panel_width(.Macro_Side, clamp(body.w / 5, 170, ME_SIDE_W)))
	panel_track_drawn(.Macro_Nodes, lib, body)
	panel_track_drawn(.Macro_Side, side, body)
	me.canvas = body
	me.origin = {f32(body.x), f32(body.y)}
	if me.fit {
		me.fit = false
		me_frame_all()
	}

	me_keys()
	me_canvas(body)
	me_library(lib)
	me_side(side)
	me_bar(bar)
	me_live_sync()
}

// A layer effect shows its edits on the canvas as they happen: once the mouse is up and no field is being typed in,
// a change is saved to the library, and the layers using it run it again (macro_on_live_edit), whatever its trigger.
@(private = "file")
me_live_sync :: proc() {
	if !me.dirty || me.m == nil || ui.down[0] || ui.down[1] || ui.focus_id != 0 || me.drag != .None || me.curve_id != 0 do return
	lib := strings.clone(name_str(&me.lib_name), context.temp_allocator)
	if lib == "" || !strings.equal_fold(name_str(&me.name), lib) || macro_find(lib) == nil do return
	if !macro_is_layer_effect(me.m) do return
	if !me_save() do return
	if macro_on_live_edit != nil do macro_on_live_edit(lib)
	me_set_msg(false, "Saved %s: the layers using it show the change", lib)
}

@(private = "file")
me_bar :: proc(r: Rect) {
	fill_rect(r, C_PANEL)
	hline(r.x, r.y + r.h - 1, r.w, C_BORDER)
	x := r.x + 8
	y := r.y + (r.h - 18) / 2
	// which macro: the library's, then a new one
	@(static) names: [MACRO_MAX + 1]string
	n := min(len(macro_lib), MACRO_MAX)
	cur := n
	for m, i in macro_lib[:n] {
		names[i] = m.name
		if strings.equal_fold(m.name, name_str(&me.lib_name)) do cur = i
	}
	names[n] = "(new macro)"
	PICK_TIP :: "The macro to edit. The one you were editing is saved first."
	if nv, ch := combo(Rect{x, y + 2, 150, 14}, names[:n + 1], cur, {"Macro", PICK_TIP}); ch {
		if nv < n {
			me_load(macro_lib[nv])
		} else {
			me_new()
		}
	}
	x += 156
	if button(Rect{x, y, 46, 18}, "New", {"", "Start a new macro. The one you were editing is saved first."}) do me_new()
	x += 56
	NAME_TIP :: "The macro's name: what its menu item and tool group buttons say."
	tip_text(x, y + 5, "Name", C_TEXT_DIM, {"Name", NAME_TIP})
	x += text_w("Name") + 6
	if changed, _ := text_field(Rect{x, y + 2, 150, 14}, &me.name, {"Name", NAME_TIP}); changed do me.dirty = true
	x += 156
	if button(Rect{x, y, 54, 18}, me.dirty ? "Save*" : "Save", {"", "Save the macro (Ctrl+S). It is saved anyway when you close the editor or pick another macro."}, true, me.dirty) do me_save()
	x += 60
	if button_primary(Rect{x, y, 54, 18}, "Run", {"Run", "Run the macro on the open document now (F5). One Undo takes it all back."}) do me_run()
	x += 66
	right := r.x + r.w - 8
	if button(Rect{right - 60, y, 60, 18}, "Close", {"", "Close the node editor and go back to the canvas (Esc). The macro is saved."}) {
		macro_editor_close()
		return
	}
	msg := name_str(&me.msg)
	text_clipped(Rect{x, y + 5, right - 70 - x, 12}, msg, me.msg_bad ? C_DANGER : C_TEXT_DIM)
}

@(private = "file")
me_run :: proc() {
	ok, msg, at := macro_run(me.m)
	me.err_node = ok ? 0 : at
	if ok {
		me_set_msg(false, "Ran %s", name_str(&me.name))
	} else {
		me_set_msg(true, "Stopped. %s", msg)
	}
}

// Keys the editor handles, while no field has the keyboard.
@(private = "file")
me_keys :: proc() {
	if ui.focus_id != 0 || ui.input_layer > 1 do return
	if me.search {
		if IsKeyPressed(.ESCAPE) do me.search = false
		return
	}
	if ui.ctrl && IsKeyPressed(.S) do me_save()
	if IsKeyPressed(.F5) do me_run()
	if popup.open do return
	// typing on the canvas starts a search with what was typed
	if !ui.ctrl && !ui.alt && len(ui.chars) > 0 {
		sb := strings.builder_make(context.temp_allocator)
		for r in ui.chars do if r > ' ' || (r == ' ' && strings.builder_len(sb) > 0) do strings.write_rune(&sb, r)
		if typed := strings.to_string(sb); typed != "" {
			at := to_graph({f32(me.canvas.x + me.canvas.w / 2), f32(me.canvas.y + me.canvas.h / 3)})
			if in_rect(me.canvas, ui.mx, ui.my) do at = to_graph({f32(ui.mx), f32(ui.my)})
			me_search_open(at, false)
			name_set(&me.search_text, typed)
			return
		}
	}
	if IsKeyPressed(.ESCAPE) {
		if len(me.sel) > 0 {
			clear(&me.sel)
		} else {
			macro_editor_close()
		}
	}
	if IsKeyPressed(.DELETE) || IsKeyPressed(.BACKSPACE) do me_delete_selected()
	if ui.ctrl && IsKeyPressed(.D) do me_duplicate_selected()
	if ui.ctrl && IsKeyPressed(.A) {
		clear(&me.sel)
		for n in me.m.nodes do append(&me.sel, n.id)
	}
	if IsKeyPressed(.HOME) do me_frame_all()
	if IsKeyPressed(.TAB) do me_search_open(to_graph({f32(me.canvas.x + me.canvas.w / 2), f32(me.canvas.y + me.canvas.h / 3)}), false)
}

@(private = "file")
me_delete_selected :: proc() {
	for id in me.sel {
		n := macro_node(me.m, id)
		if n != nil && n.kind != MACRO_START {
			macro_remove_node(me.m, id)
			me.dirty = true
		}
	}
	clear(&me.sel)
}

@(private = "file")
me_duplicate_selected :: proc() {
	copies := make([dynamic]int, context.temp_allocator)
	for id in me.sel {
		n := macro_node(me.m, id)
		if n == nil || n.kind == MACRO_START do continue
		kind, x, y := n.kind, n.x + 24, n.y + 24
		args := make([dynamic]Macro_Arg, context.temp_allocator)
		append(&args, ..n.args[:])
		c := macro_add_node(me.m, kind, x, y)
		for a in args do macro_set_arg(me.m, c, a.key, a.val)
		append(&copies, c.id)
	}
	if len(copies) > 0 {
		clear(&me.sel)
		append(&me.sel, ..copies[:])
		me.dirty = true
	}
}

// Pans and zooms so every node shows.
@(private = "file")
me_frame_all :: proc() {
	if len(me.m.nodes) == 0 do return
	lo, hi := Vec2{1e9, 1e9}, Vec2{-1e9, -1e9}
	for &n in me.m.nodes {
		h := node_h(&n, macro_def_find(n.kind))
		lo = {min(lo.x, n.x), min(lo.y, n.y)}
		hi = {max(hi.x, n.x + ME_NODE_W), max(hi.y, n.y + h)}
	}
	cw, ch := f32(me.canvas.w) - 60, f32(me.canvas.h) - 60
	z := clamp(min(cw / max(hi.x - lo.x, 1), ch / max(hi.y - lo.y, 1)), 0.3, 1)
	me.zoom = z
	me.pan = (lo + hi) / 2 - Vec2{f32(me.canvas.w), f32(me.canvas.h)} / 2 / z
}

@(private = "file")
me_search_open :: proc(at: Vec2, from_wire: bool) {
	me.search = true
	me.search_at = at
	me.search_pick = 0
	me.search_focus = true
	me.search_wire = from_wire
	name_set(&me.search_text, "")
}

// Adds a node of kind `id` at graph position `at`, and selects it. Returns its id.
@(private = "file")
me_add :: proc(id: string, at: Vec2) -> int {
	if id == MACRO_START && macro_start(me.m) > 0 {
		me_set_msg(true, "A macro has one Start node")
		return 0
	}
	n := macro_add_node(me.m, id, math.round(at.x), math.round(at.y))
	nid := n.id
	select_only(nid)
	me.dirty = true
	return nid
}

// Adds a node picked in the library. With one step selected, an action goes right after it on the Document wire (so
// clicking Start and then actions in turn builds the chain in order); anything else goes to a free spot mid-canvas.
@(private = "file")
me_add_from_library :: proc(d: ^Macro_Def) {
	after: ^Macro_Node
	if len(me.sel) == 1 && d.kind == .Action {
		if s := macro_node(me.m, me.sel[0]); s != nil {
			if sd := macro_def_find(s.kind); sd != nil && sd.kind != .Value do after = s
		}
	}
	at := to_graph({f32(me.canvas.x + me.canvas.w / 2), f32(me.canvas.y + me.canvas.h / 3)}) - {ME_NODE_W / 2, 0}
	if after != nil do at = {after.x + ME_NODE_W + 40, after.y}
	at = me_free_spot(at, macro_def_find(d.id))
	after_id := after != nil ? after.id : 0
	next := -1
	if after != nil {
		// one step after it: the new one goes in between; several (branches): the new one starts another branch
		if outs := macro_nexts(me.m, after.id); len(outs) == 1 do next = outs[0]
	}
	id := me_add(d.id, at)
	if id == 0 || after_id == 0 do return
	macro_link(me.m, after_id, id)
	if next > 0 do macro_link(me.m, id, next) // this replaces the wire that went from `after` into it
}

// The first place at or below `at` where a node of kind `def` overlaps no other.
@(private = "file")
me_free_spot :: proc(at: Vec2, def: ^Macro_Def) -> Vec2 {
	p := at
	h := node_h(nil, def)
	for _ in 0 ..< 100 {
		moved := false
		for &n in me.m.nodes {
			nh := node_h(&n, macro_def_find(n.kind))
			if p.x < n.x + ME_NODE_W + 10 && p.x + ME_NODE_W + 10 > n.x && p.y < n.y + nh + 16 && p.y + h + 16 > n.y {
				p.y = n.y + nh + 24
				moved = true
			}
		}
		if !moved do break
	}
	return p
}

// Joins a new node to the wire that was dropped on the canvas, at the first socket that fits.
@(private = "file")
me_attach :: proc(nid: int) {
	n := macro_node(me.m, nid)
	if n == nil do return
	for p in node_ports(n, macro_def_find(n.kind)) {
		if ports_fit(me.wire, p) {
			connect(me.wire, p)
			return
		}
	}
}

// Does the node fit the wire being dropped (a socket that takes it)?
@(private = "file")
def_fits_wire :: proc(def: ^Macro_Def) -> bool {
	wt, wdoc, ok := port_type(me.wire)
	if !ok do return true
	if wdoc {
		return me.wire.out ? def.kind == .Action : def.kind != .Value
	}
	if me.wire.out {
		for s in def.settings do if !s.no_wire && macro_can_feed(wt, s.type) do return true
		return false
	}
	return def.kind == .Value && macro_can_feed(def.out, wt)
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

@(private = "file")
me_canvas :: proc(r: Rect) {
	fill_rect(r, C_VIEWPORT)
	clip_begin(r)
	defer clip_end()
	// dot grid, 20 graph units apart
	step := 20 * me.zoom
	if step >= 8 {
		ox := f32(r.x) - math.mod(me.pan.x * me.zoom, step)
		oy := f32(r.y) - math.mod(me.pan.y * me.zoom, step)
		dot := with_alpha(C_TEXT, 22)
		for y := oy; y < f32(r.y + r.h); y += step {
			for x := ox; x < f32(r.x + r.w); x += step {
				draw_rect(x, y, 1.5, 1.5, dot)
			}
		}
	}
	mouse := Vec2{f32(ui.mx), f32(ui.my)}
	inside := in_rect(r, ui.mx, ui.my) && ui.layer == ui.input_layer
	search_r := me_search_rect()
	over_search := me.search && in_rect(search_r, ui.mx, ui.my)
	me_canvas_input(r, mouse, inside && !over_search)

	// value wires, then the Document wire on top
	for w in me.m.wires {
		a, b := macro_node(me.m, w.from), macro_node(me.m, w.to)
		if a == nil || b == nil do continue
		from := Me_Port{w.from, true, "out"}
		draw_wire(port_pos(a, macro_def_find(a.kind), from), port_pos(b, macro_def_find(b.kind), {w.to, false, w.key}), port_color(from))
	}
	for f in me.m.flows {
		a, b := macro_node(me.m, f.from), macro_node(me.m, f.to)
		if a == nil || b == nil do continue
		draw_wire(port_pos(a, macro_def_find(a.kind), {f.from, true, ""}), port_pos(b, macro_def_find(b.kind), {f.to, false, ""}), DOC_COLOR)
	}
	// where the Document wire splits, a number by each branch says the order they run in
	for &n in me.m.nodes {
		outs := macro_nexts(me.m, n.id)
		if len(outs) < 2 do continue
		for o, i in outs {
			t := macro_node(me.m, o)
			if t == nil do continue
			p := port_pos(t, macro_def_find(t.kind), {o, false, ""}) - {18 * me.zoom, 0}
			rad := 6.5 * me.zoom
			draw_dot(p, rad, DOC_COLOR)
			label := fmt.tprintf("%d", i + 1)
			fs := i32(math.round(12 * me.zoom))
			if fs >= 6 do draw_text(p.x - text_width(label, fs) / 2, p.y - text_cap(fs) / 2, label, C_BG, fs)
		}
	}
	for &n in me.m.nodes do me_node(&n)
	if me.drag == .Wire {
		n := macro_node(me.m, me.wire.node)
		if n != nil {
			p := port_pos(n, macro_def_find(n.kind), me.wire)
			if me.wire.out {
				draw_wire(p, mouse, port_color(me.wire))
			} else {
				draw_wire(mouse, p, port_color(me.wire))
			}
		}
	}
	if me.drag == .Box {
		a, b := me.drag_from, mouse
		box := FRect{min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
		draw_rect(box.x, box.y, box.w, box.h, with_alpha(C_ACCENT, 30))
		draw_rect_outline(box, C_ACCENT)
	}
	if len(me.m.nodes) <= 1 && !me.search {
		hint := "Double-click the canvas or press Tab to add a node, then drag from Start's white socket to it."
		text(r.x + (r.w - text_w(hint)) / 2, r.y + r.h - 30, hint, C_TEXT_DIM)
	}
	text(r.x + 8, r.y + r.h - 16, fmt.tprintf("%d%%", int(math.round(me.zoom * 100))), C_TEXT_OFF)
	if me.search do me_search(me_search_rect()) // where it is now: the input above may just have opened it
}

@(private = "file")
draw_wire :: proc(a, b: Vec2, c: Color) {
	dx := max(abs(b.x - a.x) * 0.5, 30 * me.zoom)
	draw_bezier(a, a + {dx, 0}, b - {dx, 0}, b, max(2.2 * me.zoom, 1.4), c)
}

// Is the point on a node's widget (where a press belongs to the widget, not to the canvas)?
@(private = "file")
on_widget :: proc(p: Vec2) -> bool {
	if me.zoom != 1 do return false
	id := node_at(p)
	if id == 0 do return false
	n := macro_node(me.m, id)
	def := macro_def_find(n.kind)
	if def == nil do return false
	b := node_box(n, def)
	for row in node_rows(n, def) {
		if macro_wire_from(me.m, n.id, def.settings[row.si].key) != 0 do continue
		rr := row_rect(b, row)
		if in_rect(rr, i32(p.x), i32(p.y)) do return true
	}
	return false
}

@(private = "file")
me_canvas_input :: proc(r: Rect, mouse: Vec2, inside: bool) {
	// zoom with the wheel, around the pointer (not over a widget: the wheel changes its value)
	if inside && ui.wheel != 0 && !on_widget(mouse) {
		STEPS := [?]f32{0.3, 0.4, 0.5, 0.6, 0.7, 0.85, 1}
		at := 0
		for z, i in STEPS do if abs(z - me.zoom) < abs(STEPS[at] - me.zoom) do at = i
		at = clamp(at + (ui.wheel > 0 ? 1 : -1), 0, len(STEPS) - 1)
		g := to_graph(mouse)
		me.zoom = STEPS[at]
		me.pan = g - (mouse - me.origin) / me.zoom
	}
	switch me.drag {
	case .None:
	case .Pan:
		me.pan -= (mouse - me.drag_prev) / me.zoom
		if !ui.down[0] && !ui.down[2] do me.drag = .None
	case .Nodes:
		d := (mouse - me.drag_prev) / me.zoom
		if d != {} {
			for id in me.sel {
				if n := macro_node(me.m, id); n != nil {
					n.x += d.x
					n.y += d.y
				}
			}
			me.dirty = true
		}
		if !ui.down[0] {
			// settle on whole units so the file stays tidy
			for id in me.sel do if n := macro_node(me.m, id); n != nil do n.x, n.y = math.round(n.x), math.round(n.y)
			me.drag = .None
		}
	case .Wire:
		if !ui.down[0] {
			me.drag = .None
			if p, ok := port_at(mouse); ok && ports_fit(me.wire, p) {
				connect(me.wire, p)
			} else if inside && node_at(mouse) == 0 {
				// dropped on the canvas: pick a node to join it to
				me_search_open(to_graph(mouse) - {me.wire.out ? 0 : ME_NODE_W, ME_HEAD_H / 2}, true)
			}
		}
	case .Box:
		if !ui.down[0] {
			a, b := to_graph(me.drag_from), to_graph(mouse)
			lo, hi := Vec2{min(a.x, b.x), min(a.y, b.y)}, Vec2{max(a.x, b.x), max(a.y, b.y)}
			if !ui.shift do clear(&me.sel)
			for &n in me.m.nodes {
				h := node_h(&n, macro_def_find(n.kind))
				if n.x < hi.x && n.x + ME_NODE_W > lo.x && n.y < hi.y && n.y + h > lo.y && !is_selected(n.id) do append(&me.sel, n.id)
			}
			me.drag = .None
		}
	}
	me.drag_prev = mouse
	if !inside do return
	if ui.pressed[2] || (ui.pressed[0] && IsKeyDown(.SPACE)) {
		me.drag = .Pan
		return
	}
	if ui.dbl_click && node_at(mouse) == 0 {
		me.drag = .None
		me_search_open(to_graph(mouse), false)
		return
	}
	if !ui.pressed[0] do return
	me.search = false
	if p, ok := port_at(mouse); ok {
		ui.focus_id = 0
		if !p.out {
			// a wire already in this input is picked up from its other end, to move or drop it
			if p.key == "" {
				if from := macro_prev(me.m, p.node); from != 0 {
					macro_unlink(me.m, 0, p.node)
					me.wire = {from, true, ""}
					me.drag = .Wire
					me.dirty = true
					return
				}
			} else if from := macro_wire_from(me.m, p.node, p.key); from != 0 {
				macro_unwire(me.m, p.node, p.key)
				me.wire = {from, true, "out"}
				me.drag = .Wire
				me.dirty = true
				return
			}
		}
		me.wire = p
		me.drag = .Wire
		return
	}
	if on_widget(mouse) do return
	id := node_at(mouse)
	ui.focus_id = 0
	if id != 0 {
		if ui.shift {
			if is_selected(id) {
				for s, i in me.sel {
					if s == id {
						ordered_remove(&me.sel, i)
						break
					}
				}
			} else {
				append(&me.sel, id)
			}
		} else if !is_selected(id) {
			select_only(id)
		}
		raise(id)
		me.drag = .Nodes
		return
	}
	if ui.ctrl {
		me.drag = .Box
		me.drag_from = mouse
		return
	}
	clear(&me.sel)
	me.drag = .Pan
}

// One node: its box, header, sockets and settings.
@(private = "file")
me_node :: proc(n: ^Macro_Node) {
	def := macro_def_find(n.kind)
	b := node_box(n, def)
	cv := me.canvas
	if b.x > f32(cv.x + cv.w) || b.y > f32(cv.y + cv.h) || b.x + b.w < f32(cv.x) || b.y + b.h < f32(cv.y) do return
	z := me.zoom
	rad := RADIUS * 2 * z
	sel := is_selected(n.id)
	draw_shadow(b.x, b.y + 3 * z, b.w, b.h, rad, 10 * z, Color{0, 0, 0, 110})
	draw_rrect(b.x, b.y, b.w, b.h, rad, C_PANEL)
	head := def != nil ? category_color(def.category) : Color{120, 50, 50, 255}
	draw_rrect(b.x, b.y, b.w, ME_HEAD_H * z, rad, head)
	if b.h > ME_HEAD_H * z + rad do draw_rect(b.x, b.y + ME_HEAD_H * z - rad, b.w, rad, head)
	ring := sel ? C_ACCENT : C_RING_HI
	if n.id == me.err_node do ring = C_DANGER
	draw_rrect_outline(b.x, b.y, b.w, b.h, rad, ring)
	if sel || n.id == me.err_node do draw_rrect_outline(b.x - 1, b.y - 1, b.w + 2, b.h + 2, rad + 1, ring)

	fs := i32(math.round(f32(FONT_SIZE) * z))
	title := def != nil ? def.name : fmt.tprintf("%s (unknown)", n.kind)
	clip_begin(Rect{i32(b.x), i32(b.y), i32(b.w), i32(b.h)})
	if fs >= 7 do draw_text(b.x + 12 * z, b.y + (ME_HEAD_H * z - text_cap(fs)) / 2, title, WHITE, fs)
	if def != nil && def.kind == .Value && fs >= 7 {
		ts := strings.to_lower(fmt.tprintf("%v", def.out), context.temp_allocator)
		draw_text(b.x + b.w - 14 * z - text_width(ts, fs), b.y + (ME_HEAD_H * z - text_cap(fs)) / 2, ts, with_alpha(WHITE, 150), fs)
	}
	if def != nil {
		rows := node_rows(n, def)
		for row in rows do me_row(n, def, &def.settings[row.si], row.si, row, b, fs)
		if places := start_places(def); len(places) > 0 && fs >= 7 {
			units := len(rows) > 0 ? rows[len(rows) - 1].top + rows[len(rows) - 1].units : 0
			y := b.y + (ME_HEAD_H + f32(units) * ME_ROW_H + 6) * z
			x := b.x + 10 * z
			hline(i32(x), i32(y - 3 * z), i32(b.w - 20 * z), C_RING)
			draw_text(x, y + (ME_LINE_H * z - text_cap(fs)) / 2, "Where this applies:", C_TEXT_DIM, fs)
			for p, i in places {
				draw_text(x, y + (f32(i + 1) * ME_LINE_H * z) + (ME_LINE_H * z - text_cap(fs)) / 2, p, C_TEXT, fs)
			}
		}
	}
	clip_end()
	if def != nil {
		for p in node_ports(n, def) {
			pp := port_pos(n, def, p)
			c := port_color(p)
			connected := false
			if p.key == "" {
				connected = p.out ? macro_next(me.m, n.id) >= 0 : macro_prev(me.m, n.id) != 0
			} else if !p.out {
				connected = macro_wire_from(me.m, n.id, p.key) != 0
			} else {
				for w in me.m.wires do if w.from == n.id do connected = true
			}
			rr := ME_PORT_R * z
			if p.key == "" {
				// the Document sockets are squares, so they read apart from the values
				draw_rrect(pp.x - rr, pp.y - rr, rr * 2, rr * 2, 1.5 * z, connected ? c : C_PANEL_DK)
				draw_rrect_outline(pp.x - rr, pp.y - rr, rr * 2, rr * 2, 1.5 * z, c)
			} else {
				draw_dot(pp, rr + 1, c)
				if !connected do draw_dot(pp, rr - 1, C_PANEL_DK)
			}
		}
	}
	if ui.layer == ui.input_layer && in_rect(Rect{i32(b.x), i32(b.y), i32(b.w), i32(ME_HEAD_H * z)}, ui.mx, ui.my) && def != nil {
		tooltip_hover(make_id({}, fmt.tprintf("menode%d", n.id)), {def.name, me_node_help(def)})
	}
}

// A node's description. The Start node's follows its Trigger, and says where the macro can be added.
@(private = "file")
me_node_help :: proc(def: ^Macro_Def) -> string {
	if def.kind != .Start || !macro_layer_effects do return def.help
	return macro_start_help(macro_trigger(me.m))
}

// One setting of a node: its widget at 100%, else its value as text; a wired setting shows where it comes from.
@(private = "file")
me_row :: proc(n: ^Macro_Node, def: ^Macro_Def, s: ^Macro_Setting, i: int, row: Me_Row, b: FRect, fs: i32) {
	rr := row_rect(b, row)
	from := macro_wire_from(me.m, n.id, s.key)
	if s.type == .Curve && (from != 0 || me.zoom != 1) {
		// a curve still shows as a curve: the one wired in, or its own, zoomed out
		v := macro_node_own_values(n, def)[i]
		label := s.name
		if from != 0 {
			src := macro_node(me.m, from)
			sdef := src != nil ? macro_def_find(src.kind) : nil
			label = fmt.tprintf("%s  <  %s", s.name, sdef != nil ? sdef.name : "?")
			if sdef != nil && sdef.kind == .Value && sdef.out == .Curve && len(sdef.settings) > 0 do v = macro_node_own_values(src, sdef)[0]
		}
		curve_widget(n, s, rr, v, false, label, fs)
		return
	}
	if from != 0 || me.zoom != 1 {
		txt: string
		if from != 0 {
			src := macro_node(me.m, from)
			sdef := src != nil ? macro_def_find(src.kind) : nil
			txt = fmt.tprintf("%s  <  %s", s.name, sdef != nil ? sdef.name : "?")
		} else {
			v := macro_node_own_values(n, def)[i]
			txt = fmt.tprintf("%s: %s", s.name, setting_text(s, v))
		}
		if fs >= 7 do draw_text(f32(rr.x), f32(rr.y) + (f32(rr.h) - text_cap(fs)) / 2, txt, from != 0 ? TYPE_COLORS[s.type] : C_TEXT_DIM, fs)
		return
	}
	setting_widget(n, s, i, rr, macro_node_own_values(n, def)[i])
}

// A value as the editor shows it.
@(private = "file")
setting_text :: proc(s: ^Macro_Setting, v: Macro_Value) -> string {
	#partial switch s.type {
	case .Number:
		t := s.div > 0 ? macro_num_text(v.num / s.div) : macro_num_text(v.num)
		return fmt.tprintf("%s%s", t, s.suffix)
	case .Bool:
		return v.num != 0 ? "on" : "off"
	case .Curve:
		pts, _ := macro_curve_parse(v.text)
		return fmt.tprintf("%d points", len(pts))
	}
	return macro_value_text(s, v)
}

// The widget that edits setting `s` (number `i`) of node `n` in `r`.
@(private = "file")
setting_widget :: proc(n: ^Macro_Node, s: ^Macro_Setting, i: int, r: Rect, v: Macro_Value) {
	tip := Tip{s.name, s.help}
	set :: proc(n: ^Macro_Node, s: ^Macro_Setting, v: Macro_Value) {
		macro_set_arg(me.m, n, s.key, macro_value_text(s, v))
		me.dirty = true
	}
	switch s.type {
	case .Number:
		// the slider counts whole steps: with a step of 0.1 it counts tenths and shows them as decimals
		k := s.step > 0 && s.step < 1 ? int(math.round(1 / s.step)) : 1
		lo, hi := int(math.ceil(s.lo * f64(k) - 1e-9)), int(math.floor(s.hi * f64(k) + 1e-9))
		curve := s.curve > 0 ? s.curve : 1
		if s.hi > s.lo && (hi - lo <= 2000 || curve > 1) {
			iv := int(math.round(v.num * f64(k)))
			div := k > 1 ? k : (s.div > 1 ? int(s.div) : 1)
			if slider(r, &iv, lo, hi, s.name, tip, s.suffix, curve, div) do set(n, s, {num = f64(iv) / f64(k)})
		} else if s.hi > s.lo {
			lw := text_w(s.name) + 8
			text(r.x, r.y + (r.h - FONT_CAP) / 2, s.name, C_TEXT_DIM)
			iv := int(math.round(v.num))
			if field_int(Rect{r.x + lw, r.y, r.w - lw, r.h}, &iv, int(s.lo), int(s.hi), tip) do set(n, s, {num = f64(iv)})
		} else {
			lw := text_w(s.name) + 8
			text(r.x, r.y + (r.h - FONT_CAP) / 2, s.name, C_TEXT_DIM)
			if t, changed := text_box(n, s, Rect{r.x + lw, r.y, r.w - lw, r.h}, macro_num_text(v.num), tip); changed {
				if nv, ok := macro_value_parse(s, t); ok do set(n, s, nv)
			}
		}
	case .Bool:
		on := v.num != 0
		if checkbox(r.x, r.y + (r.h - 12) / 2, s.name, &on, tip) do set(n, s, {num = on ? 1 : 0})
	case .Choice:
		lw := text_w(s.name) + 8
		text(r.x, r.y + (r.h - FONT_CAP) / 2, s.name, C_TEXT_DIM)
		// with help for each choice, the closed combo tells what the picked one does
		cur := int(v.num)
		ctip := cur >= 0 && cur < len(s.choice_help) ? Tip{s.name, s.choice_help[cur]} : tip
		if nv, ch := combo(Rect{r.x + lw, r.y, r.w - lw, r.h}, s.choices, cur, ctip, item_tips = s.choice_help); ch do set(n, s, {num = f64(nv)})
	case .Color:
		lw := text_w(s.name) + 8
		text(r.x, r.y + (r.h - FONT_CAP) / 2, s.name, C_TEXT_DIM)
		sw := Rect{r.x + lw, r.y, r.h + 6, r.h}
		draw_rrect(f32(sw.x), f32(sw.y), f32(sw.w), f32(sw.h), RADIUS, v.col)
		draw_rrect_outline(f32(sw.x), f32(sw.y), f32(sw.w), f32(sw.h), RADIUS, C_RING_HI)
		if t, changed := text_box(n, s, Rect{sw.x + sw.w + 4, r.y, r.w - lw - sw.w - 4, r.h}, macro_value_text(s, v), tip); changed {
			if nv, ok := macro_value_parse(s, t); ok do set(n, s, nv)
		}
	case .Text:
		lw := text_w(s.name) + 8
		text(r.x, r.y + (r.h - FONT_CAP) / 2, s.name, C_TEXT_DIM)
		bw: i32 = s.browse ? 24 : 0
		sw: i32 = s.suggest != "" ? 20 : 0
		fw := r.w - lw - bw - sw
		if t, changed := text_box(n, s, Rect{r.x + lw, r.y, fw, r.h}, v.text, tip); changed do set(n, s, {text = t})
		if s.suggest != "" {
			// a list to pick from (the document's layers, say), next to the field
			dr := Rect{r.x + lw + fw + 2, r.y, 18, r.h}
			did := make_id(dr, fmt.tprintf("suggest%d.%s", n.id, s.key))
			clicked, held, hover := button_behavior(did, dr, {"Pick from the list", fmt.tprintf("Pick one of the open document's %s, instead of typing it.", s.suggest)})
			ctl_state(dr, hover, held || (popup.open && popup.owner == did), false, true)
			icon(.Down, dr.x + (dr.w - ICON_SIZE) / 2, dr.y + (dr.h - ICON_SIZE) / 2, C_TEXT_DIM)
			if clicked {
				items := macro_suggest(s.suggest)
				popup_begin(did, Rect{r.x + lw, r.y, fw + 20, r.h}, fw + 20)
				for it, i in items do popup_item(it, i, checked = strings.equal_fold(it, v.text))
				if len(items) == 0 do popup_item(fmt.tprintf("No %s", s.suggest), -1, enabled = false)
			}
			if ui.popup_result_id == did {
				items := macro_suggest(s.suggest)
				if i := ui.popup_result_val; i >= 0 && i < len(items) {
					set(n, s, {text = items[i]})
					me.edit_node = 0
					ui.focus_id = 0
				}
				ui.popup_result_id = 0
			}
		}
		BROWSE_TIP :: "Pick the folder and the file name in a file window. {name} in the name becomes the document's name when the macro runs, and {ext} the format's extension."
		if s.browse && button(Rect{r.x + r.w - 20, r.y, 20, r.h}, "...", {"Choose the file", BROWSE_TIP}) {
			initial := v.text != "" ? path_basename(v.text) : "{name}"
			filters := [1]Filter{{"All files (*.*)", "*.*"}}
			if p, ok := native_dialog(true, fmt.tprintf("%s: where to save", s.name), filters[:], "", initial); ok {
				path, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
				set(n, s, {text = path})
				me.edit_node = 0
				ui.focus_id = 0
				delete(p)
			}
		}
	case .Curve:
		if t, changed := curve_widget(n, s, r, v, true, s.name, FONT_SIZE); changed do set(n, s, {text = t})
	}
}

// A Curve setting: its name, then a graph to shape it in `r`. Tones go in along the bottom (the bar under the graph,
// dark at the left) and come out up the side (the bar at its left). A `mask` curve gives a strength instead: at the top
// the node works fully on that tone, at the bottom not at all, and the area under the line is filled to show it.
// With `live`, drag a point to move it, click to add one, right-click one to remove it; without, it is only drawn
// (a zoomed-out node, a wired curve). Returns the new points as text when they change.
@(private = "file")
curve_widget :: proc(n: ^Macro_Node, s: ^Macro_Setting, r: Rect, v: Macro_Value, live: bool, label: string, fs: i32) -> (out: string, changed: bool) {
	pts_in, pok := macro_curve_parse(v.text)
	if !pok do pts_in, _ = macro_curve_parse(s.def.text != "" ? s.def.text : MACRO_CURVE_DEFAULT)
	pts := make([dynamic]Vec2, context.temp_allocator)
	append(&pts, ..pts_in)
	z := live ? 1 : me.zoom
	head := i32(math.round(16 * z))
	bar := max(i32(math.round(5 * z)), 2)
	gap := max(i32(math.round(2 * z)), 1)
	if fs >= 7 {
		if live {
			text(r.x, r.y + 2, label, C_TEXT_DIM)
		} else {
			draw_text(f32(r.x), f32(r.y) + (f32(head) - text_cap(fs)) / 2, label, TYPE_COLORS[.Curve], fs)
		}
	}
	plot := Rect{r.x + bar + gap, r.y + head, r.w - bar - gap, r.h - head - bar - gap}
	if plot.w < 8 || plot.h < 8 do return
	col := TYPE_COLORS[.Curve]
	if live && button(Rect{r.x + r.w - 44, r.y, 44, 14}, "Reset", {"", s.mask ? "Put the curve back as it was when the node was added." : "Make the curve as it was when the node was added: tones come out as they go in."}) {
		return s.def.text != "" ? s.def.text : MACRO_CURVE_DEFAULT, true
	}
	// the bars: what goes in (bottom) and what comes out, or how strongly it applies (left)
	for x in 0 ..< plot.w {
		g := u8(x * 255 / max(plot.w - 1, 1))
		draw_rect(f32(plot.x + x), f32(plot.y + plot.h + gap), 1, f32(bar), {g, g, g, 255})
	}
	for y in 0 ..< plot.h {
		g := u8((plot.h - 1 - y) * 255 / max(plot.h - 1, 1))
		draw_rect(f32(r.x), f32(plot.y + y), f32(bar), 1, {g, g, g, 255})
	}
	ctl_well(plot)
	px, py, pw, ph := f32(plot.x) + 1, f32(plot.y) + 1, f32(plot.w) - 2, f32(plot.h) - 2
	to_scr :: proc(p: Vec2, px, py, pw, ph: f32) -> Vec2 {
		return {px + p.x / 255 * pw, py + ph - p.y / 255 * ph}
	}
	for k in 1 ..< 4 {
		draw_rect(px + pw * f32(k) / 4, py, 1, ph, with_alpha(C_TEXT, 16))
		draw_rect(px, py + ph * f32(k) / 4, pw, 1, with_alpha(C_TEXT, 16))
	}
	if !s.mask do draw_line({px, py + ph}, {px + pw, py}, with_alpha(C_TEXT, 50))

	// input: grab, add, remove, drag
	id := make_id(r, fmt.tprintf("curve%d.%s", n.id, s.key))
	hit := Rect{plot.x - 5, plot.y - 5, plot.w + 10, plot.h + 10}
	mouse := Vec2{f32(ui.mx), f32(ui.my)}
	at := Vec2{clamp((mouse.x - px) / pw * 255, 0, 255), clamp((py + ph - mouse.y) / ph * 255, 0, 255)}
	near := -1
	if live && ui_hover(hit) && !popup.open {
		best := f32(7)
		for p, i in pts {
			q := to_scr(p, px, py, pw, ph)
			dv := q - mouse
			if dd := math.sqrt(dv.x * dv.x + dv.y * dv.y); dd < best do near, best = i, dd
		}
		tip_area(plot, fmt.tprintf("curvetip%d.%s", n.id, s.key), {s.name, s.help})
		if ui.pressed[0] {
			if near < 0 && len(pts) < MACRO_CURVE_MAX {
				near = len(pts)
				for p, i in pts {
					if p.x > at.x {
						near = i
						break
					}
				}
				inject_at(&pts, near, Vec2{math.round(at.x), math.round(at.y)})
				changed = true
			}
			if near >= 0 {
				me.curve_id, me.curve_pt = id, near
				ui.active_id = id
				ui.focus_id = 0
			}
		} else if ui.pressed[1] && near >= 0 && len(pts) > 2 {
			ordered_remove(&pts, near)
			near = -1
			changed = true
		}
	}
	if live && me.curve_id == id {
		if !ui.down[0] {
			me.curve_id = 0
			if ui.active_id == id do ui.active_id = 0
		} else if k := me.curve_pt; k >= 0 && k < len(pts) {
			lo: f32 = k > 0 ? pts[k - 1].x + 1 : 0
			hi: f32 = k < len(pts) - 1 ? pts[k + 1].x - 1 : 255
			np := Vec2{math.round(clamp(at.x, lo, hi)), math.round(at.y)}
			if np != pts[k] {
				pts[k] = np
				changed = true
			}
			near = k
		}
	}

	// the curve, filled under for a strength, and its points
	lut := macro_curve_lut(pts[:])
	steps := max(int(pw), 2)
	prev: Vec2
	for i in 0 ..= steps {
		t := f32(i) / f32(steps) * 255
		y := lut[clamp(int(math.round(t)), 0, 255)]
		q := to_scr({t, y}, px, py, pw, ph)
		if s.mask && i < steps do draw_rect(q.x, q.y, max(pw / f32(steps), 1), py + ph - q.y, with_alpha(col, 46))
		if i > 0 do draw_thick_line(prev, q, max(1.6 * z, 1), col)
		prev = q
	}
	if live || me.zoom >= 0.6 {
		hs := max(3 * z, 2)
		for p, i in pts {
			q := to_scr(p, px, py, pw, ph)
			lit := live && i == near
			draw_frect({q.x - hs - 1, q.y - hs - 1, hs * 2 + 2, hs * 2 + 2}, lit ? C_ACCENT : BLACK)
			draw_frect({q.x - hs, q.y - hs, hs * 2, hs * 2}, lit ? WHITE : C_TEXT)
		}
	}
	if changed do return macro_curve_text(pts[:]), true
	return
}

// A text field over a node's setting. While it has the keyboard it edits `me.edit_buf`; otherwise it shows `shown`.
@(private = "file")
text_box :: proc(n: ^Macro_Node, s: ^Macro_Setting, r: Rect, shown: string, tip: Tip) -> (text: string, changed: bool) {
	id := make_id(r, "text")
	mine := me.edit_node == n.id && me.edit_key == s.key
	if ui.focus_id == id && !mine {
		// it took the keyboard last frame: start from the stored value
		me.edit_node, me.edit_key = n.id, s.key
		name_set(&me.edit_buf, shown)
		mine = true
	}
	if ui.focus_id == id {
		ch, _ := text_field(r, &me.edit_buf, tip)
		return name_str(&me.edit_buf), ch
	}
	if mine do me.edit_node = 0
	tmp: Name
	name_set(&tmp, shown)
	text_field(r, &tmp, tip)
	return "", false
}

// ---------------------------------------------------------------------------
// Adding nodes: the search box on the canvas, and the library on the left
// ---------------------------------------------------------------------------

@(private = "file")
me_search_rect :: proc() -> Rect {
	p := to_screen(me.search_at)
	h := i32(22 + ME_SEARCH_ROWS * 16 + 6)
	x := clamp(i32(p.x), me.canvas.x + 4, me.canvas.x + me.canvas.w - ME_SEARCH_W - 4)
	y := clamp(i32(p.y), me.canvas.y + 4, me.canvas.y + me.canvas.h - h - 4)
	return {x, y, ME_SEARCH_W, h}
}

// A node the search offers: the node itself, or the node with one of its choices already picked.
Macro_Hit :: struct {
	def:     ^Macro_Def,
	setting: int, // the Choice setting that is picked, or -1
	choice:  int,
	label:   string,
	score:   int,
}

// The nodes that match what was typed, best first (temp memory). Every word typed has to be in the node's name,
// category or description. A word that is in one of a node's choices ("soft light", "png", "bicubic") also offers the
// node with that choice picked. `fits` leaves out nodes that can't join the wire being dropped.
macro_search :: proc(query: string, fits: proc(_: ^Macro_Def) -> bool = nil) -> []Macro_Hit {
	out := make([dynamic]Macro_Hit, context.temp_allocator)
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	words := strings.fields(q, context.temp_allocator)
	has_all :: proc(hay: string, words: []string) -> bool {
		for w in words do if !strings.contains(hay, w) do return false
		return true
	}
	defs := make([dynamic]^Macro_Def, context.temp_allocator)
	for &d in macro_shared_defs() do append(&defs, &d)
	for &d in macro_catalogue() do append(&defs, &d)
	for d in defs {
		if d.kind == .Start || (fits != nil && !fits(d)) do continue
		name := strings.to_lower(d.name, context.temp_allocator)
		place := strings.to_lower(fmt.tprintf("%s %s %s", d.name, d.category, d.id), context.temp_allocator)
		score := 0
		switch {
		case len(words) == 0:
			score = 1
		case has_all(name, words):
			score = strings.has_prefix(name, q) ? 100 : 80
		case has_all(place, words):
			score = 60
		case has_all(fmt.tprintf("%s %s", place, strings.to_lower(d.help, context.temp_allocator)), words):
			score = 20
		}
		if score > 0 do append(&out, Macro_Hit{d, -1, 0, d.name, score})
		if len(words) == 0 do continue
		for s, si in d.settings {
			if s.type != .Choice do continue
			for c, ci in s.choices {
				lc := strings.to_lower(c, context.temp_allocator)
				in_choice := false
				for w in words do if strings.contains(lc, w) do in_choice = true
				if !in_choice || !has_all(fmt.tprintf("%s %s %s", lc, place, strings.to_lower(s.name, context.temp_allocator)), words) do continue
				sc := lc == q ? 95 : (strings.has_prefix(lc, q) ? 90 : 70)
				append(&out, Macro_Hit{d, si, ci, fmt.tprintf("%s: %s", d.name, c), sc})
			}
		}
	}
	slice.stable_sort_by(out[:], proc(a, b: Macro_Hit) -> bool {return a.score > b.score})
	return out[:]
}

// The nodes whose name or category has every word typed (temp memory).
@(private = "file")
defs_matching :: proc(query: string, wire_only: bool) -> []^Macro_Def {
	out := make([dynamic]^Macro_Def, context.temp_allocator)
	words := strings.fields(strings.to_lower(query, context.temp_allocator), context.temp_allocator)
	add :: proc(out: ^[dynamic]^Macro_Def, d: ^Macro_Def, words: []string, wire_only: bool) {
		if d.kind == .Start do return
		if wire_only && !def_fits_wire(d) do return
		hay := strings.to_lower(fmt.tprintf("%s %s %s", d.name, d.category, d.id), context.temp_allocator)
		for w in words do if !strings.contains(hay, w) do return
		append(out, d)
	}
	for &d in macro_shared_defs() do add(&out, &d, words, wire_only)
	for &d in macro_catalogue() do add(&out, &d, words, wire_only)
	return out[:]
}

@(private = "file")
me_search :: proc(r: Rect) {
	ui.layer = 0
	draw_shadow(f32(r.x), f32(r.y) + 3, f32(r.w), f32(r.h), RADIUS, 12, Color{0, 0, 0, 140})
	ctl_surface(r, C_PANEL, C_RING_HI)
	fr := Rect{r.x + 4, r.y + 4, r.w - 8, 14}
	_, submitted := text_field(fr, &me.search_text, {"Find a node", "Type part of a node's name or category. Up and Down pick, Enter adds it, Esc closes."})
	if me.search_focus {
		ui.focus_id = make_id(fr, "text")
		ui.caret = me.search_text.n
		ui.sel_all = false
		caret_show()
		me.search_focus = false
	}
	list := macro_search(name_str(&me.search_text), me.search_wire ? def_fits_wire : nil)
	if IsKeyPressed(.DOWN) || IsKeyPressedRepeat(.DOWN) do me.search_pick += 1
	if IsKeyPressed(.UP) || IsKeyPressedRepeat(.UP) do me.search_pick -= 1
	me.search_pick = clamp(me.search_pick, 0, max(len(list) - 1, 0))
	first := max(me.search_pick - ME_SEARCH_ROWS + 1, 0)
	pick := -1
	if submitted && len(list) > 0 do pick = me.search_pick
	for i in first ..< min(len(list), first + ME_SEARCH_ROWS) {
		h := list[i]
		d := h.def
		row := Rect{r.x + 4, r.y + 22 + i32(i - first) * 16, r.w - 8, 16}
		hover := in_rect(row, ui.mx, ui.my)
		if hover && (ui.mx != ui.pmx || ui.my != ui.pmy) do me.search_pick = i
		if i == me.search_pick do draw_rrect(f32(row.x), f32(row.y), f32(row.w), f32(row.h), RADIUS, C_HOVER)
		cw := text_w(d.category)
		text_clipped(Rect{row.x + 6, row.y + 4, row.w - cw - 18, 12}, h.label, h.setting >= 0 ? C_ACCENT : C_TEXT)
		text(row.x + row.w - cw - 6, row.y + 4, d.category, C_TEXT_OFF)
		if hover {
			tooltip_hover(make_id(row, "mesearch"), {h.label, d.help})
			if ui.pressed[0] do pick = i
		}
	}
	if len(list) == 0 do text(r.x + 10, r.y + 28, "No node matches", C_TEXT_DIM)
	if pick >= 0 {
		h := list[pick]
		id := me_add(h.def.id, me.search_at)
		if id != 0 && h.setting >= 0 {
			s := &h.def.settings[h.setting]
			macro_set_arg(me.m, macro_node(me.m, id), s.key, s.choices[h.choice])
		}
		if me.search_wire && id != 0 do me_attach(id)
		me.search = false
		ui.focus_id = 0
	}
	if IsKeyPressed(.ESCAPE) {
		me.search = false
		ui.focus_id = 0
	}
}

@(private = "file")
me_library :: proc(r: Rect) {
	fill_rect(r, C_PANEL)
	vline(r.x + r.w - 1, r.y, r.h, C_BORDER)
	text(r.x + 8, r.y + 8, "Nodes", C_TEXT_DIM)
	FILTER_TIP :: "Type to find a node. Click a node to add it to the middle of the canvas."
	text_field(Rect{r.x + 6, r.y + 22, r.w - 12, 14}, &me.lib_filter, {"Find", FILTER_TIP})
	list := defs_matching(name_str(&me.lib_filter), false)
	area := Rect{r.x, r.y + 42, r.w, r.h - 42}
	if ui_hover(area) && ui.wheel != 0 do me.lib_scroll -= i32(ui.wheel * 48)
	ROW :: 16
	// rows: a header where the category changes, then its nodes
	total: i32
	prev := ""
	for d in list {
		if d.category != prev do total += ROW + 4
		prev = d.category
		total += ROW
	}
	me.lib_scroll = clamp(me.lib_scroll, 0, max(total - area.h + 8, 0))
	clip_begin(area)
	y := area.y + 4 - me.lib_scroll
	prev = ""
	for d in list {
		if d.category != prev {
			y += 4
			if y > area.y - ROW && y < area.y + area.h do text(r.x + 8, y + 4, d.category, category_color(d.category) + Color{60, 60, 60, 0})
			y += ROW
			prev = d.category
		}
		row := Rect{r.x + 4, y, r.w - 10, ROW}
		if y > area.y - ROW && y < area.y + area.h {
			hover := ui_hover(row) && in_rect(area, ui.mx, ui.my)
			if hover do draw_rrect(f32(row.x), f32(row.y), f32(row.w), f32(row.h), RADIUS, C_HOVER)
			text_clipped(Rect{row.x + 12, row.y + 4, row.w - 14, 12}, d.name, hover ? WHITE : C_TEXT)
			if hover {
				tooltip_hover(make_id(row, d.id), {d.name, d.help})
				if ui.pressed[0] do me_add_from_library(d)
			}
		}
		y += ROW
	}
	clip_end()
}

// ---------------------------------------------------------------------------
// The panel on the right: the selected node's settings, and the document
// ---------------------------------------------------------------------------

// Shows that the settings go on past the panel, and where they are scrolled to. Drag the handle, or click the track
// to jump there.
@(private = "file")
me_side_scrollbar :: proc(track: Rect, view_h: i32) {
	@(static) grab: i32 // where on the handle the pointer took it
	total := max(me.side_h, view_h + 1)
	max_scroll := total - view_h
	thumb_h := clamp(track.h * view_h / total, min(24, track.h), track.h)
	travel := max(track.h - thumb_h, 1)
	thumb := Rect{track.x, track.y + travel * me.side_scroll / max_scroll, track.w, thumb_h}
	id := make_id(track, "me-side-scroll")
	hover := ui_hover(track)
	if hover {
		tooltip_hover(id, {"", "There is more below: drag, or scroll with the wheel."})
		if ui.pressed[0] && me.curve_id == 0 {
			ui.active_id = id
			ui.focus_id = 0
			grab = in_rect(thumb, ui.mx, ui.my) ? ui.my - thumb.y : thumb_h / 2
		}
	}
	held := ui.active_id == id && ui.down[0]
	if held {
		me.side_scroll = clamp((ui.my - grab - track.y) * max_scroll / travel, 0, max_scroll)
		thumb.y = track.y + travel * me.side_scroll / max_scroll
	}
	draw_rrect(f32(track.x), f32(track.y), f32(track.w), f32(track.h), f32(track.w) / 2, C_PANEL_DK)
	draw_rrect(f32(thumb.x), f32(thumb.y), f32(thumb.w), f32(thumb.h), f32(thumb.w) / 2, held ? C_ACCENT : hover ? C_HOVER : C_PANEL_LT)
}

@(private = "file")
me_side :: proc(r: Rect) {
	fill_rect(r, C_PANEL)
	vline(r.x, r.y, r.h, C_BORDER)
	inner := rect_inset(r, 8)
	prev_h := min(i32(f32(inner.w) * 0.8), inner.h / 2)
	preview := Rect{inner.x, inner.y + inner.h - prev_h, inner.w, prev_h}
	text(preview.x, preview.y - 14, "Document", C_TEXT_DIM)
	macro_preview(preview)
	props := Rect{inner.x, inner.y, inner.w, preview.y - 20 - inner.y}
	clip_begin(props)
	defer clip_end()
	if len(me.sel) != 1 {
		msg := len(me.sel) == 0 ? "Select a node to see its settings here." : fmt.tprintf("%d nodes selected.", len(me.sel))
		for line, i in tooltip_wrap(msg, props.w, text_w) do text(props.x, props.y + i32(i) * 14, line, C_TEXT_DIM)
		return
	}
	n := macro_node(me.m, me.sel[0])
	if n == nil do return
	def := macro_def_find(n.kind)
	if def == nil {
		text(props.x, props.y, fmt.tprintf("\"%s\" isn't in this version.", n.kind), C_DANGER)
		return
	}
	// a tall node (a curve, many settings) scrolls with the wheel, or the bar on the right
	if ui_hover(props) && ui.wheel != 0 && me.curve_id == 0 do me.side_scroll -= i32(ui.wheel * 40)
	me.side_scroll = clamp(me.side_scroll, 0, max(me.side_h - props.h, 0))
	if me.side_h > props.h {
		me_side_scrollbar(Rect{props.x + props.w - ME_SCROLL_W, props.y, ME_SCROLL_W, props.h}, props.h)
		props.w -= ME_SCROLL_W + 6
	}
	y := props.y - me.side_scroll
	text(props.x, y, def.name, WHITE)
	text(props.x + props.w - text_w(def.category), y, def.category, C_TEXT_OFF)
	y += 16
	for line in tooltip_wrap(me_node_help(def), props.w, text_w) {
		text(props.x, y, line, C_TEXT_DIM)
		y += 13
	}
	y += 8
	vals := macro_node_own_values(n, def)
	// a row partly scrolled out is drawn, clipped. Hover doesn't know about clipping, so a pointer outside the settings
	// (on the bar above, the document below) doesn't reach the rows at all, unless it is dragging or typing in one
	shows :: proc(y, h: i32, props: Rect) -> bool {return y + h > props.y && y < props.y + props.h}
	layer := ui.layer
	defer ui.layer = layer
	if !in_rect(props, ui.mx, ui.my) && ui.active_id == 0 && ui.focus_id == 0 && me.curve_id == 0 do ui.layer = -1
	for i in shown_rows(n, def) {
		s := &def.settings[i]
		row := Rect{props.x, y, props.w, 16}
		if from := macro_wire_from(me.m, n.id, s.key); from != 0 {
			if shows(y, 16, props) {
				src := macro_node(me.m, from)
				sdef := src != nil ? macro_def_find(src.kind) : nil
				text(row.x, row.y + 4, fmt.tprintf("%s  <  %s", s.name, sdef != nil ? sdef.name : "?"), TYPE_COLORS[s.type])
				if button(Rect{row.x + row.w - 70, row.y, 70, 16}, "Disconnect", {"", "Take the wire out of this setting, so it uses its own value again."}) {
					macro_unwire(me.m, n.id, s.key)
					me.dirty = true
				}
			}
			y += 22
			continue
		}
		if s.type == .Curve {
			// a bigger graph than on the node, to place points finely
			ch := min(props.w, 200) + 22
			if shows(y, ch, props) do setting_widget(n, s, i, Rect{props.x, y, props.w, ch}, vals[i])
			y += ch + 8
			continue
		}
		if shows(y, 16, props) do setting_widget(n, s, i, row, vals[i])
		y += 22
	}
	if n.kind != MACRO_START {
		y += 6
		if shows(y, 16, props) && button(Rect{props.x, y, 80, 16}, "Delete Node", {"", "Remove this node and its wires (Delete)."}) {
			macro_remove_node(me.m, n.id)
			clear(&me.sel)
			me.dirty = true
		}
		y += 16
	}
	me.side_h = y + me.side_scroll - props.y
	// the settings fade out where they go on past the panel
	FADE :: 18
	x, w := f32(props.x), f32(props.w)
	if me.side_scroll > 0 do draw_gradient(x, f32(props.y), w, FADE, C_PANEL, with_alpha(C_PANEL, 0))
	if me.side_scroll < me.side_h - props.h do draw_gradient(x, f32(props.y + props.h) - FADE, w, FADE, with_alpha(C_PANEL, 0), C_PANEL)
}
