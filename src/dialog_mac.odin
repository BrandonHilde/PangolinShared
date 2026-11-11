#+build darwin
package pangolin

import "core:fmt"
import "core:os"
import "core:strings"

// macOS file dialogs: the system's own Open and Save panels, shown by osascript (AppleScript's `choose file`
// and `choose file name`), the way Linux runs zenity. Each app's native_dialog calls this on macOS.
// `filters` are the app's (name, "*.png;*.jpg" ...): an Open panel offers the first one's extensions (the
// panel has no list of filters to switch between); none, or "*.*", lets every file through.
native_dialog_mac :: proc(save: bool, title: string, filters: []Filter, def_ext, initial, dir: string) -> (path: string, ok: bool) {
	// where it starts: `dir`, or the folder of an `initial` that is a whole path
	start_dir := dir
	name := initial
	if i := strings.last_index_byte(initial, '/'); i >= 0 {
		if start_dir == "" do start_dir = initial[:i + 1]
		name = initial[i + 1:]
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "activate\n") // bring the panel in front of the app's window
	if save {
		fmt.sbprintf(&sb, "set f to choose file name with prompt %s", as_string(title))
		if name != "" do fmt.sbprintf(&sb, " default name %s", as_string(name))
	} else {
		fmt.sbprintf(&sb, "set f to choose file with prompt %s", as_string(title))
		if exts := mac_extensions(filters); len(exts) > 0 {
			strings.write_string(&sb, " of type {")
			for e, k in exts {
				if k > 0 do strings.write_string(&sb, ", ")
				strings.write_string(&sb, as_string(e))
			}
			strings.write_string(&sb, "}")
		}
	}
	if start_dir != "" && os.exists(start_dir) {
		fmt.sbprintf(&sb, " default location (POSIX file %s)", as_string(start_dir))
	}
	strings.write_string(&sb, "\nPOSIX path of f")
	state, out, _, err := os.process_exec({command = {"osascript", "-e", strings.to_string(sb)}}, context.temp_allocator)
	if err != nil {
		set_status("The file panel could not be shown (osascript failed to start)")
		return "", false
	}
	if state.exit_code != 0 do return "", false // cancelled
	p := strings.trim_space(string(out))
	if p == "" do return "", false
	if save do p = path_default_ext(p, def_ext)
	return strings.clone(p), true
}

// An AppleScript string literal.
@(private = "file")
as_string :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
	r, _ = strings.replace_all(r, "\"", "\\\"", context.temp_allocator)
	return fmt.tprintf("\"%s\"", r)
}

// The extensions of the first filter, without "*.": nil if it takes every file.
@(private = "file")
mac_extensions :: proc(filters: []Filter) -> []string {
	if len(filters) == 0 do return nil
	out := make([dynamic]string, context.temp_allocator)
	for g in strings.split(filters[0].pattern, ";", context.temp_allocator) {
		e := strings.trim_space(g)
		e = strings.trim_prefix(e, "*.")
		if e == "" || e == "*" do return nil
		append(&out, e)
	}
	return out[:]
}
