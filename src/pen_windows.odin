package pangolin

import "core:sys/windows"

foreign import user32 "system:user32.lib"

@(default_calling_convention = "system", private = "file")
foreign user32 {
	SetWindowFeedbackSetting :: proc(hwnd: windows.HWND, feedback: windows.UINT, flags: windows.DWORD, size: windows.UINT, config: rawptr) -> windows.BOOL ---
}

@(private = "file")
prev_wndproc: windows.WNDPROC

@(private = "file")
WM_TABLET_QUERYSYSTEMGESTURESTATUS :: 0x02CC

// press-and-hold, pen tap / barrel feedback, flicks: all of these draw rings or delay the stroke
@(private = "file")
TABLET_DISABLE_GESTURES :: 0x1 | 0x8 | 0x10 | 0x10000 | 0x100000

// FEEDBACK_PEN_BARRELVISUALIZATION, _TAP, _DOUBLETAP, _PRESSANDHOLD, _RIGHTTAP and the touch contact ring
@(private = "file")
FEEDBACK_TYPES := [?]windows.UINT{1, 2, 3, 4, 5}

@(private = "file")
LOWORD :: #force_inline proc "contextless" (v: windows.WPARAM) -> windows.UINT {
	return windows.UINT(v) & 0xFFFF
}

pen_win_init :: proc() {
	hwnd := windows.HWND(gfx_hwnd())
	if hwnd == nil {
		return
	}
	off: windows.BOOL = false
	for ft in FEEDBACK_TYPES {
		SetWindowFeedbackSetting(hwnd, ft, 0, size_of(off), &off)
	}
	old := windows.SetWindowLongPtrW(hwnd, windows.GWLP_WNDPROC, windows.LONG_PTR(uintptr(rawptr(pen_wndproc))))
	prev_wndproc = windows.WNDPROC(rawptr(uintptr(old)))
}

@(private = "file")
pen_wndproc :: proc "system" (hwnd: windows.HWND, msg: windows.UINT, wparam: windows.WPARAM, lparam: windows.LPARAM) -> windows.LRESULT {
	switch msg {
	case WM_TABLET_QUERYSYSTEMGESTURESTATUS:
		return TABLET_DISABLE_GESTURES
	case windows.WM_POINTERUPDATE, windows.WM_POINTERDOWN, windows.WM_POINTERUP:
		info: windows.POINTER_PEN_INFO
		// only succeeds for pen pointers
		if windows.GetPointerPenInfo(LOWORD(wparam), &info) {
			fl := info.pointerInfo.pointerFlags
			pen.seen = true
			pen.in_range = .in_range in fl
			pen.touching = .in_contact in fl
			if msg == windows.WM_POINTERDOWN do pen.down_evt = true
			if msg == windows.WM_POINTERUP do pen.up_evt = true
			pt := info.pointerInfo.ptPixelLocation
			if windows.ScreenToClient(hwnd, &pt) {
				pen.pos = {f32(pt.x), f32(pt.y)}
			}
			pen.eraser = .eraser in info.penFlags || .inverted in info.penFlags
			if .pressure in info.penMask {
				pen.pressure = clamp(f32(info.pressure) / 1024, 0, 1)
			} else {
				pen.pressure = pen.touching ? 1 : 0
			}
			pen.tilt = {f32(info.tiltX), f32(info.tiltY)}
		}
	case windows.WM_POINTERLEAVE:
		if pen.touching do pen.up_evt = true
		pen.in_range = false
		pen.touching = false
		pen.pressure = 0
	}
	return windows.CallWindowProcW(prev_wndproc, hwnd, msg, wparam, lparam)
}
