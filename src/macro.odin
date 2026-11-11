package pangolin

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// Node macros: a graph of the app's own operations (select, fill, effects, layers, export, ...), run as one undo step.
// The graph, its file format (macro_io.odin), the node editor (macro_editor.odin) and the interpreter are shared. Each
// app supplies its nodes and runs them, in its own macros.odin:
//
//   macro_app_id    :: proc() -> string                      // "paints", "pixels" or "scales"
//   macro_catalogue :: proc() -> []Macro_Def                 // every action node the app offers
//   macro_exec      :: proc(def: ^Macro_Def, args: []Macro_Value) -> (ok: bool, msg: string)
//   macro_begin     :: proc() -> (ok: bool, msg: string)     // before a run: finish pending edits, take one undo snapshot, hold history
//   macro_end       :: proc(keep: bool)                      // after a run: release history; keep = false restores the snapshot
//   macro_dir       :: proc() -> string                      // the folder of .pmacro files, ending in /
//   macro_info      :: proc(what: int) -> f64                // a number about the open document, by MACRO_INFO index
//   macro_preview   :: proc(r: Rect)                         // draws the open document small, for the editor
//   macro_renamed   :: proc(old, new: string)                // a macro was renamed: things that hold it by name follow
//   macro_snapshot  :: proc() -> rawptr                      // a copy of the document, to start each branch from (nil: none)
//   macro_restore   :: proc(snap: rawptr)                    // puts the document back as it was in the copy
//   macro_snapshot_free :: proc(snap: rawptr)
//   macro_suggest   :: proc(what: string) -> []string        // values to offer for a Text setting's `suggest` ("layers": the layer names)
//
// The Document wire runs from the Start node through the action nodes and sets their order (`flows`). It can split:
// a node may send it to several nodes, which run as branches, top to bottom, each starting from the document as it was
// where the wire split. Branch 1 (the top one) is the main line: the document keeps its changes. The others are side
// trips, for exports and the like: their changes to the document are put back when they end. So one macro can export
// the image, then pick a layer and export that, and leave the document as it was. Value wires (`wires`)
// feed a node's settings from value nodes (Number, Color, Math, Random, Document Info ...), each of which is worked
// out once per branch. Every node keeps its settings as text (key = value), so a file always loads, even with
// nodes or settings this version doesn't know.

MACRO_MAX_STEPS :: 10000 // nodes one run may execute
MACRO_MAX_NODES :: 10000 // nodes one macro file may hold
MACRO_START :: "flow.start"

Macro_Type :: enum u8 {
	Number,
	Bool,
	Color,
	Choice,
	Text,
	Curve, // points x,y (0..255) joined by a smooth line: a new tone for each tone, or how strongly something applies
}

Macro_Value :: struct {
	num:  f64, // Number; Bool as 0 or 1; Choice as the index into the setting's choices
	col:  Color,
	text: string, // Text; Curve as its points, "0,0 128,160 255,255"
}

Macro_Setting :: struct {
	key:     string, // name in the file: lower case, no spaces
	name:    string, // shown in the editor
	type:    Macro_Type,
	lo, hi:  f64, // Number range (lo == hi: any number)
	div:     f64, // a Number is shown as num / div (0: as it is)
	step:    f64, // a Number's slider moves in steps this size, such as 0.1 (0: whole numbers)
	curve:   f32, // a Number's slider gives more room to small values the higher this is (0 or 1: even)
	suffix:  string,
	choices: []string,
	choice_help: []string, // Choice: what each choice does, the tooltip of its item in the list (constants)
	def:     Macro_Value,
	help:    string,
	browse:  bool, // Text: a file path, with a button that picks it in a save window
	only:    string, // "key=choice|choice": shown only while that Choice setting is one of those
	suggest: string, // Text: a list the app offers to pick from (macro_suggest), such as "layers"; typing still works
	no_wire: bool, // set on the node only: it has no socket, and a wire into it is ignored
	mask:    bool, // Curve: it gives how strongly something applies at each tone (bottom: none, top: full), not a new tone
}

// When a macro runs: the Trigger setting of its Start node. On Hotkey macros are run by the user. The others are live
// layer effects (in an app that has them, macro_layer_effects): they run on a layer they're added to, as often as the
// trigger allows. Which one a macro has decides where it's offered: tool groups and the Macros menu list the On Hotkey
// ones, a layer's effects list the rest.
Macro_Trigger :: enum u8 {
	Hotkey, // run by the user: a tool group's key, the Macros menu or the Macros window
	Paint, // after each change to the layer
	Pause, // once the layer has been left alone for `seconds`
	Timer, // at most once every `seconds`, while the layer keeps changing
	Demand, // when added, once painting on the layer stops, and when asked to (Refresh)
}

