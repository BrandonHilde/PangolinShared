package pangolin

// The UI scale, and the View > UI Scale window: Auto, or a slider. Nothing about the window limits it: panels
// have CSS max-width / max-height (assets/ui/theme.css), so a very large interface stays usable.

UI_SCALE_MIN :: 50
UI_SCALE_MAX :: 500
UI_SCALE_STEP :: 5
UI_SCALE_AUTO_STEP :: 25
// Auto aims to show about this much logical space on a full screen.
UI_AUTO_W :: 1280
UI_AUTO_H :: 720

ui_scale_pref := 0 // percent; 0 is Auto
ui_scale_arg := 0 // --scale, for this run only: never saved

// A scale read from the preferences or the command line. 0 is Auto; 1-4 are the whole multiples
// older versions stored.
ui_scale_parse :: proc(v: int) -> int {
	switch {
	case v <= 0:
		return 0
	case v <= 4:
		return v * 100
	}
	return clamp(v, UI_SCALE_MIN, UI_SCALE_MAX)
}

// What Auto picks for a display: as large as still shows about 1280 x 720, and at least what the
// system's display settings ask for.
ui_scale_auto :: proc(display_w, display_h: int, system_scale: f32 = 1) -> int {
	pct := min(display_w * 100 / UI_AUTO_W, display_h * 100 / UI_AUTO_H) / UI_SCALE_AUTO_STEP * UI_SCALE_AUTO_STEP
	asked := (int(system_scale * 100 + 0.5) + UI_SCALE_AUTO_STEP / 2) / UI_SCALE_AUTO_STEP * UI_SCALE_AUTO_STEP
	return clamp(max(pct, asked), 100, UI_SCALE_MAX)
}

// The scale in use, in percent.
ui_scale_wanted :: proc() -> int {
	if ui_scale_arg > 0 do return ui_scale_arg
	if ui_scale_pref > 0 do return ui_scale_pref
	return ui_scale_auto(gfx_display_info())
}

@(private = "file")
ui_scale_drag := false
@(private = "file")
ui_scale_shown := 0

// The window's body. The interface takes a new size when the slider is let go: the window itself
// changes size, and would otherwise move out from under the pointer.
dlg_ui_scale :: proc() {
	c := dialog_frame("UI Scale", 240, 84)
	if !ui_scale_drag do ui_scale_shown = ui_scale_wanted()
	automatic := ui_scale_pref == 0 && ui_scale_arg == 0 && !ui_scale_drag
	if checkbox(c.x, c.y + 1, "Auto", &automatic, {"Auto", "Size the interface to the screen this window is on."}) {
		ui_scale_arg, ui_scale_pref = 0, automatic ? 0 : ui_scale_wanted()
	}
	sr := Rect{c.x + 52, c.y, c.w - 52, 14}
	tip := Tip{"UI Scale", "How large the whole interface is drawn: its text, icons and panels. Your work is not affected. Drag, or use the mouse wheel."}
	if slider(sr, &ui_scale_shown, UI_SCALE_MIN, UI_SCALE_MAX, "", tip, "%", step = UI_SCALE_STEP) {
		ui_scale_drag = true
	}
	if ui_scale_drag && !ui.down[0] {
		ui_scale_drag = false
		ui_scale_arg, ui_scale_pref = 0, ui_scale_shown
	}
	r := Rect{c.x + c.w - 64, c.y + c.h - 18, 64, 18}
	close := button_primary(r, "Close", {"", "Close this window (Enter or Esc). The size is already applied."})
	if ui.focus_id == 0 && !popup.open {
		if IsKeyPressed(.ENTER) || IsKeyPressed(.KP_ENTER) || IsKeyPressed(.ESCAPE) do close = true
	}
	if close do dialog_close()
}
