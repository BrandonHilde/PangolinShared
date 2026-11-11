package pangolin

import "core:fmt"
import "core:strconv"
import "core:strings"

import oui "odinui:odinui"

// ---------------------------------------------------------------------------
// Saveable presets: named settings for a tool, such as a brush, a stroke style or an effect's sliders.
// The app names a kind ("brush/Oil", "stroke"), gives its built-in presets, and passes the current settings as a
// list of ints plus an optional text (a font name). This file keeps the user's own presets, draws the preset combo
// and its menu (save as new, update, revert, rename, delete), asks for a name in place of the combo, and stores the
// user's presets with the prefs (files_prefs_write / files_prefs_read), one `preset=kind|name|1,2,3|text` line each.
// The app keeps the name of the preset picked last (per tool, per group); the combo shows it even after the
// settings change. Picking it again, or Revert, puts its settings back.
// ---------------------------------------------------------------------------

Preset_Value :: struct {
	vals: []int,
	text: string,
}

Preset_Builtin :: struct {
	name: string,
	vals: []int,
	text: string,
}

User_Preset :: struct {
	kind: string,
	name: string,
	vals: [dynamic]int,
	text: string,
}

user_presets: [dynamic]User_Preset

Preset_Naming :: enum {
	None,
	New,
	Rename,
}

@(private = "file")
pn: struct {
	mode:  Preset_Naming,
	kind:  Name, // the kind being named
	buf:   Name,
	old:   Name, // Rename: the preset's name before
	vals:  [dynamic]int, // New: the settings to save
	text:  Name,
	focus: bool, // give the name field the keyboard on its first frame
	row:   bool, // the field shows in the preset_row (a window), not the preset_bar: both can be on screen for one kind
}

PRESET_MENU_TIP :: "Save these settings as a preset of your own, or update, revert, rename or delete the preset picked."

// Index of the user's preset `name` of `kind` in user_presets, or -1.
preset_find :: proc(kind, name: string) -> int {
	for p, i in user_presets {
		if p.kind == kind && p.name == name do return i
	}
	return -1
}

// Saves a preset of the user's, replacing one of the same kind and name.
preset_store :: proc(kind, name: string, vals: []int, txt := "") {
	i := preset_find(kind, name)
	if i < 0 {
		append(&user_presets, User_Preset{kind = strings.clone(kind), name = strings.clone(name)})
		i = len(user_presets) - 1
	}
	p := &user_presets[i]
	clear(&p.vals)
	append(&p.vals, ..vals)
	delete(p.text)
	p.text = strings.clone(txt)
}

preset_remove :: proc(i: int) {
	if i < 0 || i >= len(user_presets) do return
	p := &user_presets[i]
	delete(p.kind)
	delete(p.name)
	delete(p.vals)
	delete(p.text)
	ordered_remove(&user_presets, i)
}

// The settings of preset `name` of `kind`: the user's, else the built-in one.
preset_value :: proc(kind, name: string, builtin: []Preset_Builtin) -> (v: Preset_Value, ok: bool) {
	if i := preset_find(kind, name); i >= 0 {
		return {user_presets[i].vals[:], user_presets[i].text}, true
	}
	for b in builtin {
		if b.name == name do return {b.vals, b.text}, true
	}
	return
}

// Do the settings match a preset's? A preset saved before a setting was added has fewer values; the ones it has count.
preset_same :: proc(p: Preset_Value, vals: []int, txt: string) -> bool {
	if p.text != txt do return false
	for i in 0 ..< min(len(p.vals), len(vals)) {
		if p.vals[i] != vals[i] do return false
	}
	return true
}

// Is `name` usable for a preset: not empty and no line breaks or `|`. Returns it tidied.
@(private = "file")
preset_clean_name :: proc(s: string) -> string {
	t := strings.trim_space(s)
	for i in 0 ..< len(t) {
		if t[i] == '|' || t[i] < 32 do return ""
	}
	return t
}

// Prefs ------------------------------------------------------------------------------------------------------

preset_prefs_write :: proc(sb: ^strings.Builder) {
	for p in user_presets {
		fmt.sbprintf(sb, "preset=%s|%s|", p.kind, p.name)
		for v, i in p.vals do fmt.sbprintf(sb, "%s%d", i > 0 ? "," : "", v)
		fmt.sbprintf(sb, "|%s\n", p.text)
	}
}