MACRO_TRIGGER_NAMES := [?]string{"On Hotkey", "On Paint", "After a Pause", "Every N Seconds", "On Demand"}
MACRO_TRIGGER_HELP := [?]string {
	"Runs when you run it: from a tool group, the Macros menu, or Macros > Manage Macros. One undo takes it all back.",
	"A layer effect: runs after every change to the layer it's on. Add it to a layer in Layer > Layer Effects.",
	"A layer effect: runs once the layer has been left alone for Seconds. Good for heavy macros. Add it to a layer in Layer > Layer Effects.",
	"A layer effect: runs at most once every Seconds while the layer keeps changing. Add it to a layer in Layer > Layer Effects.",
	"A layer effect: runs when it's added, when you stop painting on the layer, and when you click the circling arrow by the layer's fx. Good for heavy macros. Add it to a layer in Layer > Layer Effects.",
}
MACRO_TRIGGER_SECONDS :: 2 // Seconds' default
MACRO_TRIGGER_MIN_SECONDS :: 0.2 // never 0: a timed trigger always waits a little

// The app runs macros as live layer effects (Paints), so the Start node offers their triggers. Set it before the
// macros are first used: macro_shared_defs reads it once.
macro_layer_effects := false

Macro_Kind :: enum u8 {
	Action, // Document in and out: changes the document
	Start, // Document out only
	Value, // no Document wire: works out a value from its settings, for other nodes' settings
}

Macro_Def :: struct {
	id:       string, // "cmd.Select_All", "fx.Gaussian_Blur"
	name:     string,
	category: string,
	help:     string,
	settings: []Macro_Setting,
	kind:     Macro_Kind,
	out:      Macro_Type, // a Value node's result
}

Macro_Arg :: struct {
	key, val: string,
}

Macro_Node :: struct {
	id:   int,
	kind: string, // a Macro_Def id
	x, y: f32, // position in the editor
	args: [dynamic]Macro_Arg,
}

// The Document wire goes from node `from` to node `to`. A node has at most one coming in, and any number going out.
Macro_Flow :: struct {
	from, to: int,
}

// A value wire: the result of value node `from` is setting `key` of node `to`.
Macro_Wire :: struct {
	from, to: int,
	key:      string,
}

Macro :: struct {
	name:    string,
	app:     string,
	nodes:   [dynamic]Macro_Node,
	flows:   [dynamic]Macro_Flow,
	wires:   [dynamic]Macro_Wire,
	next_id: int,
	arena:   ^virtual.Arena, // everything above lives here; freed in one go
}

macro_running: bool // a macro is running: its commands are not recorded

// The node editor saved a change to layer effect `name` as it was being edited: an app with layer effects runs them
// again at once, so the canvas follows the edit (nil: nothing to do).
macro_on_live_edit: proc(name: string)

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

macro_alloc :: proc(m: ^Macro) -> mem.Allocator {
	return virtual.arena_allocator(m.arena)
}

// An empty macro holding just its Start node.
macro_new :: proc(name: string) -> ^Macro {
	m := macro_new_empty(name)
	macro_add_node(m, MACRO_START, 0, 0)
	return m
}

// A macro with no nodes at all (the file reader fills it in).
macro_new_empty :: proc(name: string) -> ^Macro {
	m := new(Macro)
	m.arena = new(virtual.Arena)
	if virtual.arena_init_growing(m.arena) != nil {
		free(m.arena)
		free(m)
		return nil
	}
	a := macro_alloc(m)
	m.name = strings.clone(name, a)
	m.app = strings.clone(macro_app_id(), a)
	m.nodes = make([dynamic]Macro_Node, a)
	m.flows = make([dynamic]Macro_Flow, a)
	m.wires = make([dynamic]Macro_Wire, a)
	m.next_id = 1
	return m
}

macro_free :: proc(m: ^Macro) {
	if m == nil do return
	virtual.arena_destroy(m.arena)
	free(m.arena)
	free(m)
}

// A copy of the macro (the caller owns it).
macro_clone :: proc(m: ^Macro) -> ^Macro {
	c, _ := macro_from_text(macro_to_text(m))
	return c
}

macro_set_name :: proc(m: ^Macro, name: string) {
	m.name = strings.clone(name, macro_alloc(m))
}

macro_add_node :: proc(m: ^Macro, kind: string, x, y: f32, id := 0) -> ^Macro_Node {
	nid := id > 0 ? id : m.next_id
	m.next_id = max(m.next_id, nid + 1)
	append(&m.nodes, Macro_Node{id = nid, kind = strings.clone(kind, macro_alloc(m)), x = x, y = y, args = make([dynamic]Macro_Arg, macro_alloc(m))})
	return &m.nodes[len(m.nodes) - 1]
}

macro_node :: proc(m: ^Macro, id: int) -> ^Macro_Node {
	for &n in m.nodes do if n.id == id do return &n
	return nil
}

// Removes a node and every wire to or from it.
macro_remove_node :: proc(m: ^Macro, id: int) {
	macro_unlink(m, id, id)
	#reverse for w, i in m.wires do if w.from == id || w.to == id do ordered_remove(&m.wires, i)
	for n, i in m.nodes {
		if n.id == id {
			ordered_remove(&m.nodes, i)
			break
		}
	}
}

macro_set_arg :: proc(m: ^Macro, n: ^Macro_Node, key, val: string) {
	v := strings.clone(val, macro_alloc(m))
	for &a in n.args {
		if a.key == key {
			a.val = v
			return
		}
	}
	append(&n.args, Macro_Arg{strings.clone(key, macro_alloc(m)), v})
}

