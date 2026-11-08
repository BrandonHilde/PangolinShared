package pangolin

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// .pmacro files: one per macro, in the app's macros folder. Plain text, one item per line:
//
//   pangolin-macro 1
//   app paints
//   name Soft outline
//   node 1 flow.start @0,0
//   node 2 cmd.Select_Alpha @200,0
//   node 3 sel.Grow @400,0 px=4
//   node 4 file.Export @600,0 path="{dir}/{name} soft.png" quality=90
//   flow 1 2
//   flow 2 3
//   flow 3 4
//   node 5 value.Number @400,160 value=4
//   wire 5 3.px
//
// `flow` lines are the Document wire; `wire a b.key` feeds setting `key` of node b from value node a. A value with
// spaces, quotes or = is quoted, with \" and \\ inside. Lines this version doesn't know are skipped.

MACRO_EXT :: ".pmacro"
MACRO_VERSION :: 1
MACRO_MAX :: 200 // macros loaded from the folder

macro_lib: [dynamic]^Macro // the app's macros, sorted by name
macro_lib_gen: int // goes up whenever a macro in the library changes, comes or goes

macro_to_text :: proc(m: ^Macro) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "pangolin-macro %d\napp %s\nname %s\n", MACRO_VERSION, m.app, m.name)
	for &n in m.nodes {
		fmt.sbprintf(&sb, "node %d %s @%s,%s", n.id, n.kind, macro_num_text(f64(n.x)), macro_num_text(f64(n.y)))
		for a in n.args {
			fmt.sbprintf(&sb, " %s=%s", a.key, macro_quote(a.val))
		}
		strings.write_byte(&sb, '\n')
	}
	for f in m.flows {
		fmt.sbprintf(&sb, "flow %d %d\n", f.from, f.to)
	}
	for w in m.wires {
		fmt.sbprintf(&sb, "wire %d %d.%s\n", w.from, w.to, w.key)
	}
	return strings.to_string(sb)
}

@(private = "file")
macro_quote :: proc(s: string) -> string {
	plain := s != ""
	for r in s {
		if r == ' ' || r == '"' || r == '=' || r == '\\' || r == '\t' || r < ' ' do plain = false
	}
	if plain do return s
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '"')
	for r in s {
		switch r {
		case '"', '\\':
			strings.write_byte(&sb, '\\')
			strings.write_rune(&sb, r)
		case '\n', '\r':
			strings.write_byte(&sb, ' ') // a value is one line
		case:
			strings.write_rune(&sb, r)
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// Splits a line into words; a quoted value (after `key=` or alone) keeps its spaces. Temp memory.
@(private = "file")
macro_words :: proc(line: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	in_word, quoted, escaped := false, false, false
	for r in line {
		switch {
		case escaped:
			strings.write_rune(&sb, r)
			escaped = false
		case quoted && r == '\\':
			escaped = true
		case r == '"':
			quoted = !quoted
			in_word = true
		case !quoted && (r == ' ' || r == '\t'):
			if in_word {
				append(&out, strings.clone(strings.to_string(sb), context.temp_allocator))
				strings.builder_reset(&sb)
				in_word = false
			}
		case:
			strings.write_rune(&sb, r)
			in_word = true
		}
	}
	if in_word do append(&out, strings.clone(strings.to_string(sb), context.temp_allocator))
	return out[:]
}

// Reads a macro file's text. The caller owns the macro.
macro_from_text :: proc(text: string) -> (m: ^Macro, ok: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) == 0 || !strings.has_prefix(strings.trim_space(lines[0]), "pangolin-macro") do return nil, false
	m = macro_new_empty("Macro")
	if m == nil do return nil, false
	m.app = ""
	for raw in lines[1:] {
		line := strings.trim_space(raw)
		switch {
		case strings.has_prefix(line, "app "):
			m.app = strings.clone(strings.trim_space(line[4:]), macro_alloc(m))
		case strings.has_prefix(line, "name "):
			macro_set_name(m, strings.trim_space(line[5:]))
		case strings.has_prefix(line, "node "):
			w := macro_words(line)
			if len(w) < 3 do continue
			id, iok := strconv.parse_int(w[1])
			if !iok || id <= 0 || macro_node(m, id) != nil do continue
			x, y: f32
			rest := w[3:]
			if len(w) > 3 && strings.has_prefix(w[3], "@") {
				xs, _, ys := strings.partition(w[3][1:], ",")
				xv, _ := strconv.parse_f64(xs)
				yv, _ := strconv.parse_f64(ys)
				x, y = f32(xv), f32(yv)
				rest = w[4:]
			}
			n := macro_add_node(m, w[2], x, y, id)
			for kv in rest {
				k, _, v := strings.partition(kv, "=")
				if k != "" do macro_set_arg(m, n, k, v)
			}
		case strings.has_prefix(line, "flow "):
			w := macro_words(line)
			if len(w) < 3 do continue
			a, aok := strconv.parse_int(w[1])
			b, bok := strconv.parse_int(w[2])
			if aok && bok do macro_link(m, a, b)
		case strings.has_prefix(line, "wire "):
			w := macro_words(line)
			if len(w) < 3 do continue
			a, aok := strconv.parse_int(w[1])
			bs, _, key := strings.partition(w[2], ".")
			b, bok := strconv.parse_int(bs)
			if aok && bok && key != "" do macro_wire(m, a, b, key)
		}
	}
	return m, true
}

// ---------------------------------------------------------------------------
// The macros folder
// ---------------------------------------------------------------------------

// A name that can go in a file name and in the prefs (whose fields are split on : ; and ,).
macro_clean_name :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in strings.trim_space(s) {
		switch r {
		case '\\', '/', ':', '*', '?', '"', '<', '>', '|', ';', ',':
		case:
			if r >= ' ' do strings.write_rune(&sb, r)
		}
	}
	return strings.trim_space(strings.to_string(sb))
}

