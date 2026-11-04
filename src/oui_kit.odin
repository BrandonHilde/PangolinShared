package pangolin

import "core:fmt"
import "core:math"

import oui "odinui:odinui"

// ---------------------------------------------------------------------------
// Controls built on OdinUI nodes: the behaviour of the hand-drawn widgets (curved sliders with
// Shift steps and the wheel, combos that cycle with the wheel and open our popups), the look
// from the theme. Keys default to the label; `w` is a default width the theme can override
// (it becomes --w, which the theme's width rules read).
// ---------------------------------------------------------------------------

oui_last: ^oui.Node // the control the kit built last

@(private = "file")
width_style :: proc(w: i32) -> string {
	return w > 0 ? fmt.tprintf("--w:%dpx", w) : ""
}

// Slider with the value inside it, like `slider`.
oslider :: proc(label: string, w: i32, v: ^int, lo, hi: int, tip: Tip, suffix := "", curve: f32 = 1, div := 1, key := "", class := "", id := "") -> bool {
	k := key != "" ? key : fmt.tprintf("s:%s", label)
	n := oui.element(uictx, k, "slider-bar", {id = id, class = class, style = width_style(w), interactive = true})
	defer oui.end(uictx)
	oui_last = n
	r := oui_rect(n)
	changed := false
	if n.active && r.w > 1 {
		t := clamp(f32(ui.mx - r.x) / f32(max(r.w - 1, 1)), 0, 1)
		if curve != 1 do t = math.pow(t, curve)
		nv := clamp(lo + int(t * f32(hi - lo) + 0.5), lo, hi)
		if ui.shift do nv = slider_chunk(nv, lo, hi, suffix, curve)
		if nv != v^ {
			v^ = nv
			changed = true
		}
	}
	if n.hovered && ui.wheel != 0 {
		step := curve != 1 ? max(v^ / 10, 1) : 1
		nv := clamp(v^ + (ui.wheel > 0 ? step : -step), lo, hi)
		if ui.shift do nv = slider_chunk(v^, lo, hi, suffix, curve, ui.wheel > 0 ? 1 : -1)
		if nv != v^ {
			v^ = nv
			changed = true
		}
	}
	frac := clamp(f32(v^ - lo) / f32(max(hi - lo, 1)), 0, 1)
	if curve != 1 do frac = math.pow(frac, 1 / curve)
	oui.element_leaf(uictx, "fill", "bar-fill", {style = fmt.tprintf("width:%.2f%%", frac * 100)})
	// the handle sits just inside the fill's end, and inside the bar at both ends
	hx := clamp(f32(r.w) * frac - 2, 1, f32(r.w) - 3)
	oui.element_leaf(uictx, "handle", "bar-handle", {style = fmt.tprintf("left:%.1fpx", hx)})
	vs := div > 1 ? fmt.tprintf("%.*f", div >= 100 ? 2 : 1, f32(v^) / f32(div)) : fmt.tprintf("%d", v^)
	oui.label(uictx, "value", label == "" ? fmt.tprintf("%s%s", vs, suffix) : fmt.tprintf("%s: %s%s", label, vs, suffix))
	oui_tip(n, tip)
	return changed
}

// Text button; `highlight` shows it toggled on.
obutton :: proc(label: string, w: i32, tip: Tip, enabled := true, highlight := false, key := "", class := "", id := "") -> bool {
	k := key != "" ? key : fmt.tprintf("b:%s", label)
	n := oui.button_begin(uictx, k, {id = id, class = class == "" ? "btn" : fmt.tprintf("btn %s", class), style = width_style(w), checked = highlight, disabled = !enabled})
	oui.label(uictx, "t", label)
	oui.end(uictx)
	oui_last = n
	oui_tip(n, tip_for_label(tip, label))
	return n.clicked && enabled
}

// Drop-down selector, like `combo`: returns the picked index (one frame after the click); the
// wheel or up / down while hovered steps through the items.
ocombo :: proc(key: string, w: i32, items: []string, cur: int, tip: Tip, id := "") -> (new_val: int, changed: bool) {
	nid := make_id({}, key) // popup owner
	is_open := popup.open && popup.owner == nid
	n := oui.button_begin(uictx, key, {id = id, class = is_open ? "combo open" : "combo", style = width_style(w)})
	oui.label(uictx, "t", cur >= 0 && cur < len(items) ? items[cur] : "", {class = "combo-text"})
	oui.label(uictx, "caret", icon_text(.Down), {class = "icon combo-caret"})
	oui.end(uictx)
	oui_tip(n, tip)
	if ui.popup_result_id == nid {
		ui.popup_result_id = 0
		return ui.popup_result_val, true
	}
	if len(items) > 1 {
		dir := 0
		if n.hovered && ui.wheel != 0 {
			dir = ui.wheel > 0 ? -1 : 1
		} else if n.hovered || is_open {
			if IsKeyPressed(.UP) do dir = -1
			else if IsKeyPressed(.DOWN) do dir = 1
		}
		if dir != 0 {
			if is_open do popup_close()
			nv := clamp(cur + dir, 0, len(items) - 1)
			if nv != cur do return nv, true
			return
		}
	}
	if n.clicked {
		r := oui_rect(n)
		popup_begin(nid, r, r.w)
		for it, i in items do popup_item(it, i, checked = i == cur, tip = tip.desc)
	}
	return
}

ocombo_enum :: proc(key: string, w: i32, names: [$E]string, v: ^E, tip: Tip) -> bool {
	items: [len(E)]string
	for nm, i in names do items[i] = nm
	nv, ch := ocombo(key, w, items[:], int(v^), tip)
	if ch do v^ = E(nv)
	return ch
}

// Checkbox with its label; clicking either toggles it.
ocheck :: proc(label: string, v: ^bool, tip: Tip, key := "") -> bool {
	k := key != "" ? key : fmt.tprintf("c:%s", label)
	n := oui.button_begin(uictx, k, {class = "check", checked = v^})
	oui.element(uictx, "box", "check-box", {checked = v^})
	if v^ do oui.label(uictx, "mark", icon_text(.Check), {class = "icon"})
	oui.end(uictx)
	oui.label(uictx, "t", label)
	oui.end(uictx)
	oui_tip(n, tip_for_label(tip, label))
	if n.clicked {
		v^ = !v^
		return true
	}
	return false
}

// Dim help text.
ohint :: proc(s: string, key := "hint") {
	oui.label(uictx, key, s, {class = "hint"})
}

// A plain label.
otext :: proc(key, s: string, class := "", tip := Tip{}) {
	oui_tip(oui.label(uictx, key, s, {class = class}), tip)
}

// An icon on its own (not a button), coloured by `class` in the theme.
oicon :: proc(key: string, ic: Icon, class := "", tip := Tip{}) {
	oui_tip(oui.label(uictx, key, icon_text(ic), {class = class == "" ? "icon" : fmt.tprintf("icon %s", class)}), tip)
}

// A colour chip button showing `c`.
oswatch_button :: proc(key: string, c: Color, tip: Tip, w: i32 = 0) -> bool {
	n := oui.button_begin(uictx, key, {class = "swatch-btn", style = fmt.tprintf("background:#%02x%02x%02x;%s", c.r, c.g, c.b, width_style(w))})
	oui.end(uictx)
	oui_tip(n, tip)
	return n.clicked
}
