package pangolin

import "core:fmt"

// ---------------------------------------------------------------------------
// What the timelines have in common: tags, playback and the tags window. Each app's document has
//   frames (each with `duration`, in ms), tags and active_frame,
// and the app defines set_frame(i) and the commands .Tags and .Play. A frame's duration is at least 10 ms.
// ---------------------------------------------------------------------------

Tag_Dir :: enum u8 {
	Forward,
	Reverse,
	Ping_Pong,
}

TAG_DIR_NAMES := [Tag_Dir]string {
	.Forward   = "Forward",
	.Reverse   = "Reverse",
	.Ping_Pong = "Ping-Pong",
}

Tag :: struct {
	name:     Name,
	from, to: int,
	dir:      Tag_Dir,
	color:    Color,
}

playing: bool
play_timer: f32
play_dir := 1
play_tag := -1 // the tag being played, or -1 for every frame

stop_playback :: proc() {
	playing = false
	play_timer = 0
	play_dir = 1
}

// Range of frames used for playback.
play_range :: proc() -> (lo, hi: int, dir: Tag_Dir) {
	lo, hi = 0, len(doc.frames) - 1
	dir = .Forward
	if play_tag >= 0 && play_tag < len(doc.tags) {
		t := doc.tags[play_tag]
		lo = clamp(t.from, 0, len(doc.frames) - 1)
		hi = clamp(t.to, lo, len(doc.frames) - 1)
		dir = t.dir
	}
	return
}

playback_update :: proc(dt: f32) {
	if !playing do return
	lo, hi, dir := play_range()
	if lo == hi {
		set_frame(lo)
		return
	}
	// a frame that took long (a file dialog was open, the computer slept) doesn't play all it missed
	play_timer += min(dt, 0.25)
	for {
		dur := f32(max(doc.frames[doc.active_frame].duration, 10)) / 1000
		if play_timer < dur do break
		play_timer -= dur
		f := doc.active_frame
		if f < lo || f > hi {
			set_frame(dir == .Reverse ? hi : lo)
			continue
		}
		switch dir {
		case .Forward:
			f += 1
			if f > hi do f = lo
		case .Reverse:
			f -= 1
			if f < lo do f = hi
		case .Ping_Pong:
			f += play_dir
			if f > hi {
				play_dir = -1
				f = hi - 1
			} else if f < lo {
				play_dir = 1
				f = lo + 1
			}
		}
		set_frame(f)
	}
}

// The playback list and the Tags button, for the timeline's bar.
timeline_tag_controls :: proc() {
	d := doc
	tag_items := make([dynamic]string, context.temp_allocator)
	append(&tag_items, "All frames")
	for &t in d.tags do append(&tag_items, name_str(&t.name))
	if nv, ch := ocombo("tag", 100, tag_items[:], play_tag + 1, {"Playback range", "Play all frames, or only the frames of one tag. Export can use the same range."}); ch {
		play_tag = nv - 1
		if play_tag >= 0 && play_tag < len(d.tags) do set_frame(d.tags[play_tag].from)
	}
	if obutton("Tags", 38, {"", cmd_help(.Tags)}) do run_cmd(.Tags)
}

dlg_tags :: proc() {
	rows := max(len(doc.tags), 1)
	h := i32(70 + rows * 20)
	c := dialog_frame("Animation Tags", 440, h)
	y := c.y
	if len(doc.tags) == 0 {
		text(c.x, y + 3, "No tags yet. Tags name a range of frames for playback.", C_TEXT_DIM)
		y += 20
	}
	del := -1
	for &t, i in doc.tags {
		text_field(Rect{c.x, y, 100, 14}, &t.name, {"Tag name", "The name shown in the timeline's playback list."})
		tf := t.from + 1
		tt := t.to + 1
		tip_text(c.x + 108, y + 3, "from", C_TEXT_DIM, {"First frame", "The frame this tag starts on."})
		if field_int(Rect{c.x + 134, y, 36, 14}, &tf, 1, len(doc.frames), {"First frame", "The frame this tag starts on."}) {
			t.from = tf - 1
			if t.to < t.from do t.to = t.from
		}
		tip_text(c.x + 176, y + 3, "to", C_TEXT_DIM, {"Last frame", "The frame this tag ends on."})
		if field_int(Rect{c.x + 192, y, 36, 14}, &tt, 1, len(doc.frames), {"Last frame", "The frame this tag ends on."}) {
			t.to = tt - 1
			if t.from > t.to do t.from = t.to
		}
		combo_enum(Rect{c.x + 234, y, 80, 14}, TAG_DIR_NAMES, &t.dir, {"Direction", "How playback runs through this tag: forward, backward, or back and forth."})
		// the color swatch steps through hues
		sw := Rect{c.x + 320, y, 14, 14}
		fill_rect(sw, t.color)
		outline_rect(sw, C_BORDER)
		tip_area(sw, "tag-color", {"Tag color", "The color of this tag's bar in the timeline. Click for another one."})
		if in_rect(sw, ui.mx, ui.my) && ui.pressed[0] && ui.layer == ui.input_layer {
			hh, ss, vv := rgb_to_hsv(t.color)
			t.color = hsv_to_rgb(hh + 40, ss, vv)
		}
		if icon_button(Rect{c.x + 340, y, 16, 14}, .Trash, {"Delete tag", "Remove this tag. The frames stay as they are."}) do del = i
		y += 20
	}
	if del >= 0 {
		ordered_remove(&doc.tags, del)
		if play_tag >= len(doc.tags) do play_tag = -1
	}
	if button(Rect{c.x, c.y + c.h - 18, 80, 18}, "Add tag", {"Add tag", "Add a tag on the current frame. Change its name and range in the new row."}) {
		t := Tag {
			from  = doc.active_frame,
			to    = doc.active_frame,
			color = hsv_to_rgb(f32(len(doc.tags)) * 55, 0.6, 0.9),
		}
		name_set(&t.name, fmt.tprintf("Tag %d", len(doc.tags) + 1))
		append(&doc.tags, t)
	}
	ok, _ := dialog_buttons(c, "Close this window (Enter or Esc). Your changes are kept.", "Close", "")
	if ok {
		doc.modified = true
		dialog_close()
	}
}