macro_arg :: proc(n: ^Macro_Node, key: string) -> (string, bool) {
	for a in n.args do if a.key == key do return a.val, true
	return "", false
}

// Joins `from` to `to` with the Document wire, replacing the wire that reached `to` before. Wires already leaving `from`
// stay: they are other branches.
macro_link :: proc(m: ^Macro, from, to: int) {
	macro_unlink(m, 0, to)
	append(&m.flows, Macro_Flow{from, to})
}

// Would joining `from` to `to` close a loop (is `to` already before `from` on the wire)?
macro_link_loops :: proc(m: ^Macro, from, to: int) -> bool {
	at := from
	for _ in 0 ..< len(m.nodes) + 1 {
		if at == to do return true
		at = macro_prev(m, at)
		if at == 0 do return false
	}
	return true
}

// Removes the Document wires leaving `from` and reaching `to` (either may be 0: none).
macro_unlink :: proc(m: ^Macro, from, to: int) {
	#reverse for f, i in m.flows {
		if (from != 0 && f.from == from) || (to != 0 && f.to == to) do ordered_remove(&m.flows, i)
	}
}

// The node the Document wire goes to after `id` (the top one, if it splits), or -1.
macro_next :: proc(m: ^Macro, id: int) -> int {
	outs := macro_nexts(m, id)
	return len(outs) > 0 ? outs[0] : -1
}

// Every node the Document wire goes to after `id`, in the order the branches run: top to bottom (temp memory).
macro_nexts :: proc(m: ^Macro, id: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for f in m.flows do if f.from == id do append(&out, f.to)
	key :: proc(m: ^Macro, id: int) -> [2]f32 {
		n := macro_node(m, id)
		return n != nil ? {n.y, n.x} : {}
	}
	for i in 1 ..< len(out) {
		for j := i; j > 0; j -= 1 {
			a, b := key(m, out[j - 1]), key(m, out[j])
			if a.x < b.x || (a.x == b.x && a.y <= b.y) do break
			out[j - 1], out[j] = out[j], out[j - 1]
		}
	}
	return out[:]
}

// The node the Document wire comes from into `id`, or 0.
macro_prev :: proc(m: ^Macro, id: int) -> int {
	for f in m.flows do if f.to == id do return f.from
	return 0
}

// Feeds setting `key` of node `to` from value node `from`, replacing the wire it had.
macro_wire :: proc(m: ^Macro, from, to: int, key: string) {
	macro_unwire(m, to, key)
	append(&m.wires, Macro_Wire{from, to, strings.clone(key, macro_alloc(m))})
}

macro_unwire :: proc(m: ^Macro, to: int, key: string) {
	#reverse for w, i in m.wires do if w.to == to && w.key == key do ordered_remove(&m.wires, i)
}

// The value node feeding setting `key` of node `to`, or 0.
macro_wire_from :: proc(m: ^Macro, to: int, key: string) -> int {
	for w in m.wires do if w.to == to && w.key == key do return w.from
	return 0
}

// The Start node's id: -1 with none, -2 with more than one.
macro_start :: proc(m: ^Macro) -> int {
	found := -1
	for n in m.nodes {
		if n.kind != MACRO_START do continue
		if found >= 0 do return -2
		found = n.id
	}
	return found
}

macro_def_find :: proc(id: string) -> ^Macro_Def {
	for &d in macro_shared_defs() do if d.id == id do return &d
	for &d in macro_catalogue() do if d.id == id do return &d
	return nil
}

// The action nodes on the Document wire from Start, in the order they run: each branch to its end before the next.
// Fails on a loop, an unknown node or a wire to nothing.
macro_chain :: proc(m: ^Macro) -> (chain: []^Macro_Node, ok: bool, msg: string) {
	out := make([dynamic]^Macro_Node, context.temp_allocator)
	start := macro_start(m)
	switch start {
	case -1:
		return nil, false, "it has no Start node"
	case -2:
		return nil, false, "it has more than one Start node"
	}
	// depth first, the top branch first
	stack := make([dynamic]int, context.temp_allocator)
	outs := macro_nexts(m, start)
	#reverse for o in outs do append(&stack, o)
	for len(stack) > 0 {
		at := pop(&stack)
		n := macro_node(m, at)
		if n == nil do return nil, false, "a wire leads to a node that isn't there"
		def := macro_def_find(n.kind)
		if def == nil do return nil, false, fmt.tprintf("this version has no \"%s\" node", n.kind)
		if def.kind != .Action do return nil, false, fmt.tprintf("%s can't be on the Document wire", def.name)
		for prev in out do if prev == n do return nil, false, "its Document wire goes round in a loop"
		if len(out) >= MACRO_MAX_STEPS do return nil, false, "it has too many steps"
		append(&out, n)
		nexts := macro_nexts(m, at)
		#reverse for o in nexts do append(&stack, o)
	}
	return out[:], true, ""
}

