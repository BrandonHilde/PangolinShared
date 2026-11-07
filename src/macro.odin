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
//
// The Document wire runs from the Start node through the action nodes and sets their order (`flows`). Value wires
// (`wires`) feed a node's settings from value nodes (Number, Color, Math, Random, Document Info ...), each of which is
// worked out once per run. Every node keeps its settings as text (key = value), so a file always loads, even with
// nodes or settings this version doesn't know.

MACRO_MAX_STEPS :: 10000 // nodes one run may execute
MACRO_START :: "flow.start"

Macro_Type :: enum u8 {
	Number,
	Bool,
	Color,
	Choice,
	Text,
}

Macro_Value :: struct {
	num:  f64, // Number; Bool as 0 or 1; Choice as the index into the setting's choices
	col:  Color,
	text: string,
}

Macro_Setting :: struct {
	key:     string, // name in the file: lower case, no spaces
	name:    string, // shown in the editor
	type:    Macro_Type,
	lo, hi:  f64, // Number range (lo == hi: any number)
	div:     f64, // a Number is shown as num / div (0: as it is)
	suffix:  string,
	choices: []string,
	def:     Macro_Value,
	help:    string,
}

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

// The Document wire goes from node `from` to node `to`. A node has at most one going out and one coming in.
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

// Joins `from` to `to` with the Document wire, replacing the wires that left `from` and reached `to` before.
macro_link :: proc(m: ^Macro, from, to: int) {
	macro_unlink(m, from, to)
	append(&m.flows, Macro_Flow{from, to})
}

// Removes the Document wires leaving `from` and reaching `to` (either may be 0: none).
macro_unlink :: proc(m: ^Macro, from, to: int) {
	#reverse for f, i in m.flows {
		if (from != 0 && f.from == from) || (to != 0 && f.to == to) do ordered_remove(&m.flows, i)
	}
}

// The node the Document wire goes to after `id`, or -1.
macro_next :: proc(m: ^Macro, id: int) -> int {
	for f in m.flows do if f.from == id do return f.to
	return -1
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

// The action nodes from Start to the end of the Document wire, in order. Fails on a loop, an unknown node or a wire
// to nothing.
macro_chain :: proc(m: ^Macro) -> (chain: []^Macro_Node, ok: bool, msg: string) {
	out := make([dynamic]^Macro_Node, context.temp_allocator)
	start := macro_start(m)
	switch start {
	case -1:
		return nil, false, "it has no Start node"
	case -2:
		return nil, false, "it has more than one Start node"
	}
	at := macro_next(m, start)
	for at >= 0 {
		n := macro_node(m, at)
		if n == nil do return nil, false, "a wire leads to a node that isn't there"
		def := macro_def_find(n.kind)
		if def == nil do return nil, false, fmt.tprintf("this version has no \"%s\" node", n.kind)
		if def.kind != .Action do return nil, false, fmt.tprintf("%s can't be on the Document wire", def.name)
		for prev in out do if prev == n do return nil, false, "its Document wire goes round in a loop"
		if len(out) >= MACRO_MAX_STEPS do return nil, false, "it has too many steps"
		append(&out, n)
		at = macro_next(m, at)
	}
	return out[:], true, ""
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
	shared_def({id = MACRO_START, name = "Start", category = "Flow", kind = .Start, help = "Where the macro begins: its Document wire leads through the steps, in order. Each macro has one."})
	shared_def({id = "value.Number", name = "Number", category = "Values", kind = .Value, out = .Number, help = "A number, for the settings of other nodes."},
		{key = "value", name = "Value", type = .Number, help = ANY_NUMBER})
	shared_def({id = "value.Bool", name = "On / Off", category = "Values", kind = .Value, out = .Bool, help = "On or off, for the settings of other nodes."},
		{key = "value", name = "On", type = .Bool, def = {num = 1}, help = "On, or off."})
	shared_def({id = "value.Color", name = "Color", category = "Values", kind = .Value, out = .Color, help = "A color, for the settings of other nodes."},
		{key = "color", name = "Color", type = .Color, def = {col = {0, 0, 0, 255}}, help = "The color, as #rrggbb or #rrggbbaa."})
	shared_def({id = "value.Text", name = "Text", category = "Values", kind = .Value, out = .Text, help = "Text, such as a file name or a layer name, for the settings of other nodes."},
		{key = "text", name = "Text", type = .Text, help = "The text."})
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
	case "value.Number", "value.Bool", "value.Color", "value.Text":
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
	case .Text:
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

// The node's settings as values, in the order of `def.settings` (temp memory): from the wire feeding the setting, else
// from the node. A setting the node doesn't store, or stores as text that doesn't fit, takes its default.
macro_node_values :: proc(r: ^Macro_Run, n: ^Macro_Node, def: ^Macro_Def) -> (vals: []Macro_Value, ok: bool, msg: string) {
	vals = make([]Macro_Value, len(def.settings), context.temp_allocator)
	for &s, i in def.settings {
		vals[i] = s.def
		if from := macro_wire_from(r.m, n.id, s.key); from != 0 {
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
	if bok, bmsg := macro_begin(); !bok do return false, bmsg, 0
	macro_running = true
	defer macro_running = false
	run := macro_run_state(m)
	for n in chain {
		def := macro_def_find(n.kind)
		args, aok, amsg := macro_node_values(&run, n, def)
		if !aok {
			macro_end(false)
			return false, fmt.tprintf("%s: %s", def.name, amsg), n.id
		}
		if eok, emsg := macro_exec(def, args); !eok {
			macro_end(false)
			return false, fmt.tprintf("%s: %s", def.name, emsg != "" ? emsg : "it didn't work"), n.id
		}
	}
	macro_end(true)
	return true, "", 0
}

// Runs a macro from the library by name and reports the result in the status bar.
macro_run_named :: proc(name: string) -> bool {
	m := macro_find(name)
	if m == nil {
		set_statusf("There is no macro called %s", name)
		return false
	}
	return macro_run_report(m)
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
