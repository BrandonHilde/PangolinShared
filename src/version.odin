package pangolin

import "core:fmt"

// Each app sets APP_NAME and APP_VERSION (brand.odin). The build passes the git commit it was made from:
// -define:APP_COMMIT=1a2b3c4 (build.sh / build.bat); a build without it just leaves it out.
APP_COMMIT :: #config(APP_COMMIT, "")

// "Pangolin Paints 0.9.0-beta (1a2b3c4)"
app_version_line :: proc() -> string {
	if APP_COMMIT == "" do return fmt.tprintf("%s %s", APP_NAME, APP_VERSION)
	return fmt.tprintf("%s %s (%s)", APP_NAME, APP_VERSION, APP_COMMIT)
}

// --version: what this is, and where it keeps the user's files (for bug reports).
version_print :: proc() {
	fmt.println(app_version_line())
	fmt.printfln("Settings, workspaces and macros: %s", gfx_data_dir())
}

// "0.9.0-beta (1a2b3c4)", for the About box.
app_version_short :: proc() -> string {
	if APP_COMMIT == "" do return APP_VERSION
	return fmt.tprintf("%s (%s)", APP_VERSION, APP_COMMIT)
}
