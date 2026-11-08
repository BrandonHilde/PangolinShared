package pangolin

import "core:fmt"
import "core:os"
import "core:strings"

// Recently opened and saved files, newest first, for the File menu's recent files. Saved with the file browser's
// preferences (files_prefs_write / files_prefs_read), one `recent_file=` line each. Each app adds a file when it opens
// or saves one (recent_add) and shows the list in its File menu; picking one calls the app's open_path.

RECENT_FILES_MAX :: 10

recent_files: [dynamic]string

@(private = "file")
same_path :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x == '\\' do x = '/'
		if y == '\\' do y = '/'
		if x >= 'A' && x <= 'Z' do x += 32
		if y >= 'A' && y <= 'Z' do y += 32
		if x != y do return false
	}
	return true
}

// Puts `path` at the top of the list (moving it there if it is on it already).
recent_add :: proc(path: string) {
	if path == "" do return
	recent_remove(path)
	inject_at(&recent_files, 0, strings.clone(path))
	for len(recent_files) > RECENT_FILES_MAX do delete(pop(&recent_files))
}

recent_remove :: proc(path: string) {
	#reverse for f, i in recent_files {
		if same_path(f, path) {
			delete(f)
			ordered_remove(&recent_files, i)
		}
	}
}

recent_clear :: proc() {
	for f in recent_files do delete(f)
	clear(&recent_files)
}

// Opens recent file `i`. A file that is not there any more comes off the list.
recent_open :: proc(i: int) {
	if i < 0 || i >= len(recent_files) do return
	p := strings.clone(recent_files[i], context.temp_allocator)
	if !os.exists(p) {
		recent_remove(p)
		set_statusf("%s is not there any more, so it came off the recent files", path_basename(p))
		return
	}
	open_path(p)
}

recent_prefs_write :: proc(sb: ^strings.Builder) {
	for f in recent_files do fmt.sbprintf(sb, "recent_file=%s\n", f)
}

recent_prefs_read :: proc(key, val: string) -> bool {
	if key != "recent_file" do return false
	if val != "" && len(recent_files) < RECENT_FILES_MAX do append(&recent_files, strings.clone(val))
	return true
}
