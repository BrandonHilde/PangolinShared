package pangolin

import "core:fmt"
import "core:os"

// Whole-file reads and writes, for the apps' documents, settings, workspaces and macros.

read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, false
	}
	return d, true
}

// Writes beside the file, then renames over it: a full disk or a crash part way through leaves the file that was
// there, not a cut-off one. Only when no file can be made beside it (a folder that only lets its files be changed)
// is the file written directly.
write_file :: proc(path: string, data: []u8) -> bool {
	tmp := fmt.tprintf("%s.tmp~", path)
	if os.write_entire_file_from_bytes(tmp, data) != nil {
		if os.exists(tmp) {
			os.remove(tmp)
			return false
		}
		return os.write_entire_file_from_bytes(path, data) == nil
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// The file pickers of Linux (zenity, kdialog) hand back the name as it was typed: "drawing" would be saved without
// an extension, and then not open again. This adds `def_ext` ("svg") to a name that has none, unless a file of that
// name is already there (the picker asked about replacing the name as typed, not that one). Takes over `path`.
path_default_ext :: proc(path, def_ext: string) -> string {
	if path == "" || def_ext == "" do return path
	name := path
	for i := len(name) - 1; i >= 0; i -= 1 {
		if name[i] == '/' || name[i] == '\\' {
			name = name[i + 1:]
			break
		}
	}
	for i in 1 ..< len(name) do if name[i] == '.' do return path
	with := fmt.aprintf("%s.%s", path, def_ext)
	if os.exists(with) {
		delete(with)
		return path
	}
	delete(path)
	return with
}