preset_prefs_read :: proc(key, val: string) -> bool {
	if key != "preset" do return false
	parts := strings.split_n(val, "|", 4, context.temp_allocator)
	if len(parts) < 3 || parts[0] == "" || parts[1] == "" do return true
	vals := make([dynamic]int, context.temp_allocator)
	if parts[2] != "" {
		for s in strings.split(parts[2], ",", context.temp_allocator) {
			v, _ := strconv.parse_int(strings.trim_space(s))
			append(&vals, v)
		}
	}
	preset_store(parts[0], parts[1], vals[:], len(parts) > 3 ? parts[3] : "")
	return true
}

// The combo's list and state -----------------------------------------------------------------------------------

@(private = "file")
Preset_List :: struct {
	names:    [dynamic]string, // built-in presets first, then the user's
	n_built:  int,
	cur:      int, // the picked preset's index in names, or -1
	user:     int, // the picked preset's index in user_presets, or -1
	modified: bool,
	shown:    string, // the combo's text
}

@(private = "file")
preset_list :: proc(kind: string, builtin: []Preset_Builtin, cur: ^Name, vals: []int, txt: string) -> (l: Preset_List) {
	l.names = make([dynamic]string, context.temp_allocator)
	l.cur, l.user = -1, -1
	cn := name_str(cur)
	for b, i in builtin {
		if b.name == cn do l.cur = i
		append(&l.names, b.name)
	}
	l.n_built = len(builtin)
	for p, i in user_presets {
		if p.kind != kind do continue
		if p.name == cn {
			l.cur, l.user = len(l.names), i // the user's preset wins over a built-in of the same name
		}
		append(&l.names, p.name)
	}
	if l.cur < 0 {
		l.shown = "Custom"
		return
	}
	pv, _ := preset_value(kind, cn, builtin)
	l.modified = !preset_same(pv, vals, txt)
	l.shown = cn // no mark once the settings change: a preset is a starting point, not something to keep in step
	return
}

@(private = "file")
preset_pick :: proc(kind: string, builtin: []Preset_Builtin, cur: ^Name, l: ^Preset_List, i: int) -> (Preset_Value, bool) {
	if i < 0 || i >= len(l.names) do return {}, false
	name := l.names[i]
	v, ok := preset_value(kind, name, builtin)
	if i < l.n_built {
		// a built-in, even when the user has one of the same name
		v, ok = Preset_Value{builtin[i].vals, builtin[i].text}, true
	}
	if ok do name_set(cur, name)
	return v, ok
}

@(private = "file")
preset_menu_open :: proc(owner: u32, anchor: Rect, l: ^Preset_List, cur: ^Name) {
	popup_begin(owner, anchor, 170)
	cn := name_str(cur)
	popup_item("Save as New Preset...", 1, tip = "Keep the current settings as a preset of your own, under a name you choose.")
	if l.cur >= 0 {
		popup_sep()
		user := l.user >= 0
		popup_item(fmt.tprintf("Update \"%s\"", cn), 2, enabled = user && l.modified, tip = "Store the current settings in this preset of yours.")
		popup_item(fmt.tprintf("Revert to \"%s\"", cn), 3, enabled = l.modified, tip = "Put back this preset's settings.")
		popup_item(fmt.tprintf("Rename \"%s\"...", cn), 4, enabled = user, tip = "Give this preset of yours another name.")
		popup_item(fmt.tprintf("Delete \"%s\"", cn), 5, enabled = user, tip = "Remove this preset of yours. The current settings stay as they are.")
	}
}

@(private = "file")
preset_menu_run :: proc(v: int, kind: string, builtin: []Preset_Builtin, cur: ^Name, l: ^Preset_List, vals: []int, txt: string, row: bool) -> (Preset_Value, bool) {
	switch v {
	case 1:
		preset_save_begin(kind, vals, txt, row)
	case 2:
		if l.user >= 0 {
			preset_store(kind, name_str(cur), vals, txt)
			prefs_save()
			set_statusf("Updated the preset \"%s\"", name_str(cur))
		}
	case 3:
		return preset_value(kind, name_str(cur), builtin)
	case 4:
		if l.user >= 0 {
			pn.mode = .Rename
			pn.row = row
			name_set(&pn.kind, kind)
			pn.buf = cur^
			pn.old = cur^
			pn.focus = true
		}
	case 5:
		preset_delete(kind, cur)
	}
	return {}, false
}

// Opens the name field of `kind`'s preset combo to save `vals` / `txt` as a new preset, for a Save as Preset
// button somewhere else, such as a settings window. `row`: in its preset_row, else in its preset_bar.
preset_save_begin :: proc(kind: string, vals: []int, txt := "", row := false) {
	pn.mode = .New
	pn.row = row
	name_set(&pn.kind, kind)
	pn.buf = {}
	clear(&pn.vals)
	append(&pn.vals, ..vals)
	name_set(&pn.text, txt)
	pn.focus = true
}