// Is setting `s` shown, given the node's values (`only`: while another setting has one of the choices listed)?
macro_setting_shown :: proc(def: ^Macro_Def, s: ^Macro_Setting, vals: []Macro_Value) -> bool {
	if s.only == "" do return true
	key, _, choices := strings.partition(s.only, "=")
	for &o, i in def.settings {
		if o.key != key || o.type != .Choice do continue
		cur := int(vals[i].num)
		if cur < 0 || cur >= len(o.choices) do return false
		for c in strings.split(choices, "|", context.temp_allocator) do if strings.equal_fold(c, o.choices[cur]) do return true
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Nodes every app has: Start and the value nodes
// ---------------------------------------------------------------------------

MATH_OPS := [?]string{"add", "subtract", "multiply", "divide", "min", "max", "power", "round"}
MACRO_INFO := [?]string{"width", "height", "layers", "active layer", "frames", "active frame"}

@(private = "file")
shared_defs: [dynamic]Macro_Def

@(private = "file")
shared_def :: proc(def: Macro_Def, settings: ..Macro_Setting) {
	d := def
	d.settings = make([]Macro_Setting, len(settings))
	copy(d.settings, settings)
	append(&shared_defs, d)
}

macro_shared_defs :: proc() -> []Macro_Def {
	if len(shared_defs) > 0 do return shared_defs[:]
	ANY_NUMBER :: "Any number. Type it, or wire a value into it."
	START_HELP :: "Where the macro begins: its Document wire leads through the steps, in order. Each macro has one."
	if macro_layer_effects {
		shared_def({id = MACRO_START, name = "Start", category = "Flow", kind = .Start, help = START_HELP + " Its Trigger sets when the macro runs."},
			{key = "trigger", name = "Trigger", type = .Choice, choices = MACRO_TRIGGER_NAMES[:], choice_help = MACRO_TRIGGER_HELP[:], no_wire = true, help = "When the macro runs, which also decides where it can be added. Open the list and point at a choice to see what it does."},
			{key = "seconds", name = "Seconds", type = .Number, lo = MACRO_TRIGGER_MIN_SECONDS, hi = 600, step = 0.1, curve = 3, suffix = " s", def = {num = MACRO_TRIGGER_SECONDS}, no_wire = true, only = "trigger=After a Pause|Every N Seconds", help = "After a Pause: how long the layer has to be left alone. Every N Seconds: the shortest time between two runs."})
	} else {
		shared_def({id = MACRO_START, name = "Start", category = "Flow", kind = .Start, help = START_HELP})
	}
	shared_def({id = "value.Number", name = "Number", category = "Values", kind = .Value, out = .Number, help = "A number, for the settings of other nodes."},
		{key = "value", name = "Value", type = .Number, help = ANY_NUMBER})
	shared_def({id = "value.Bool", name = "On / Off", category = "Values", kind = .Value, out = .Bool, help = "On or off, for the settings of other nodes."},
		{key = "value", name = "On", type = .Bool, def = {num = 1}, help = "On, or off."})
	shared_def({id = "value.Color", name = "Color", category = "Values", kind = .Value, out = .Color, help = "A color, for the settings of other nodes."},
		{key = "color", name = "Color", type = .Color, def = {col = {0, 0, 0, 255}}, help = "The color, as #rrggbb or #rrggbbaa."})
	shared_def({id = "value.Text", name = "Text", category = "Values", kind = .Value, out = .Text, help = "Text, such as a file name or a layer name, for the settings of other nodes."},
		{key = "text", name = "Text", type = .Text, help = "The text."})
	shared_def({id = "value.Curve", name = "Curve", category = "Values", kind = .Value, out = .Curve, help = "A curve, for the curve settings of other nodes: wire one into several nodes and they all follow it."},
		{key = "curve", name = "Curve", type = .Curve, def = {text = MACRO_CURVE_DEFAULT}, help = MACRO_CURVE_HELP})
	shared_def({id = "value.Math", name = "Math", category = "Values", kind = .Value, out = .Number, help = "Works out a number from two others."},
		{key = "a", name = "A", type = .Number, help = ANY_NUMBER},
		{key = "op", name = "Operation", type = .Choice, choices = MATH_OPS[:], help = "What to do with A and B. Round rounds A to the nearest multiple of B, or to a whole number if B is 0."},
		{key = "b", name = "B", type = .Number, def = {num = 1}, help = ANY_NUMBER})
	shared_def({id = "value.Random", name = "Random", category = "Values", kind = .Value, out = .Number, help = "A random number between Min and Max, new each time the macro runs."},
		{key = "min", name = "Min", type = .Number, help = "The smallest number it gives."},
		{key = "max", name = "Max", type = .Number, def = {num = 100}, help = "The largest number it gives."},
		{key = "whole", name = "Whole", type = .Bool, def = {num = 1}, help = "Only whole numbers."})
	shared_def({id = "value.Info", name = "Document Info", category = "Values", kind = .Value, out = .Number, help = "A number about the open document, read when a step first needs it."},
		{key = "what", name = "What", type = .Choice, choices = MACRO_INFO[:], help = "Which number: the size in pixels, how many layers or frames there are, or which one is active (1 is the first)."})
	return shared_defs[:]
}

// Can a value of type `from` feed a setting of type `to`?
macro_can_feed :: proc(from, to: Macro_Type) -> bool {
	if from == to do return true
	#partial switch from {
	case .Number:
		return to == .Choice || to == .Bool
	case .Bool:
		return to == .Number
	}
	return false
}

// A wired value made to fit setting `s`.
@(private = "file")
macro_fit :: proc(s: ^Macro_Setting, v: Macro_Value) -> Macro_Value {
	out := v
	#partial switch s.type {
	case .Number:
		if s.hi > s.lo do out.num = clamp(out.num, s.lo, s.hi)
	case .Choice:
		out.num = f64(clamp(int(math.round(out.num)), 0, max(len(s.choices) - 1, 0)))
	case .Bool:
		out.num = out.num != 0 ? 1 : 0
	}
	return out
}

