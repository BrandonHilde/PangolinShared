package pangolin

import "core:image/qoi"

// Decodes the image formats all the Pangolin tools read, picked by content rather than file extension:
// our own JPEG and WebP decoders, core:image for QOI, stb_image for the rest (PNG, BMP, TGA, GIF's first frame).
// Safe off the main thread. Result allocated with context.allocator.
decode_common_image :: proc(data: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	if len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
		return jpeg_decode(data)
	}
	if webp_is(data) {
		return webp_decode(data)
	}
	if len(data) >= 4 && string(data[:4]) == "qoif" {
		img, err := qoi.load_from_bytes(data, {.alpha_add_if_missing})
		if err != nil || img == nil do return
		defer qoi.destroy(img)
		w, h = img.width, img.height
		if img.channels != 4 || len(img.pixels.buf) < w * h * 4 do return nil, 0, 0, false
		pix = make([]Color, w * h)
		copy(pix, ([^]Color)(raw_data(img.pixels.buf))[:w * h])
		return pix, w, h, true
	}
	return stb_decode(data)
}

// File dialogs and file browsers offer these.
COMMON_IMAGE_EXTS := [?]string{".png", ".jpg", ".jpeg", ".jfif", ".webp", ".bmp", ".tga", ".gif", ".qoi"}
COMMON_IMAGE_PATTERN :: "*.png;*.jpg;*.jpeg;*.jfif;*.webp;*.bmp;*.tga;*.gif;*.qoi"

is_common_image_ext :: proc(ext: string) -> bool {
	for e in COMMON_IMAGE_EXTS do if e == ext do return true
	return false
}