macro_path :: proc(name: string) -> string {
	return fmt.tprintf("%s%s%s", macro_dir(), name, MACRO_EXT)
}

macro_find :: proc(name: string) -> ^Macro {
	for m in macro_lib do if strings.equal_fold(m.name, name) do return m
	return nil
}

// `base`, or `base 2`, `base 3` ... whichever no macro has yet.
macro_unique_name :: proc(base: string) -> string {
	b := macro_clean_name(base)
	if b == "" do b = "Macro"
	if macro_find(b) == nil do return b
	for i in 2 ..< 10000 {
		n := fmt.tprintf("%s %d", b, i)
		if macro_find(n) == nil do return n
	}
	return b
}

@(private = "file")
macro_lib_sort :: proc() {
	slice.sort_by(macro_lib[:], proc(a, b: ^Macro) -> bool {
		return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
	})
}

macros_clear :: proc() {
	macro_lib_gen += 1
	for m in macro_lib do macro_free(m)
	clear(&macro_lib)
}

// Loads every macro of this app from the macros folder. A file's name is the macro's name.
macros_refresh :: proc() {
	macros_clear()
	files, err := os.read_directory_by_path(macro_dir(), -1, context.temp_allocator)
	if err != nil do return
	for f in files {
		if f.type == .Directory || lower_ext(f.name) != MACRO_EXT || len(macro_lib) >= MACRO_MAX do continue
		data, ok := read_file(f.fullpath)
		if !ok do continue
		m, mok := macro_from_text(string(data))
		delete(data)
		if !mok do continue
		name := macro_clean_name(path_stem(f.name))
		if m.app != macro_app_id() || name == "" || macro_find(name) != nil {
			macro_free(m)
			continue
		}
		macro_set_name(m, name)
		append(&macro_lib, m)
	}
	macro_lib_sort()
}

macro_save :: proc(m: ^Macro) -> bool {
	macro_lib_gen += 1
	os.make_directory_all(macro_dir())
	return write_file(macro_path(m.name), transmute([]u8)macro_to_text(m))
}

// Saves a new macro and adds it to the library, under a name no other macro has. The library owns it after this.
macro_add :: proc(m: ^Macro) -> bool {
	macro_set_name(m, macro_unique_name(m.name))
	if !macro_save(m) do return false
	append(&macro_lib, m)
	macro_lib_sort()
	return true
}

macro_delete :: proc(m: ^Macro) {
	macro_lib_gen += 1
	os.remove(macro_path(m.name))
	for x, i in macro_lib {
		if x == m {
			ordered_remove(&macro_lib, i)
			break
		}
	}
	macro_free(m)
}

macro_rename :: proc(m: ^Macro, name: string) -> (ok: bool, msg: string) {
	n := macro_clean_name(name)
	if n == "" do return false, "Enter a name for the macro"
	if other := macro_find(n); other != nil && other != m do return false, fmt.tprintf("There is already a macro called %s", n)
	old := strings.clone(m.name, context.temp_allocator)
	macro_set_name(m, n)
	if !macro_save(m) {
		macro_set_name(m, old)
		return false, "Could not write the macro file"
	}
	if !strings.equal_fold(old, n) do os.remove(macro_path(old))
	macro_lib_sort()
	return true, ""
}

// Copies a macro file into the library. Returns the new macro's name.
macro_import_file :: proc(path: string) -> (name: string, ok: bool, msg: string) {
	data, rok := read_file(path)
	if !rok do return "", false, fmt.tprintf("Cannot read %s", path_basename(path))
	defer delete(data)
	m, mok := macro_from_text(string(data))
	if !mok do return "", false, "This is not a macro file"
	if m.app != macro_app_id() {
		app := strings.clone(m.app, context.temp_allocator)
		macro_free(m)
		return "", false, fmt.tprintf("This macro was made in Pangolin %s", app)
	}
	macro_set_name(m, path_stem(path))
	if !macro_add(m) {
		macro_free(m)
		return "", false, "Could not write the macro file"
	}
	return m.name, true, ""
}

macro_export_file :: proc(m: ^Macro, path: string) -> bool {
	return write_file(path, transmute([]u8)macro_to_text(m))
}