// What one run has worked out so far: each value node gives one result per run.
Macro_Run :: struct {
	m:     ^Macro,
	cache: map[int]Macro_Value,
	busy:  map[int]bool, // being worked out: a value wired back into itself
	seed:  u64,
}

macro_run_state :: proc(m: ^Macro) -> Macro_Run {
	return {m = m, cache = make(map[int]Macro_Value, context.temp_allocator), busy = make(map[int]bool, context.temp_allocator), seed = u64(gfx_time() * 1e6) | 1}
}

@(private = "file")
macro_rand :: proc(r: ^Macro_Run) -> f64 {
	// xorshift: a new sequence each run
	r.seed ~= r.seed << 13
	r.seed ~= r.seed >> 7
	r.seed ~= r.seed << 17
	return f64(r.seed >> 11) / f64(u64(1) << 53)
}

// The result of value node `id`.
macro_eval :: proc(r: ^Macro_Run, id: int) -> (v: Macro_Value, ok: bool, msg: string) {
	if c, have := r.cache[id]; have do return c, true, ""
	n := macro_node(r.m, id)
	if n == nil do return {}, false, "a wire comes from a node that isn't there"
	def := macro_def_find(n.kind)
	if def == nil do return {}, false, fmt.tprintf("this version has no \"%s\" node", n.kind)
	if def.kind != .Value do return {}, false, fmt.tprintf("%s gives no value", def.name)
	if r.busy[id] do return {}, false, "values are wired round in a loop"
	r.busy[id] = true
	args, aok, amsg := macro_node_values(r, n, def)
	r.busy[id] = false
	if !aok do return {}, false, amsg
	switch def.id {
	case "value.Number", "value.Bool", "value.Color", "value.Text", "value.Curve":
		v = args[0]
	case "value.Math":
		a, b := args[0].num, args[2].num
		switch int(args[1].num) {
		case 0:
			v.num = a + b
		case 1:
			v.num = a - b
		case 2:
			v.num = a * b
		case 3:
			if b == 0 do return {}, false, "Math divides by 0"
			v.num = a / b
		case 4:
			v.num = min(a, b)
		case 5:
			v.num = max(a, b)
		case 6:
			v.num = math.pow(a, b)
		case 7:
			v.num = b == 0 ? math.round(a) : math.round(a / b) * b
		}
		if math.is_nan(v.num) || math.is_inf(v.num) do return {}, false, "Math gives no number"
	case "value.Random":
		lo, hi := min(args[0].num, args[1].num), max(args[0].num, args[1].num)
		if args[2].num != 0 {
			lo, hi = math.ceil(lo), math.floor(hi)
			if hi < lo do return {}, false, "Random has no whole number between Min and Max"
			v.num = min(lo + math.floor(macro_rand(r) * (hi - lo + 1)), hi)
		} else {
			v.num = lo + macro_rand(r) * (hi - lo)
		}
	case "value.Info":
		v.num = macro_info(int(args[0].num))
	case:
		return {}, false, fmt.tprintf("%s gives no value", def.name)
	}
	r.cache[id] = v
	return v, true, ""
}

// ---------------------------------------------------------------------------
// Setting values: text in the file, Macro_Value when running
// ---------------------------------------------------------------------------

// A setting's value from its text. Text that doesn't fit the setting gives `ok = false` and the default.
macro_value_parse :: proc(s: ^Macro_Setting, text: string) -> (v: Macro_Value, ok: bool) {
	v = s.def
	t := strings.trim_space(text)
	switch s.type {
	case .Number:
		n := strconv.parse_f64(t) or_return
		if math.is_nan(n) || math.is_inf(n) do return
		if s.hi > s.lo do n = clamp(n, s.lo, s.hi)
		v.num = n
	case .Bool:
		switch strings.to_lower(t, context.temp_allocator) {
		case "1", "true", "yes", "on":
			v.num = 1
		case "0", "false", "no", "off":
			v.num = 0
		case:
			return
		}
	case .Color:
		v.col = macro_parse_color(t) or_return
	case .Choice:
		for c, i in s.choices {
			if strings.equal_fold(c, t) {
				v.num = f64(i)
				return v, true
			}
		}
		i := strconv.parse_int(t) or_return
		if i < 0 || i >= len(s.choices) do return
		v.num = f64(i)
	case .Text:
		v.text = text
	case .Curve:
		pts, pok := macro_curve_parse(t)
		if !pok do return
		v.text = macro_curve_text(pts)
	}
	return v, true
}