// Deletes the user's preset named in `cur`; false if `cur` names no preset of the user's (a built-in can't be deleted).
// The settings stay as they are, so the combo shows them as Custom.
preset_delete :: proc(kind: string, cur: ^Name) -> bool {
	i := preset_find(kind, name_str(cur))
	if i < 0 do return false
	set_statusf("Deleted the preset \"%s\"", name_str(cur))
	preset_remove(i)
	prefs_save()
	return true
}

// Takes the typed name. False keeps the name field open (the name can't be used).
@(private = "file")
preset_name_submit :: proc(builtin: []Preset_Builtin, cur: ^Name) -> bool {
	kind := name_str(&pn.kind)
	name := preset_clean_name(name_str(&pn.buf))
	if name == "" {
		set_status("Type a name for the preset (without |)")
		return false
	}
	for b in builtin {
		if b.name == name {
			set_statusf("\"%s\" is a built-in preset: choose another name", name)
			return false
		}
	}
	switch pn.mode {
	case .None:
	case .New:
		had := preset_find(kind, name) >= 0
		preset_store(kind, name, pn.vals[:], name_str(&pn.text))
		name_set(cur, name)
		set_statusf(had ? "Replaced the preset \"%s\"" : "Saved the preset \"%s\"", name)
	case .Rename:
		old := name_str(&pn.old)
		if name == old do break
		if preset_find(kind, name) >= 0 {
			set_statusf("There is a preset called \"%s\" already", name)
			return false
		}
		i := preset_find(kind, old)
		if i < 0 do break
		delete(user_presets[i].name)
		user_presets[i].name = strings.clone(name)
		if name_str(cur) == old do name_set(cur, name)
		set_statusf("Renamed the preset to \"%s\"", name)
	}
	prefs_save()
	return true
}

// Saves under the typed name and closes the name field, or keeps it open with the keyboard when the name can't be used.
@(private = "file")
preset_name_done :: proc(builtin: []Preset_Builtin, cur: ^Name) {
	if preset_name_submit(builtin, cur) {
		pn.mode = .None
	} else {
		pn.focus = true
	}
}

// Is the name field showing for `kind`?
preset_naming :: proc(kind: string, row := false) -> bool {
	return pn.mode != .None && pn.row == row && name_str(&pn.kind) == kind
}

preset_naming_cancel :: proc() {
	pn.mode = .None
}

@(private = "file")
NAME_TIP :: Tip{"Preset name", "Type a name, then press Enter or click Save. Esc cancels."}

// Options bar (OdinUI) -----------------------------------------------------------------------------------------

// The preset combo and its menu button, for the tool options bar. `cur` holds the name of the preset picked last
// and `vals` / `txt` the current settings. Returns the settings to apply when a preset is picked or reverted to.
preset_bar :: proc(kind: string, builtin: []Preset_Builtin, cur: ^Name, vals: []int, txt := "", w: i32 = 110, tip := Tip{}) -> (picked: Preset_Value, ok: bool) {
	key := fmt.tprintf("preset:%s", kind)
	if preset_naming(kind) {
		preset_bar_naming(key, builtin, cur, w)
		return
	}
	l := preset_list(kind, builtin, cur, vals, txt)
	t := tip.title != "" ? tip : Tip{"Preset", "A ready-made or saved group of settings for this tool. Picking one replaces the settings."}
	if nv, ch := ocombo(key, w, l.names[:], l.cur, t, shown = l.shown); ch {
		return preset_pick(kind, builtin, cur, &l, nv)
	}
	mid := make_id({}, fmt.tprintf("%s:menu", key))
	if obutton("...", 20, {"Preset menu", PRESET_MENU_TIP}, key = fmt.tprintf("%s:menu", key)) {
		preset_menu_open(mid, oui_rect(oui_last), &l, cur)
	}
	if ui.popup_result_id == mid {
		ui.popup_result_id = 0
		return preset_menu_run(ui.popup_result_val, kind, builtin, cur, &l, vals, txt, false)
	}
	return
}