// The text that stores `v` (temp memory).
macro_value_text :: proc(s: ^Macro_Setting, v: Macro_Value) -> string {
	switch s.type {
	case .Number:
		return macro_num_text(v.num)
	case .Bool:
		return v.num != 0 ? "1" : "0"
	case .Color:
		c := v.col
		return c.a == 255 ? fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b) : fmt.tprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
	case .Choice:
		i := int(v.num)
		return i >= 0 && i < len(s.choices) ? s.choices[i] : "0"
	case .Text, .Curve:
		return v.text
	}
	return ""
}

macro_num_text :: proc(n: f64) -> string {
	if n == math.trunc(n) && abs(n) < 1e15 do return fmt.tprintf("%d", i64(n))
	s := fmt.tprintf("%.4f", n)
	s = strings.trim_right(s, "0")
	return strings.trim_suffix(s, ".")
}

macro_parse_color :: proc(t: string) -> (c: Color, ok: bool) {
	h := strings.trim_prefix(t, "#")
	if len(h) != 6 && len(h) != 8 do return
	n := strconv.parse_u64_of_base(h, 16) or_return
	if len(h) == 6 do n = n << 8 | 0xff
	return Color{u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)}, true
}

// ---------------------------------------------------------------------------
// Curves: points from 0,0 (bottom left) to 255,255 (top right), joined by a smooth line that never overshoots
// ---------------------------------------------------------------------------

MACRO_CURVE_DEFAULT :: "0,0 64,64 192,192 255,255"
MACRO_CURVE_HELP :: "Tones go in along the bottom (dark at the left) and come out up the side. Drag a point to bend the curve, click the line to add a point, right-click a point to remove it."
MACRO_CURVE_MAX :: 16 // points

// A curve's points from their text, "x,y x,y ...", sorted left to right (temp memory). Needs two points or more.
macro_curve_parse :: proc(t: string) -> (pts: []Vec2, ok: bool) {
	out := make([dynamic]Vec2, context.temp_allocator)
	for f in strings.fields(t, context.temp_allocator) {
		xs, _, ys := strings.partition(f, ",")
		x := strconv.parse_f64(xs) or_return
		y := strconv.parse_f64(ys) or_return
		if math.is_nan(x) || math.is_nan(y) do return
		p := Vec2{f32(clamp(math.round(x), 0, 255)), f32(clamp(math.round(y), 0, 255))}
		// in order of x; a point on the same x as another replaces it
		at := len(out)
		for q, i in out {
			if q.x == p.x {
				at = -1
				out[i] = p
				break
			}
			if q.x > p.x {
				at = i
				break
			}
		}
		if at >= 0 do inject_at(&out, at, p)
		if len(out) > MACRO_CURVE_MAX do return
	}
	if len(out) < 2 do return
	return out[:], true
}

// A curve's points as text (temp memory).
macro_curve_text :: proc(pts: []Vec2) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for p, i in pts {
		if i > 0 do strings.write_byte(&sb, ' ')
		fmt.sbprintf(&sb, "%d,%d", int(math.round(p.x)), int(math.round(p.y)))
	}
	return strings.to_string(sb)
}

// The curve's height (0..255) over each tone 0..255: monotone cubic (Fritsch-Carlson) between the points, so it never
// bulges past them, and flat beyond the first and last. What the editor draws is what the nodes apply.
macro_curve_lut :: proc(pts: []Vec2) -> (lut: [256]f32) {
	n := len(pts)
	if n == 0 {
		for i in 0 ..< 256 do lut[i] = f32(i)
		return
	}
	if n == 1 {
		for i in 0 ..< 256 do lut[i] = clamp(pts[0].y, 0, 255)
		return
	}
	d := make([]f32, n, context.temp_allocator)
	m := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n - 1 do d[k] = (pts[k + 1].y - pts[k].y) / max(pts[k + 1].x - pts[k].x, 1e-3)
	m[0], m[n - 1] = d[0], d[n - 2]
	for k in 1 ..< n - 1 do m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) * 0.5
	for k in 0 ..< n - 1 {
		if d[k] == 0 {
			m[k], m[k + 1] = 0, 0
			continue
		}
		a, b := m[k] / d[k], m[k + 1] / d[k]
		if s := a * a + b * b; s > 9 {
			t := 3 / math.sqrt(s)
			m[k], m[k + 1] = t * a * d[k], t * b * d[k]
		}
	}
	seg := 0
	for i in 0 ..< 256 {
		x := f32(i)
		switch {
		case x <= pts[0].x:
			lut[i] = pts[0].y
		case x >= pts[n - 1].x:
			lut[i] = pts[n - 1].y
		case:
			for seg < n - 2 && x > pts[seg + 1].x do seg += 1
			h := pts[seg + 1].x - pts[seg].x
			t := (x - pts[seg].x) / h
			t2, t3 := t * t, t * t * t
			lut[i] = (2 * t3 - 3 * t2 + 1) * pts[seg].y + (t3 - 2 * t2 + t) * h * m[seg] + (-2 * t3 + 3 * t2) * pts[seg + 1].y + (t3 - t2) * h * m[seg + 1]
		}
		lut[i] = clamp(lut[i], 0, 255)
	}
	return
}

// The curve of a Curve value as a table (identity if the text isn't a curve).
macro_curve_value_lut :: proc(v: Macro_Value) -> [256]f32 {
	pts, ok := macro_curve_parse(v.text)
	if !ok do return macro_curve_lut(nil)
	return macro_curve_lut(pts)
}

// The node's settings as values, in the order of `def.settings` (temp memory): from the wire feeding the setting, else
// from the node. A setting the node doesn't store, or stores as text that doesn't fit, takes its default.
macro_node_values :: proc(r: ^Macro_Run, n: ^Macro_Node, def: ^Macro_Def) -> (vals: []Macro_Value, ok: bool, msg: string) {
	vals = make([]Macro_Value, len(def.settings), context.temp_allocator)
	for &s, i in def.settings {
		vals[i] = s.def
		if from := macro_wire_from(r.m, n.id, s.key); from != 0 && !s.no_wire {
			v, vok, vmsg := macro_eval(r, from)
			if !vok do return nil, false, vmsg
			vals[i] = macro_fit(&s, v)
		} else if t, has := macro_arg(n, s.key); has {
			vals[i], _ = macro_value_parse(&s, t)
		}
	}
	return vals, true, ""
}

// The settings the node stores itself, ignoring wires (temp memory).
macro_node_own_values :: proc(n: ^Macro_Node, def: ^Macro_Def) -> []Macro_Value {
	vals := make([]Macro_Value, len(def.settings), context.temp_allocator)
	for &s, i in def.settings {
		vals[i] = s.def
		if t, has := macro_arg(n, s.key); has do vals[i], _ = macro_value_parse(&s, t)
	}
	return vals
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

// Runs a macro as one undo step. If a node fails, the document goes back to how it was and `msg` says why;
// `at` is the failing node's id (0 if it failed before starting).
macro_run :: proc(m: ^Macro) -> (ok: bool, msg: string, at: int) {
	if macro_running do return false, "another macro is running", 0
	if m.app != macro_app_id() do return false, fmt.tprintf("it was made in Pangolin %s", m.app), 0
	chain, cok, cmsg := macro_chain(m)
	if !cok do return false, cmsg, 0
	_ = chain
	if bok, bmsg := macro_begin(); !bok do return false, bmsg, 0
	macro_running = true
	defer macro_running = false
	run := macro_run_state(m)
	ok, msg, at = macro_run_from(&run, macro_start(m))
	macro_end(ok)
	return
}

// Runs the steps after node `id`. Where the Document wire splits, each branch starts from the document as it was there,
// and the document ends as branch 1 left it.
@(private = "file")
macro_run_from :: proc(r: ^Macro_Run, id: int) -> (ok: bool, msg: string, at: int) {
	cur := id
	for {
		outs := macro_nexts(r.m, cur)
		switch len(outs) {
		case 0:
			return true, "", 0
		case 1:
			if sok, smsg, sat := macro_step(r, outs[0]); !sok do return sok, smsg, sat
			cur = outs[0]
		case:
			split := macro_snapshot()
			defer if split != nil do macro_snapshot_free(split)
			main: rawptr // the document as branch 1 left it
			defer if main != nil do macro_snapshot_free(main)
			for o, i in outs {
				if i > 0 && split != nil do macro_restore(split)
				clear(&r.cache) // values are worked out again for each branch: the document may differ
				if sok, smsg, sat := macro_step(r, o); !sok do return sok, smsg, sat
				if bok, bmsg, bat := macro_run_from(r, o); !bok do return bok, bmsg, bat
				if i == 0 do main = macro_snapshot()
			}
			if main != nil do macro_restore(main)
			return true, "", 0
		}
	}
}

// Runs one step.
@(private = "file")
macro_step :: proc(r: ^Macro_Run, id: int) -> (ok: bool, msg: string, at: int) {
	n := macro_node(r.m, id)
	def := macro_def_find(n.kind)
	args, aok, amsg := macro_node_values(r, n, def)
	if !aok do return false, fmt.tprintf("%s: %s", def.name, amsg), id
	if eok, emsg := macro_exec(def, args); !eok {
		return false, fmt.tprintf("%s: %s", def.name, emsg != "" ? emsg : "it didn't work"), id
	}
	return true, "", 0
}

// Runs a macro from the library by name and reports the result in the status bar.
macro_run_named :: proc(name: string) -> bool {
	m := macro_find(name)
	if m == nil {
		set_statusf("There is no macro called %s", name)
		return false
	}
	if t, _ := macro_trigger(m); t != .Hotkey {
		set_statusf("%s is a layer effect (%s): add it to a layer, or set its Start node's Trigger to On Hotkey", m.name, macro_trigger_text(m))
		return false
	}
	return macro_run_report(m)
}

// When macro `m` runs (its Start node's Trigger), and the Seconds the timed triggers wait. On Hotkey in an app without
// layer effects, and for a macro saved before triggers existed.
macro_trigger :: proc(m: ^Macro) -> (t: Macro_Trigger, seconds: f64) {
	seconds = MACRO_TRIGGER_SECONDS
	if m == nil || !macro_layer_effects do return
	id := macro_start(m)
	if id <= 0 do return
	def := macro_def_find(MACRO_START)
	vals := macro_node_own_values(macro_node(m, id), def)
	for &s, i in def.settings {
		switch s.key {
		case "trigger":
			t = Macro_Trigger(clamp(int(vals[i].num), 0, len(Macro_Trigger) - 1))
		case "seconds":
			seconds = max(vals[i].num, MACRO_TRIGGER_MIN_SECONDS)
		}
	}
	return
}

// The trigger as words, with its Seconds: "On Paint", "After a 2 s pause", "Every 5 s" (temp memory).
macro_trigger_text :: proc(m: ^Macro) -> string {
	return macro_trigger_words(macro_trigger(m))
}

// A trigger and its Seconds as words (temp memory).
macro_trigger_words :: proc(t: Macro_Trigger, s: f64) -> string {
	#partial switch t {
	case .Pause:
		return fmt.tprintf("After a %s s pause", macro_num_text(s))
	case .Timer:
		return fmt.tprintf("Every %s s", macro_num_text(s))
	}
	return MACRO_TRIGGER_NAMES[t]
}