@(private = "file")
preset_bar_naming :: proc(key: string, builtin: []Preset_Builtin, cur: ^Name, w: i32) {
	fkey := fmt.tprintf("%s:name", key)
	id := make_id({}, fkey)
	// a slider bar without its fill makes the field: text from the left, the accent ring while it has the keyboard
	ring := ui.focus_id == id ? "border-color:var(--accent);" : ""
	n := oui.element(uictx, fkey, "slider-bar", {style = fmt.tprintf("--w:%dpx;justify-content:flex-start;padding-left:4px;%s", w + 24, ring), interactive = true})
	r := oui_rect(n)
	if pn.focus {
		pn.focus = false
		ui.focus_id = id
		ui.sel_all = true
		ui.caret = pn.buf.n
		caret_show()
	}
	done := false
	if ui.focus_id == id {
		sub, _, cancel := edit_core(&pn.buf, r, id)
		if sub || cancel do slider_type_eat_keys()
		if cancel do pn.mode = .None
		if sub {
			preset_name_done(builtin, cur)
		}
	} else if n.hovered && ui.pressed[0] {
		ui.focus_id = id
		ui.caret = pn.buf.n
		caret_show()
	}
	focused := ui.focus_id == id
	s := name_str(&pn.buf)
	if focused && ui.sel_all && s != "" {
		oui.element_leaf(uictx, "fill", "bar-fill", {style = "width:100%"})
	}
	caret := focused && caret_on() ? "|" : ""
	if s == "" && !focused {
		oui.label(uictx, "value", "Preset name", {class = "hint", style = "margin-left:0"})
	} else {
		oui.label(uictx, "value", fmt.tprintf("%s%s", s, caret))
	}
	oui.end(uictx)
	oui_tip(n, NAME_TIP)
	if obutton("Save", 40, {"Save preset (Enter)", "Keep the preset under this name."}, key = fmt.tprintf("%s:save", key)) {
		preset_name_done(builtin, cur)
		done = true
	}
	if !done && obutton("Cancel", 48, {"Cancel (Esc)", "Leave the presets as they are."}, key = fmt.tprintf("%s:cancel", key)) {
		pn.mode = .None
		if ui.focus_id == id do ui.focus_id = 0
	}
}

// Dialogs (drawn by hand) --------------------------------------------------------------------------------------

// The same as preset_bar, laid out in `r` for a dialog: the combo with the menu button on its right.
preset_row :: proc(r: Rect, kind: string, builtin: []Preset_Builtin, cur: ^Name, vals: []int, txt := "", tip := Tip{}) -> (picked: Preset_Value, ok: bool) {
	if preset_naming(kind, true) {
		rr := r
		cancel_r := cut_right(&rr, 50)
		cut_right(&rr, 4)
		save_r := cut_right(&rr, 40)
		cut_right(&rr, 4)
		id := make_id(rr, "preset-name")
		if pn.focus {
			pn.focus = false
			ui.focus_id = id
			ui.sel_all = true
			ui.caret = pn.buf.n
			caret_show()
		}
		if ui_hover(rr) {
			ui.cursor = .IBEAM
			tooltip_hover(id, NAME_TIP)
		}
		if ui.focus_id == id {
			sub, _, cancel := edit_core(&pn.buf, rr, id)
			if sub || cancel do slider_type_eat_keys()
			if cancel do pn.mode = .None
			if sub {
				if preset_name_submit(builtin, cur) do pn.mode = .None
				else do pn.focus = true
			}
		} else if ui_hover(rr) && ui.pressed[0] {
			ui.focus_id = id
			ui.caret = pn.buf.n
			caret_show()
		}
		draw_edit_box(rr, &pn.buf, ui.focus_id == id)
		if pn.buf.n == 0 && ui.focus_id != id do text(rr.x + 4, rr.y + (rr.h - FONT_CAP) / 2, "Preset name", C_TEXT_DIM)
		if button(save_r, "Save", {"Save preset (Enter)", "Keep the preset under this name."}) {
			preset_name_done(builtin, cur)
		}
		if button(cancel_r, "Cancel", {"Cancel (Esc)", "Leave the presets as they are."}) {
			pn.mode = .None
			if ui.focus_id == id do ui.focus_id = 0
		}
		return
	}
	l := preset_list(kind, builtin, cur, vals, txt)
	rr := r
	menu_r := cut_right(&rr, 22)
	cut_right(&rr, 4)
	t := tip.title != "" ? tip : Tip{"Preset", "A ready-made or saved group of these settings. Picking one replaces them."}
	if nv, ch := combo(rr, l.names[:], l.cur, t, shown = l.shown); ch {
		return preset_pick(kind, builtin, cur, &l, nv)
	}
	mid := make_id(menu_r, "preset-menu")
	if button(menu_r, "...", {"Preset menu", PRESET_MENU_TIP}) {
		preset_menu_open(mid, menu_r, &l, cur)
	}
	if ui.popup_result_id == mid {
		ui.popup_result_id = 0
		return preset_menu_run(ui.popup_result_val, kind, builtin, cur, &l, vals, txt, true)
	}
	return
}