// The Start node's description for its Trigger: when the macro runs, then where it can be added.
macro_start_help :: proc(t: Macro_Trigger, s: f64) -> string {
	BEGIN :: "Where the macro begins: its Document wire leads through the steps, in order."
	HOTKEY_PLACES :: "\nAdd it to:\n- A tool group: the group's + button, then Macros. Clicking the group or pressing its key runs it.\n- The Macros menu, which lists it already.\n- Macros > Manage Macros, where its Run button runs it."
	LAYER_PLACES :: "\nAdd it to:\n- A layer: Layer > Layer Effects, or right-click the layer, then Layer Effects.\nTool groups and the Macros menu don't offer it: set the Trigger to On Hotkey for those."
	switch t {
	case .Hotkey:
		return BEGIN + " On Hotkey: it runs when you run it, as one undo step.\n" + HOTKEY_PLACES
	case .Paint:
		return BEGIN + " On Paint: a live layer effect that runs after every change to the layer it's on.\n" + LAYER_PLACES
	case .Pause:
		return fmt.tprintf("%s After a Pause: a live layer effect that runs once the layer it's on has been left alone for %s s.\n%s", BEGIN, macro_num_text(s), LAYER_PLACES)
	case .Timer:
		return fmt.tprintf("%s Every N Seconds: a live layer effect that runs at most once every %s s while the layer it's on keeps changing.\n%s", BEGIN, macro_num_text(s), LAYER_PLACES)
	case .Demand:
		return BEGIN + " On Demand: a live layer effect that runs when it's added, once you stop painting on the layer, and when you click the circling arrow by the layer's fx.\n" + LAYER_PLACES
	}
	return BEGIN
}

// Is `m` a live layer effect rather than run by the user?
macro_is_layer_effect :: proc(m: ^Macro) -> bool {
	t, _ := macro_trigger(m)
	return t != .Hotkey
}

// Runs a macro and reports the result in the status bar.
macro_run_report :: proc(m: ^Macro) -> bool {
	ok, msg, _ := macro_run(m)
	if ok {
		set_statusf("Ran macro %s", m.name)
	} else {
		set_statusf("Macro %s stopped. %s", m.name, msg)
	}
	return ok
}

// Number setting `i` as an int, rounded.
macro_int :: proc(args: []Macro_Value, i: int) -> int {
	return int(math.round(args[i].num))
}

macro_bool :: proc(args: []Macro_Value, i: int) -> bool {
	return args[i].num != 0
}

// ---------------------------------------------------------------------------
// Recording: each command the user runs becomes the next node of a new macro
// ---------------------------------------------------------------------------

MACRO_REC_STEP :: 220 // horizontal space between recorded nodes

macro_rec: ^Macro // the macro being recorded, or nil
macro_rec_last: int // the node recorded last (the Start node at first)

macro_recording :: proc() -> bool {
	return macro_rec != nil
}

macro_record_start :: proc() {
	macro_free(macro_rec)
	macro_rec = macro_new("Recorded")
	macro_rec_last = macro_start(macro_rec)
}

// Ends the recording. Returns the recorded macro (the caller owns it), or nil if nothing was recorded.
macro_record_stop :: proc() -> ^Macro {
	m := macro_rec
	macro_rec = nil
	if m != nil && len(m.nodes) <= 1 {
		macro_free(m)
		return nil
	}
	return m
}

// Adds a node to the recording, if one is going and no macro is running. `args` are key, value pairs.
macro_record :: proc(kind: string, args: ..string) {
	if macro_rec == nil || macro_running do return
	m := macro_rec
	n := macro_add_node(m, kind, f32(len(m.nodes)) * MACRO_REC_STEP, 0)
	for i := 0; i + 1 < len(args); i += 2 {
		macro_set_arg(m, n, args[i], args[i + 1])
	}
	macro_link(m, macro_rec_last, n.id)
	macro_rec_last = n.id
}
