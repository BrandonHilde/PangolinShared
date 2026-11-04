package pangolin

import "base:runtime"

// ---------------------------------------------------------------------------
// Pure-Odin WebP decoder: lossless (VP8L), lossy key frames (VP8), the alpha chunk (ALPH), and the
// first frame of an animation. Neither stb_image nor core:image reads WebP. Safe off the main thread.
// Follows RFC 6386 and the WebP lossless bitstream specification; malformed files return ok = false.
// ---------------------------------------------------------------------------

WEBP_MAX_SIDE :: 16384

webp_is :: proc(data: []u8) -> bool {
	return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP"
}

// The decoded image, RGBA, allocated with context.allocator.
webp_decode :: proc(data: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	if !webp_is(data) do return
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	pos := 12
	canvas_w, canvas_h := 0, 0
	alpha: []u8
	for pos + 8 <= len(data) {
		id := string(data[pos:pos + 4])
		size := int(u32(data[pos + 4]) | u32(data[pos + 5]) << 8 | u32(data[pos + 6]) << 16 | u32(data[pos + 7]) << 24)
		start := pos + 8
		end := min(start + size, len(data))
		body := data[start:end]
		switch id {
		case "VP8X":
			if len(body) < 10 do return
			canvas_w = (int(body[4]) | int(body[5]) << 8 | int(body[6]) << 16) + 1
			canvas_h = (int(body[7]) | int(body[8]) << 8 | int(body[9]) << 16) + 1
		case "ALPH":
			alpha = body
		case "VP8 ":
			return webp_lossy_with_alpha(body, alpha)
		case "VP8L":
			return vp8l_decode(body)
		case "ANMF":
			return webp_first_frame(body, canvas_w, canvas_h)
		}
		pos = start + size + (size & 1)
	}
	return
}

// An animation's first frame, placed on the canvas.
@(private = "file")
webp_first_frame :: proc(frame: []u8, canvas_w, canvas_h: int) -> (pix: []Color, w, h: int, ok: bool) {
	if len(frame) < 16 || canvas_w < 1 || canvas_h < 1 || canvas_w > WEBP_MAX_SIDE || canvas_h > WEBP_MAX_SIDE do return
	fx := (int(frame[0]) | int(frame[1]) << 8 | int(frame[2]) << 16) * 2
	fy := (int(frame[3]) | int(frame[4]) << 8 | int(frame[5]) << 16) * 2
	pos := 16
	alpha: []u8
	sub: []Color
	sw, sh: int
	found := false
	for pos + 8 <= len(frame) && !found {
		id := string(frame[pos:pos + 4])
		size := int(u32(frame[pos + 4]) | u32(frame[pos + 5]) << 8 | u32(frame[pos + 6]) << 16 | u32(frame[pos + 7]) << 24)
		start := pos + 8
		end := min(start + size, len(frame))
		body := frame[start:end]
		switch id {
		case "ALPH":
			alpha = body
		case "VP8 ":
			sub, sw, sh, found = webp_lossy_with_alpha(body, alpha)
			if !found do return
		case "VP8L":
			sub, sw, sh, found = vp8l_decode(body)
			if !found do return
		}
		pos = start + size + (size & 1)
	}
	if !found do return
	defer delete(sub)
	pix = make([]Color, canvas_w * canvas_h)
	for y in 0 ..< sh {
		if fy + y >= canvas_h do break
		for x in 0 ..< sw {
			if fx + x >= canvas_w do break
			pix[(fy + y) * canvas_w + fx + x] = sub[y * sw + x]
		}
	}
	return pix, canvas_w, canvas_h, true
}

@(private = "file")
webp_lossy_with_alpha :: proc(body, alpha: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	pix, w, h, ok = vp8_decode(body)
	if ok && len(alpha) > 0 do webp_apply_alpha(pix, w, h, alpha)
	return
}

// The ALPH chunk: one header byte, then the alpha plane raw or as a headerless VP8L image, with an
// optional prediction filter. A chunk that cannot be read leaves the image opaque.
@(private = "file")
webp_apply_alpha :: proc(pix: []Color, w, h: int, chunk: []u8) {
	filter := (chunk[0] >> 2) & 3
	method := chunk[0] & 3
	plane := make([]u8, w * h, context.temp_allocator)
	switch method {
	case 0:
		if len(chunk) - 1 < w * h do return
		copy(plane, chunk[1:])
	case 1:
		r := VP8L_Reader {
			data = chunk[1:],
		}
		img, iok := vp8l_image(&r, w, h, true)
		if !iok do return
		for v, i in img do plane[i] = u8(v >> 8)
	case:
		return
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := y * w + x
			pred: int
			switch {
			case filter == 0:
			case x == 0 && y == 0:
			case y == 0:
				pred = int(plane[i - 1])
			case x == 0:
				pred = int(plane[i - w])
			case filter == 1:
				pred = int(plane[i - 1])
			case filter == 2:
				pred = int(plane[i - w])
			case:
				pred = clamp(int(plane[i - 1]) + int(plane[i - w]) - int(plane[i - w - 1]), 0, 255)
			}
			plane[i] = u8((int(plane[i]) + pred) & 255)
			pix[i].a = plane[i]
		}
	}
}

// ---------------------------------------------------------------------------
// Lossless
// ---------------------------------------------------------------------------

@(private = "file")
VP8L_Reader :: struct {
	data:  []u8,
	pos:   int,
	bits:  u64,
	nbits: uint,
	eof:   bool,
}

@(private = "file")
vp8l_read :: #force_inline proc(r: ^VP8L_Reader, n: uint) -> u32 {
	if n == 0 do return 0
	for r.nbits < n {
		if r.pos < len(r.data) {
			r.bits |= u64(r.data[r.pos]) << r.nbits
		} else if r.pos > len(r.data) + 8 {
			r.eof = true
		}
		r.pos += 1
		r.nbits += 8
	}
	v := u32(r.bits & ((u64(1) << n) - 1))
	r.bits >>= n
	r.nbits -= n
	return v
}

@(private = "file")
VP8L_Huff :: struct {
	fast:   [256]u16, // by the next 8 bits: symbol << 4 | length; 0 means the code is longer
	count:  [16]u16,
	syms:   []u16,
	single: i32, // the only symbol, which takes no bits; -1 otherwise
}

// Builds the canonical code. Codes go into the stream first bit first, so the table is indexed bit-reversed.
@(private = "file")
vp8l_huff_build :: proc(h: ^VP8L_Huff, lengths: []u8) -> bool {
	h.single = -1
	used, last := 0, 0
	for l, s in lengths {
		if l > 15 do return false
		if l > 0 {
			h.count[l] += 1
			used += 1
			last = s
		}
	}
	// a code with no symbols is legal in a group nothing refers to
	if used <= 1 {
		h.single = i32(last)
		return true
	}
	offs: [17]int
	for l in 1 ..= 15 do offs[l + 1] = offs[l] + int(h.count[l])
	h.syms = make([]u16, used, context.temp_allocator)
	for l, s in lengths {
		if l > 0 {
			h.syms[offs[l]] = u16(s)
			offs[l] += 1
		}
	}
	code, index := 0, 0
	for l in 1 ..= 15 {
		for _ in 0 ..< int(h.count[l]) {
			if l <= 8 {
				if code >= 1 << uint(l) do return false
				rev := 0
				for b in 0 ..< l {
					if code & (1 << uint(b)) != 0 do rev |= 1 << uint(l - 1 - b)
				}
				for f := rev; f < 256; f += 1 << uint(l) {
					h.fast[f] = h.syms[index] << 4 | u16(l)
				}
			}
			code += 1
			index += 1
		}
		code <<= 1
	}
	return true
}

@(private = "file")
vp8l_sym :: #force_inline proc(r: ^VP8L_Reader, h: ^VP8L_Huff) -> int {
	if h.single >= 0 do return int(h.single)
	for r.nbits < 16 {
		if r.pos < len(r.data) {
			r.bits |= u64(r.data[r.pos]) << r.nbits
		} else if r.pos > len(r.data) + 8 {
			r.eof = true
		}
		r.pos += 1
		r.nbits += 8
	}
	e := h.fast[r.bits & 255]
	if e != 0 {
		n := uint(e & 15)
		r.bits >>= n
		r.nbits -= n
		return int(e >> 4)
	}
	code, first, index := 0, 0, 0
	for l in 1 ..= 15 {
		code |= int(r.bits & 1)
		r.bits >>= 1
		r.nbits -= 1
		count := int(h.count[l])
		if code - count < first {
			i := index + code - first
			return i < len(h.syms) ? int(h.syms[i]) : 0
		}
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	r.eof = true
	return 0
}

@(private = "file")
vp8l_read_code :: proc(r: ^VP8L_Reader, h: ^VP8L_Huff, alphabet: int) -> bool {
	lengths := make([]u8, alphabet, context.temp_allocator)
	if vp8l_read(r, 1) == 1 {
		// simple: one or two symbols
		n := vp8l_read(r, 1) + 1
		first := vp8l_read(r, 1) == 1 ? vp8l_read(r, 8) : vp8l_read(r, 1)
		if int(first) >= alphabet do return false
		lengths[first] = 1
		if n == 2 {
			second := vp8l_read(r, 8)
			if int(second) >= alphabet do return false
			lengths[second] = 1
		}
		return vp8l_huff_build(h, lengths)
	}
	ORDER := [19]u8{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	cl: [19]u8
	n := int(vp8l_read(r, 4)) + 4
	for i in 0 ..< n do cl[ORDER[i]] = u8(vp8l_read(r, 3))
	lc: VP8L_Huff
	if !vp8l_huff_build(&lc, cl[:]) do return false
	max_symbol := alphabet
	if vp8l_read(r, 1) == 1 {
		nbits := uint(2 + 2 * vp8l_read(r, 3))
		max_symbol = 2 + int(vp8l_read(r, nbits))
		if max_symbol > alphabet do return false
	}
	sym, prev := 0, u8(8)
	for sym < alphabet {
		if max_symbol == 0 do break
		max_symbol -= 1
		c := vp8l_sym(r, &lc)
		if r.eof do return false
		if c < 16 {
			lengths[sym] = u8(c)
			sym += 1
			if c != 0 do prev = u8(c)
		} else {
			slot := c - 16
			extra := [3]uint{2, 3, 7}
			offset := [3]int{3, 3, 11}
			if slot > 2 do return false
			repeat := int(vp8l_read(r, extra[slot])) + offset[slot]
			if sym + repeat > alphabet do return false
			v := c == 16 ? prev : 0
			for _ in 0 ..< repeat {
				lengths[sym] = v
				sym += 1
			}
		}
	}
	return vp8l_huff_build(h, lengths)
}

@(private = "file")
VP8L_DIST := [120][2]i32 {
	{0,1}, {1,0}, {1,1}, {-1,1}, {0,2}, {2,0}, {1,2}, {-1,2}, {2,1}, {-2,1}, {2,2}, {-2,2}, {0,3}, {3,0}, {1,3}, {-1,3}, {3,1}, {-3,1}, {2,3}, {-2,3}, {3,2}, {-3,2}, {0,4}, {4,0}, {1,4}, {-1,4}, {4,1}, {-4,1}, {3,3}, {-3,3}, {2,4}, {-2,4}, {4,2}, {-4,2}, {0,5}, {3,4}, {-3,4}, {4,3}, {-4,3}, {5,0}, {1,5}, {-1,5}, {5,1}, {-5,1}, {2,5}, {-2,5}, {5,2}, {-5,2}, {4,4}, {-4,4}, {3,5}, {-3,5}, {5,3}, {-5,3}, {0,6}, {6,0}, {1,6}, {-1,6}, {6,1}, {-6,1}, {2,6}, {-2,6}, {6,2}, {-6,2}, {4,5}, {-4,5}, {5,4}, {-5,4}, {3,6}, {-3,6}, {6,3}, {-6,3}, {0,7}, {7,0}, {1,7}, {-1,7}, {5,5}, {-5,5}, {7,1}, {-7,1}, {4,6}, {-4,6}, {6,4}, {-6,4}, {2,7}, {-2,7}, {7,2}, {-7,2}, {3,7}, {-3,7}, {7,3}, {-7,3}, {5,6}, {-5,6}, {6,5}, {-6,5}, {8,0}, {4,7}, {-4,7}, {7,4}, {-7,4}, {8,1}, {8,2}, {6,6}, {-6,6}, {8,3}, {5,7}, {-5,7}, {7,5}, {-7,5}, {8,4}, {6,7}, {-6,7}, {7,6}, {-7,6}, {8,5}, {7,7}, {-7,7}, {8,6}, {8,7},
}

@(private = "file")
VP8L_Transform :: struct {
	kind:    u32,
	bits:    uint,
	xsize:   int, // the image's width as this transform sees it
	data:    []u32,
	palette: int,
}

// An image stream. Level 0 images have transforms, a color cache and meta codes; the entropy images
// inside them have only a cache. The result is `w` wide, in the temp allocator.
@(private = "file")
vp8l_image :: proc(r: ^VP8L_Reader, w, h: int, level0: bool) -> (pix: []u32, ok: bool) {
	transforms: [4]VP8L_Transform
	nt := 0
	xs := w
	if level0 {
		for vp8l_read(r, 1) == 1 {
			if nt >= 4 do return nil, false
			t := VP8L_Transform {
				kind  = vp8l_read(r, 2),
				xsize = xs,
			}
			switch t.kind {
			case 0, 1:
				t.bits = uint(vp8l_read(r, 3)) + 2
				bw := (xs + (1 << t.bits) - 1) >> t.bits
				bh := (h + (1 << t.bits) - 1) >> t.bits
				sok: bool
				t.data, sok = vp8l_image(r, bw, bh, false)
				if !sok do return nil, false
			case 3:
				t.palette = int(vp8l_read(r, 8)) + 1
				sok: bool
				t.data, sok = vp8l_image(r, t.palette, 1, false)
				if !sok do return nil, false
				t.bits = t.palette <= 2 ? 3 : t.palette <= 4 ? 2 : t.palette <= 16 ? 1 : 0
				xs = (xs + (1 << t.bits) - 1) >> t.bits
			}
			transforms[nt] = t
			nt += 1
		}
	}
	cache_bits: uint
	if vp8l_read(r, 1) == 1 {
		cache_bits = uint(vp8l_read(r, 4))
		if cache_bits < 1 || cache_bits > 11 do return nil, false
	}
	meta_bits: uint
	meta: []u32
	mw := 0
	groups := 1
	if level0 && vp8l_read(r, 1) == 1 {
		meta_bits = uint(vp8l_read(r, 3)) + 2
		mw = (xs + (1 << meta_bits) - 1) >> meta_bits
		mh := (h + (1 << meta_bits) - 1) >> meta_bits
		mok: bool
		meta, mok = vp8l_image(r, mw, mh, false)
		if !mok do return nil, false
		for &v in meta {
			v = (v >> 8) & 0xffff
			groups = max(groups, int(v) + 1)
		}
	}
	codes := make([][5]VP8L_Huff, groups, context.temp_allocator)
	cache_size := cache_bits > 0 ? 1 << cache_bits : 0
	for gi in 0 ..< groups {
		sizes := [5]int{256 + 24 + cache_size, 256, 256, 256, 40}
		for i in 0 ..< 5 {
			if !vp8l_read_code(r, &codes[gi][i], sizes[i]) do return nil, false
		}
	}
	if r.eof do return nil, false
	// the transforms widen the image in place, so it has room for `w` from the start
	pix = make([]u32, w * h, context.temp_allocator)
	cache: []u32
	if cache_size > 0 do cache = make([]u32, cache_size, context.temp_allocator)
	total := xs * h
	pos, cached := 0, 0
	group := &codes[0]
	for pos < total {
		// looked up for every symbol: a back-reference can end in the middle of a block
		if meta_bits > 0 {
			x, y := pos % xs, pos / xs
			group = &codes[meta[(y >> meta_bits) * mw + (x >> meta_bits)]]
		}
		code := vp8l_sym(r, &group[0])
		switch {
		case code < 256:
			red := u32(vp8l_sym(r, &group[1]))
			blue := u32(vp8l_sym(r, &group[2]))
			a := u32(vp8l_sym(r, &group[3]))
			pix[pos] = a << 24 | red << 16 | u32(code) << 8 | blue
			pos += 1
		case code < 256 + 24:
			length := vp8l_prefix(r, code - 256)
			dcode := vp8l_prefix(r, vp8l_sym(r, &group[4]))
			dist: int
			if dcode > 120 {
				dist = dcode - 120
			} else {
				d := VP8L_DIST[dcode - 1]
				dist = max(int(d[0]) + int(d[1]) * xs, 1)
			}
			if dist > pos || pos + length > total do return nil, false
			for i in 0 ..< length do pix[pos + i] = pix[pos + i - dist]
			pos += length
		case:
			idx := code - 256 - 24
			// what the cache holds at this point is everything before it
			for cached < pos {
				v := pix[cached]
				cache[(0x1e35a7bd * v) >> (32 - cache_bits)] = v
				cached += 1
			}
			pix[pos] = cache[idx]
			pos += 1
		}
		if r.eof do return nil, false
	}
	for i := nt - 1; i >= 0; i -= 1 {
		t := &transforms[i]
		switch t.kind {
		case 0:
			vp8l_inverse_predict(pix, t.xsize, h, t.bits, t.data)
		case 1:
			vp8l_inverse_color(pix, t.xsize, h, t.bits, t.data)
		case 2:
			for &p in pix[:t.xsize * h] {
				g := (p >> 8) & 255
				p = (p & 0xff00ff00) | ((((p >> 16) + g) & 255) << 16) | ((p + g) & 255)
			}
		case 3:
			vp8l_inverse_index(pix, t.xsize, h, t.bits, t.data, t.palette)
		}
	}
	return pix, true
}

@(private = "file")
vp8l_prefix :: #force_inline proc(r: ^VP8L_Reader, prefix: int) -> int {
	if prefix < 4 do return prefix + 1
	extra := uint((prefix - 2) >> 1)
	offset := (2 + (prefix & 1)) << extra
	return offset + int(vp8l_read(r, extra)) + 1
}

@(private = "file")
vp8l_avg :: #force_inline proc(a, b: u32) -> u32 {
	return (((a ~ b) & 0xfefefefe) >> 1) + (a & b)
}

@(private = "file")
vp8l_add :: #force_inline proc(a, b: u32) -> u32 {
	alpha_green := (a & 0xff00ff00) + (b & 0xff00ff00)
	red_blue := (a & 0x00ff00ff) + (b & 0x00ff00ff)
	return (alpha_green & 0xff00ff00) | (red_blue & 0x00ff00ff)
}

@(private = "file")
vp8l_predict :: proc(mode: u32, l, t, tr, tl: u32) -> u32 {
	switch mode {
	case 1:
		return l
	case 2:
		return t
	case 3:
		return tr
	case 4:
		return tl
	case 5:
		return vp8l_avg(vp8l_avg(l, tr), t)
	case 6:
		return vp8l_avg(l, tl)
	case 7:
		return vp8l_avg(l, t)
	case 8:
		return vp8l_avg(tl, t)
	case 9:
		return vp8l_avg(t, tr)
	case 10:
		return vp8l_avg(vp8l_avg(l, tl), vp8l_avg(t, tr))
	case 11:
		pl, pt := 0, 0
		for s in 0 ..< uint(4) {
			sh := s * 8
			c_l, c_t, c_tl := int((l >> sh) & 255), int((t >> sh) & 255), int((tl >> sh) & 255)
			pl += abs(c_t - c_tl)
			pt += abs(c_l - c_tl)
		}
		return pl < pt ? l : t
	case 12:
		out: u32
		for s in 0 ..< uint(4) {
			sh := s * 8
			v := int((l >> sh) & 255) + int((t >> sh) & 255) - int((tl >> sh) & 255)
			out |= u32(clamp(v, 0, 255)) << sh
		}
		return out
	case 13:
		avg := vp8l_avg(l, t)
		out: u32
		for s in 0 ..< uint(4) {
			sh := s * 8
			a, b := int((avg >> sh) & 255), int((tl >> sh) & 255)
			out |= u32(clamp(a + (a - b) / 2, 0, 255)) << sh
		}
		return out
	}
	return 0xff000000
}

@(private = "file")
vp8l_inverse_predict :: proc(pix: []u32, w, h: int, bits: uint, data: []u32) {
	bw := (w + (1 << bits) - 1) >> bits
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := y * w + x
			pred: u32
			switch {
			case x == 0 && y == 0:
				pred = 0xff000000
			case y == 0:
				pred = pix[i - 1]
			case x == 0:
				pred = pix[i - w]
			case:
				mode := (data[(y >> bits) * bw + (x >> bits)] >> 8) & 15
				pred = vp8l_predict(mode, pix[i - 1], pix[i - w], pix[i - w + 1], pix[i - w - 1])
			}
			pix[i] = vp8l_add(pix[i], pred)
		}
	}
}

@(private = "file")
vp8l_delta :: #force_inline proc(t, c: u32) -> u32 {
	return u32((i32(i8(u8(t))) * i32(i8(u8(c)))) >> 5)
}

@(private = "file")
vp8l_inverse_color :: proc(pix: []u32, w, h: int, bits: uint, data: []u32) {
	bw := (w + (1 << bits) - 1) >> bits
	for y in 0 ..< h {
		for x in 0 ..< w {
			m := data[(y >> bits) * bw + (x >> bits)]
			to_red, to_blue_g, to_blue_r := m & 255, (m >> 8) & 255, (m >> 16) & 255
			p := &pix[y * w + x]
			g := (p^ >> 8) & 255
			r := ((p^ >> 16) + vp8l_delta(to_red, g)) & 255
			b := (p^ + vp8l_delta(to_blue_g, g) + vp8l_delta(to_blue_r, r)) & 255
			p^ = (p^ & 0xff00ff00) | r << 16 | b
		}
	}
}

// Palette indices in the green channel, several to a pixel when the palette is small.
@(private = "file")
vp8l_inverse_index :: proc(pix: []u32, w, h: int, bits: uint, data: []u32, palette: int) {
	colors := make([]u32, 256, context.temp_allocator)
	prev: u32
	for i in 0 ..< palette {
		prev = vp8l_add(prev, data[i])
		colors[i] = prev
	}
	xs := (w + (1 << bits) - 1) >> bits
	per := uint(1) << bits
	depth := uint(8) >> bits
	vmask := (u32(1) << depth) - 1
	// from the end: the packed image sits in the front of the same array
	for y := h - 1; y >= 0; y -= 1 {
		for x := w - 1; x >= 0; x -= 1 {
			v := (pix[y * xs + (x >> bits)] >> 8) & 255
			idx := bits > 0 ? (v >> ((uint(x) % per) * depth)) & vmask : v
			pix[y * w + x] = colors[idx]
		}
	}
}

@(private = "file")
vp8l_decode :: proc(body: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	if len(body) < 5 || body[0] != 0x2f do return
	r := VP8L_Reader {
		data = body,
		pos  = 1,
	}
	w = int(vp8l_read(&r, 14)) + 1
	h = int(vp8l_read(&r, 14)) + 1
	vp8l_read(&r, 1) // alpha hint
	if vp8l_read(&r, 3) != 0 do return nil, 0, 0, false
	img, iok := vp8l_image(&r, w, h, true)
	if !iok do return nil, 0, 0, false
	pix = make([]Color, w * h)
	for v, i in img {
		pix[i] = {u8(v >> 16), u8(v >> 8), u8(v), u8(v >> 24)}
	}
	return pix, w, h, true
}

// ---------------------------------------------------------------------------
// Lossy: the key frame of VP8
// ---------------------------------------------------------------------------

@(private = "file")
VP8_Bool :: struct {
	data:      []u8,
	pos:       int,
	value:     u32,
	range:     u32,
	bit_count: int,
}

@(private = "file")
vp8_bool_init :: proc(b: ^VP8_Bool, data: []u8) {
	b^ = {
		data  = data,
		range = 255,
	}
	for _ in 0 ..< 2 {
		b.value <<= 8
		if b.pos < len(data) do b.value |= u32(data[b.pos])
		b.pos += 1
	}
}

@(private = "file")
vp8_bit :: #force_inline proc(b: ^VP8_Bool, prob: u8) -> int {
	split := 1 + (((b.range - 1) * u32(prob)) >> 8)
	big := split << 8
	ret := 0
	if b.value >= big {
		ret = 1
		b.range -= split
		b.value -= big
	} else {
		b.range = split
	}
	for b.range < 128 {
		b.value <<= 1
		b.range <<= 1
		b.bit_count += 1
		if b.bit_count == 8 {
			b.bit_count = 0
			if b.pos < len(b.data) do b.value |= u32(b.data[b.pos])
			b.pos += 1
		}
	}
	return ret
}

@(private = "file")
vp8_lit :: proc(b: ^VP8_Bool, n: int) -> int {
	v := 0
	for _ in 0 ..< n do v = v << 1 | vp8_bit(b, 128)
	return v
}

@(private = "file")
vp8_signed :: proc(b: ^VP8_Bool, n: int) -> int {
	v := vp8_lit(b, n)
	return vp8_bit(b, 128) == 1 ? -v : v
}

@(private = "file")
vp8_opt_signed :: proc(b: ^VP8_Bool, n: int) -> int {
	return vp8_bit(b, 128) == 1 ? vp8_signed(b, n) : 0
}

@(private = "file")
VP8_ZIGZAG := [16]u8{0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15}
@(private = "file")
VP8_BANDS := [17]u8{0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0}
@(private = "file")
VP8_CAT3 := [?]u8{173, 148, 140}
@(private = "file")
VP8_CAT4 := [?]u8{176, 155, 140, 135}
@(private = "file")
VP8_CAT5 := [?]u8{180, 157, 141, 134, 130}
@(private = "file")
VP8_CAT6 := [?]u8{254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129}

@(private = "file")
VP8_Quant :: struct {
	y1, y2, uv: [2]i32, // dc, ac
}

// Reads one block's tokens; returns the position after the last one read.
@(private = "file")
vp8_coeffs :: proc(b: ^VP8_Bool, probs: ^[1056]u8, kind, ctx_in: int, dq: [2]i32, first: int, out: []i32) -> int {
	slot :: #force_inline proc(kind, n, ctx: int) -> int {
		return (kind * 8 + int(VP8_BANDS[n])) * 33 + ctx * 11
	}
	n := first
	at := slot(kind, n, ctx_in)
	for n < 16 {
		if vp8_bit(b, probs[at + 0]) == 0 do return n
		for vp8_bit(b, probs[at + 1]) == 0 {
			n += 1
			if n == 16 do return 16
			at = slot(kind, n, 0)
		}
		v: i32
		ctx := 2
		if vp8_bit(b, probs[at + 2]) == 0 {
			v = 1
			ctx = 1
		} else if vp8_bit(b, probs[at + 3]) == 0 {
			if vp8_bit(b, probs[at + 4]) == 0 {
				v = 2
			} else {
				v = 3 + i32(vp8_bit(b, probs[at + 5]))
			}
		} else if vp8_bit(b, probs[at + 6]) == 0 {
			if vp8_bit(b, probs[at + 7]) == 0 {
				v = 5 + i32(vp8_bit(b, 159))
			} else {
				v = 7 + 2 * i32(vp8_bit(b, 165))
				v += i32(vp8_bit(b, 145))
			}
		} else {
			bit1 := vp8_bit(b, probs[at + 8])
			bit0 := vp8_bit(b, probs[at + 9 + bit1])
			cat := 2 * bit1 + bit0
			tab: []u8
			switch cat {
			case 0:
				tab = VP8_CAT3[:]
			case 1:
				tab = VP8_CAT4[:]
			case 2:
				tab = VP8_CAT5[:]
			case:
				tab = VP8_CAT6[:]
			}
			for t in tab do v = v * 2 + i32(vp8_bit(b, t))
			v += 3 + (8 << uint(cat))
		}
		if vp8_bit(b, 128) == 1 do v = -v
		out[VP8_ZIGZAG[n]] = v * dq[n > 0 ? 1 : 0]
		n += 1
		at = slot(kind, n, ctx)
	}
	return 16
}

@(private = "file")
vp8_wht :: proc(input: []i32, out: []i32) {
	tmp: [16]i32
	for i in 0 ..< 4 {
		a0 := input[0 + i] + input[12 + i]
		a1 := input[4 + i] + input[8 + i]
		a2 := input[4 + i] - input[8 + i]
		a3 := input[0 + i] - input[12 + i]
		tmp[0 + i] = a0 + a1
		tmp[8 + i] = a0 - a1
		tmp[4 + i] = a3 + a2
		tmp[12 + i] = a3 - a2
	}
	for i in 0 ..< 4 {
		dc := tmp[0 + i * 4] + 3
		a0 := dc + tmp[3 + i * 4]
		a1 := tmp[1 + i * 4] + tmp[2 + i * 4]
		a2 := tmp[1 + i * 4] - tmp[2 + i * 4]
		a3 := dc - tmp[3 + i * 4]
		out[(i * 4 + 0) * 16] = (a0 + a1) >> 3
		out[(i * 4 + 1) * 16] = (a3 + a2) >> 3
		out[(i * 4 + 2) * 16] = (a0 - a1) >> 3
		out[(i * 4 + 3) * 16] = (a3 - a2) >> 3
	}
}

@(private = "file")
vp8_clip8 :: #force_inline proc(v: i32) -> u8 {
	return v < 0 ? 0 : v > 255 ? 255 : u8(v)
}

// Work buffers are VP8_BPS wide, with a border: the row above at -VP8_BPS, the column to the left at -1.
@(private = "file")
VP8_BPS :: 32
@(private = "file")
VP8_ORG :: VP8_BPS + 1

@(private = "file")
vp8_idct :: proc(c: []i32, dst: []u8, at: int) {
	mul1 :: #force_inline proc(a: i32) -> i32 {return ((a * 20091) >> 16) + a}
	mul2 :: #force_inline proc(a: i32) -> i32 {return (a * 35468) >> 16}
	any_set := false
	for v in c[:16] do if v != 0 do any_set = true
	if !any_set do return
	tmp: [16]i32
	for i in 0 ..< 4 {
		a := c[i] + c[8 + i]
		b := c[i] - c[8 + i]
		cc := mul2(c[4 + i]) - mul1(c[12 + i])
		d := mul1(c[4 + i]) + mul2(c[12 + i])
		tmp[i * 4 + 0] = a + d
		tmp[i * 4 + 1] = b + cc
		tmp[i * 4 + 2] = b - cc
		tmp[i * 4 + 3] = a - d
	}
	for i in 0 ..< 4 {
		dc := tmp[i] + 4
		a := dc + tmp[8 + i]
		b := dc - tmp[8 + i]
		cc := mul2(tmp[4 + i]) - mul1(tmp[12 + i])
		d := mul1(tmp[4 + i]) + mul2(tmp[12 + i])
		row := at + i * VP8_BPS
		dst[row + 0] = vp8_clip8(i32(dst[row + 0]) + ((a + d) >> 3))
		dst[row + 1] = vp8_clip8(i32(dst[row + 1]) + ((b + cc) >> 3))
		dst[row + 2] = vp8_clip8(i32(dst[row + 2]) + ((b - cc) >> 3))
		dst[row + 3] = vp8_clip8(i32(dst[row + 3]) + ((a - d) >> 3))
	}
}

@(private = "file")
vp8_avg2 :: #force_inline proc(a, b: u8) -> u8 {return u8((u32(a) + u32(b) + 1) >> 1)}
@(private = "file")
vp8_avg3 :: #force_inline proc(a, b, c: u8) -> u8 {return u8((u32(a) + 2 * u32(b) + u32(c) + 2) >> 2)}

// A subblock mode. The enum order is the bitstream's: DC TM VE HE LD RD VR VL HD HU.
@(private = "file")
vp8_pred4 :: proc(mode: u8, w: []u8, at: int) {
	avg2, avg3 := vp8_avg2, vp8_avg3
	top := at - VP8_BPS
	d :: #force_inline proc(w: []u8, at, x, y: int, v: u8) {w[at + x + y * VP8_BPS] = v}
	X := w[top - 1]
	A, B, C, D := w[top], w[top + 1], w[top + 2], w[top + 3]
	E, F, G, H := w[top + 4], w[top + 5], w[top + 6], w[top + 7]
	I, J, K, L := w[at - 1], w[at - 1 + VP8_BPS], w[at - 1 + 2 * VP8_BPS], w[at - 1 + 3 * VP8_BPS]
	switch mode {
	case 0:
		s := u32(A) + u32(B) + u32(C) + u32(D) + u32(I) + u32(J) + u32(K) + u32(L) + 4
		v := u8(s >> 3)
		for y in 0 ..< 4 do for x in 0 ..< 4 do d(w, at, x, y, v)
	case 1:
		ls := [4]u8{I, J, K, L}
		ts := [4]u8{A, B, C, D}
		for y in 0 ..< 4 do for x in 0 ..< 4 do d(w, at, x, y, vp8_clip8(i32(ts[x]) + i32(ls[y]) - i32(X)))
	case 2:
		v := [4]u8{avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E)}
		for y in 0 ..< 4 do for x in 0 ..< 4 do d(w, at, x, y, v[x])
	case 3:
		v := [4]u8{avg3(X, I, J), avg3(I, J, K), avg3(J, K, L), avg3(K, L, L)}
		for y in 0 ..< 4 do for x in 0 ..< 4 do d(w, at, x, y, v[y])
	case 4:
		v := [7]u8{avg3(A, B, C), avg3(B, C, D), avg3(C, D, E), avg3(D, E, F), avg3(E, F, G), avg3(F, G, H), avg3(G, H, H)}
		for y in 0 ..< 4 do for x in 0 ..< 4 do d(w, at, x, y, v[x + y])
	case 5:
		v := [7]u8{avg3(J, K, L), avg3(I, J, K), avg3(X, I, J), avg3(A, X, I), avg3(B, A, X), avg3(C, B, A), avg3(D, C, B)}
		for y in 0 ..< 4 do for x in 0 ..< 4 do d(w, at, x, y, v[3 - y + x])
	case 6:
		d(w, at, 0, 0, avg2(X, A));d(w, at, 1, 2, avg2(X, A))
		d(w, at, 1, 0, avg2(A, B));d(w, at, 2, 2, avg2(A, B))
		d(w, at, 2, 0, avg2(B, C));d(w, at, 3, 2, avg2(B, C))
		d(w, at, 3, 0, avg2(C, D))
		d(w, at, 0, 3, avg3(K, J, I))
		d(w, at, 0, 2, avg3(J, I, X))
		d(w, at, 0, 1, avg3(I, X, A));d(w, at, 1, 3, avg3(I, X, A))
		d(w, at, 1, 1, avg3(X, A, B));d(w, at, 2, 3, avg3(X, A, B))
		d(w, at, 2, 1, avg3(A, B, C));d(w, at, 3, 3, avg3(A, B, C))
		d(w, at, 3, 1, avg3(B, C, D))
	case 7:
		d(w, at, 0, 0, avg2(A, B))
		d(w, at, 1, 0, avg2(B, C));d(w, at, 0, 2, avg2(B, C))
		d(w, at, 2, 0, avg2(C, D));d(w, at, 1, 2, avg2(C, D))
		d(w, at, 3, 0, avg2(D, E));d(w, at, 2, 2, avg2(D, E))
		d(w, at, 0, 1, avg3(A, B, C))
		d(w, at, 1, 1, avg3(B, C, D));d(w, at, 0, 3, avg3(B, C, D))
		d(w, at, 2, 1, avg3(C, D, E));d(w, at, 1, 3, avg3(C, D, E))
		d(w, at, 3, 1, avg3(D, E, F));d(w, at, 2, 3, avg3(D, E, F))
		d(w, at, 3, 2, avg3(E, F, G))
		d(w, at, 3, 3, avg3(F, G, H))
	case 8:
		d(w, at, 0, 0, avg2(I, X));d(w, at, 2, 1, avg2(I, X))
		d(w, at, 0, 1, avg2(J, I));d(w, at, 2, 2, avg2(J, I))
		d(w, at, 0, 2, avg2(K, J));d(w, at, 2, 3, avg2(K, J))
		d(w, at, 0, 3, avg2(L, K))
		d(w, at, 3, 0, avg3(A, B, C))
		d(w, at, 2, 0, avg3(X, A, B))
		d(w, at, 1, 0, avg3(I, X, A));d(w, at, 3, 1, avg3(I, X, A))
		d(w, at, 1, 1, avg3(J, I, X));d(w, at, 3, 2, avg3(J, I, X))
		d(w, at, 1, 2, avg3(K, J, I));d(w, at, 3, 3, avg3(K, J, I))
		d(w, at, 1, 3, avg3(L, K, J))
	case 9:
		d(w, at, 0, 0, avg2(I, J))
		d(w, at, 2, 0, avg2(J, K));d(w, at, 0, 1, avg2(J, K))
		d(w, at, 2, 1, avg2(K, L));d(w, at, 0, 2, avg2(K, L))
		d(w, at, 1, 0, avg3(I, J, K))
		d(w, at, 3, 0, avg3(J, K, L));d(w, at, 1, 1, avg3(J, K, L))
		d(w, at, 3, 1, avg3(K, L, L));d(w, at, 1, 2, avg3(K, L, L))
		d(w, at, 3, 2, L);d(w, at, 2, 2, L);d(w, at, 0, 3, L);d(w, at, 1, 3, L);d(w, at, 2, 3, L);d(w, at, 3, 3, L)
	}
}

// A whole-block mode: 0 DC, 1 V, 2 H, 3 TM.
@(private = "file")
vp8_pred_block :: proc(mode: u8, w: []u8, size: int, mb_x, mb_y: int) {
	at := VP8_ORG
	top := at - VP8_BPS
	switch mode {
	case 0:
		sum: u32
		shift := size == 16 ? uint(3) : uint(2)
		if mb_y > 0 do for x in 0 ..< size do sum += u32(w[top + x])
		if mb_x > 0 do for y in 0 ..< size do sum += u32(w[at - 1 + y * VP8_BPS])
		v: u8
		switch {
		case mb_x > 0 && mb_y > 0:
			v = u8((sum + u32(size)) >> (shift + 2))
		case mb_x > 0 || mb_y > 0:
			v = u8((sum + u32(size / 2)) >> (shift + 1))
		case:
			v = 0x80
		}
		for y in 0 ..< size do for x in 0 ..< size do w[at + x + y * VP8_BPS] = v
	case 1:
		for y in 0 ..< size do for x in 0 ..< size do w[at + x + y * VP8_BPS] = w[top + x]
	case 2:
		for y in 0 ..< size {
			v := w[at - 1 + y * VP8_BPS]
			for x in 0 ..< size do w[at + x + y * VP8_BPS] = v
		}
	case 3:
		tl := i32(w[top - 1])
		for y in 0 ..< size {
			l := i32(w[at - 1 + y * VP8_BPS])
			for x in 0 ..< size do w[at + x + y * VP8_BPS] = vp8_clip8(i32(w[top + x]) + l - tl)
		}
	}
}

@(private = "file")
VP8_Filter :: struct {
	limit, ilevel, hev: i32,
	inner:              bool,
}

@(private = "file")
vp8_sclip1 :: #force_inline proc(v: i32) -> i32 {return clamp(v, -128, 127)}
@(private = "file")
vp8_sclip2 :: #force_inline proc(v: i32) -> i32 {return clamp(v, -16, 15)}

@(private = "file")
vp8_filter2 :: #force_inline proc(p: []u8, at, s: int) {
	p1, p0, q0, q1 := i32(p[at - 2 * s]), i32(p[at - s]), i32(p[at]), i32(p[at + s])
	a := 3 * (q0 - p0) + vp8_sclip1(p1 - q1)
	a1 := vp8_sclip2((a + 4) >> 3)
	a2 := vp8_sclip2((a + 3) >> 3)
	p[at - s] = vp8_clip8(p0 + a2)
	p[at] = vp8_clip8(q0 - a1)
}

@(private = "file")
vp8_filter4 :: #force_inline proc(p: []u8, at, s: int) {
	p1, p0, q0, q1 := i32(p[at - 2 * s]), i32(p[at - s]), i32(p[at]), i32(p[at + s])
	a := 3 * (q0 - p0)
	a1 := vp8_sclip2((a + 4) >> 3)
	a2 := vp8_sclip2((a + 3) >> 3)
	a3 := (a1 + 1) >> 1
	p[at - 2 * s] = vp8_clip8(p1 + a3)
	p[at - s] = vp8_clip8(p0 + a2)
	p[at] = vp8_clip8(q0 - a1)
	p[at + s] = vp8_clip8(q1 - a3)
}

@(private = "file")
vp8_filter6 :: #force_inline proc(p: []u8, at, s: int) {
	p2, p1, p0 := i32(p[at - 3 * s]), i32(p[at - 2 * s]), i32(p[at - s])
	q0, q1, q2 := i32(p[at]), i32(p[at + s]), i32(p[at + 2 * s])
	a := vp8_sclip1(3 * (q0 - p0) + vp8_sclip1(p1 - q1))
	a1 := (27 * a + 63) >> 7
	a2 := (18 * a + 63) >> 7
	a3 := (9 * a + 63) >> 7
	p[at - 3 * s] = vp8_clip8(p2 + a3)
	p[at - 2 * s] = vp8_clip8(p1 + a2)
	p[at - s] = vp8_clip8(p0 + a1)
	p[at] = vp8_clip8(q0 - a1)
	p[at + s] = vp8_clip8(q1 - a2)
	p[at + 2 * s] = vp8_clip8(q2 - a3)
}

@(private = "file")
vp8_needs_filter :: #force_inline proc(p: []u8, at, s: int, t: i32) -> bool {
	return 4 * abs(i32(p[at - s]) - i32(p[at])) + abs(i32(p[at - 2 * s]) - i32(p[at + s])) <= t
}

@(private = "file")
vp8_edge_simple :: proc(p: []u8, at, across, along, size: int, thresh: i32) {
	t := 2 * thresh + 1
	for i in 0 ..< size {
		a := at + i * along
		if vp8_needs_filter(p, a, across, t) do vp8_filter2(p, a, across)
	}
}

// One edge of the normal filter: `outer` for macroblock edges, the milder one inside a macroblock.
@(private = "file")
vp8_edge_normal :: proc(p: []u8, at, s, along, size: int, thresh, it, hev: i32, outer: bool) {
	t := 2 * thresh + 1
	for i in 0 ..< size {
		a := at + i * along
		if !vp8_needs_filter(p, a, s, t) do continue
		p3, p2, p1, p0 := i32(p[a - 4 * s]), i32(p[a - 3 * s]), i32(p[a - 2 * s]), i32(p[a - s])
		q0, q1, q2, q3 := i32(p[a]), i32(p[a + s]), i32(p[a + 2 * s]), i32(p[a + 3 * s])
		if abs(p3 - p2) > it || abs(p2 - p1) > it || abs(p1 - p0) > it || abs(q3 - q2) > it || abs(q2 - q1) > it || abs(q1 - q0) > it do continue
		if abs(p1 - p0) > hev || abs(q1 - q0) > hev {
			vp8_filter2(p, a, s)
		} else if outer {
			vp8_filter6(p, a, s)
		} else {
			vp8_filter4(p, a, s)
		}
	}
}

@(private = "file")
vp8_tree_bmode :: proc(b: ^VP8_Bool, p: []u8) -> u8 {
	if vp8_bit(b, p[0]) == 0 do return 0
	if vp8_bit(b, p[1]) == 0 do return 1
	if vp8_bit(b, p[2]) == 0 do return 2
	if vp8_bit(b, p[3]) == 0 {
		if vp8_bit(b, p[4]) == 0 do return 3
		return vp8_bit(b, p[5]) == 0 ? 5 : 6
	}
	if vp8_bit(b, p[6]) == 0 do return 4
	if vp8_bit(b, p[7]) == 0 do return 7
	return vp8_bit(b, p[8]) == 0 ? 8 : 9
}

@(private = "file")
vp8_put :: #force_inline proc(out: ^Color, y, u, v: u32) {
	clip :: #force_inline proc(x: i32) -> u8 {
		if x & ~i32((256 << 6) - 1) == 0 do return u8(x >> 6)
		return x < 0 ? 0 : 255
	}
	hi :: #force_inline proc(v, c: i32) -> i32 {return (v * c) >> 8}
	yy, uu, vv := i32(y), i32(u), i32(v)
	out^ = {clip(hi(yy, 19077) + hi(vv, 26149) - 14234), clip(hi(yy, 19077) - hi(uu, 6419) - hi(vv, 13320) + 8708), clip(hi(yy, 19077) + hi(uu, 33050) - 17685), 255}
}

// Two rows of pixels between two rows of chroma, upsampled smoothly. bot_y < 0: one row only.
@(private = "file")
vp8_row_pair :: proc(pix: []Color, w, top_y, bot_y: int, yp: []u8, ys: int, up, vp: []u8, uvs, tu, cu: int) {
	load :: #force_inline proc(up, vp: []u8, i: int) -> u32 {return u32(up[i]) | u32(vp[i]) << 16}
	ty := top_y * ys
	by := bot_y >= 0 ? bot_y * ys : 0
	tl := load(up, vp, tu * uvs)
	l := load(up, vp, cu * uvs)
	uv := (3 * tl + l + 0x00020002) >> 2
	vp8_put(&pix[top_y * w], u32(yp[ty]), uv & 255, (uv >> 16) & 255)
	if bot_y >= 0 {
		uv = (3 * l + tl + 0x00020002) >> 2
		vp8_put(&pix[bot_y * w], u32(yp[by]), uv & 255, (uv >> 16) & 255)
	}
	for x := 1; x <= (w - 1) >> 1; x += 1 {
		t := load(up, vp, tu * uvs + x)
		c := load(up, vp, cu * uvs + x)
		avg := tl + t + l + c + 0x00080008
		d12 := (avg + 2 * (t + l)) >> 3
		d03 := (avg + 2 * (tl + c)) >> 3
		uv0 := (d12 + tl) >> 1
		uv1 := (d03 + t) >> 1
		vp8_put(&pix[top_y * w + 2 * x - 1], u32(yp[ty + 2 * x - 1]), uv0 & 255, (uv0 >> 16) & 255)
		vp8_put(&pix[top_y * w + 2 * x], u32(yp[ty + 2 * x]), uv1 & 255, (uv1 >> 16) & 255)
		if bot_y >= 0 {
			uv0 = (d03 + l) >> 1
			uv1 = (d12 + c) >> 1
			vp8_put(&pix[bot_y * w + 2 * x - 1], u32(yp[by + 2 * x - 1]), uv0 & 255, (uv0 >> 16) & 255)
			vp8_put(&pix[bot_y * w + 2 * x], u32(yp[by + 2 * x]), uv1 & 255, (uv1 >> 16) & 255)
		}
		tl, l = t, c
	}
	if w & 1 == 0 {
		uv = (3 * tl + l + 0x00020002) >> 2
		vp8_put(&pix[top_y * w + w - 1], u32(yp[ty + w - 1]), uv & 255, (uv >> 16) & 255)
		if bot_y >= 0 {
			uv = (3 * l + tl + 0x00020002) >> 2
			vp8_put(&pix[bot_y * w + w - 1], u32(yp[by + w - 1]), uv & 255, (uv >> 16) & 255)
		}
	}
}

@(private = "file")
vp8_decode :: proc(body: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	if len(body) < 10 do return
	tag := int(body[0]) | int(body[1]) << 8 | int(body[2]) << 16
	if tag & 1 != 0 do return // not a key frame
	first_size := tag >> 5
	if body[3] != 0x9d || body[4] != 0x01 || body[5] != 0x2a do return
	w = (int(body[6]) | int(body[7]) << 8) & 0x3fff
	h = (int(body[8]) | int(body[9]) << 8) & 0x3fff
	if w < 1 || h < 1 || 10 + first_size > len(body) do return nil, 0, 0, false
	b: VP8_Bool
	vp8_bool_init(&b, body[10:10 + first_size])
	vp8_lit(&b, 1) // color space
	vp8_lit(&b, 1) // clamping type

	seg_on := vp8_lit(&b, 1) == 1
	seg_map := false
	seg_abs := false
	seg_q, seg_lf: [4]int
	seg_probs := [3]u8{255, 255, 255}
	if seg_on {
		seg_map = vp8_lit(&b, 1) == 1
		if vp8_lit(&b, 1) == 1 {
			seg_abs = vp8_lit(&b, 1) == 1
			for i in 0 ..< 4 do seg_q[i] = vp8_opt_signed(&b, 7)
			for i in 0 ..< 4 do seg_lf[i] = vp8_opt_signed(&b, 6)
		}
		if seg_map {
			for i in 0 ..< 3 do seg_probs[i] = vp8_lit(&b, 1) == 1 ? u8(vp8_lit(&b, 8)) : 255
		}
	}
	simple := vp8_lit(&b, 1) == 1
	level := vp8_lit(&b, 6)
	sharp := vp8_lit(&b, 3)
	use_delta := vp8_lit(&b, 1) == 1
	ref_delta, mode_delta: [4]int
	if use_delta && vp8_lit(&b, 1) == 1 {
		for i in 0 ..< 4 do if vp8_lit(&b, 1) == 1 do ref_delta[i] = vp8_signed(&b, 6)
		for i in 0 ..< 4 do if vp8_lit(&b, 1) == 1 do mode_delta[i] = vp8_signed(&b, 6)
	}

	// the token partitions follow the first partition, after a table of their sizes
	nparts := 1 << uint(vp8_lit(&b, 2))
	rest := body[10 + first_size:]
	table := 3 * (nparts - 1)
	if len(rest) < table do return nil, 0, 0, false
	parts := make([]VP8_Bool, nparts, context.temp_allocator)
	off := table
	for i in 0 ..< nparts {
		sz := len(rest) - off
		if i < nparts - 1 {
			sz = min(sz, int(rest[i * 3]) | int(rest[i * 3 + 1]) << 8 | int(rest[i * 3 + 2]) << 16)
		}
		vp8_bool_init(&parts[i], rest[off:off + sz])
		off += sz
	}

	q_base := vp8_lit(&b, 7)
	y1dc := vp8_opt_signed(&b, 4)
	y2dc := vp8_opt_signed(&b, 4)
	y2ac := vp8_opt_signed(&b, 4)
	uvdc := vp8_opt_signed(&b, 4)
	uvac := vp8_opt_signed(&b, 4)
	quants: [4]VP8_Quant
	for i in 0 ..< 4 {
		q := q_base
		if seg_on do q = seg_abs ? seg_q[i] : q + seg_q[i]
		dcq :: proc(q: int) -> i32 {return VP8_DC_Q[clamp(q, 0, 127)]}
		acq :: proc(q: int) -> i32 {return VP8_AC_Q[clamp(q, 0, 127)]}
		qq := &quants[i]
		qq.y1 = {dcq(q + y1dc), acq(q)}
		qq.y2 = {dcq(q + y2dc) * 2, max(acq(q + y2ac) * 155 / 100, 8)}
		qq.uv = {min(dcq(q + uvdc), 132), acq(q + uvac)}
	}
	vp8_lit(&b, 1) // refresh entropy: there is only this frame
	probs := VP8_COEFF_DEFAULT
	for i in 0 ..< 1056 {
		if vp8_bit(&b, VP8_COEFF_UPDATE[i]) == 1 do probs[i] = u8(vp8_lit(&b, 8))
	}
	use_skip := vp8_lit(&b, 1) == 1
	skip_prob: u8
	if use_skip do skip_prob = u8(vp8_lit(&b, 8))

	// filter strengths, by segment and whether a macroblock uses subblock modes
	filters: [4][2]VP8_Filter
	for s in 0 ..< 4 {
		base := level
		if seg_on do base = seg_abs ? seg_lf[s] : base + seg_lf[s]
		for i4 in 0 ..< 2 {
			l := base
			if use_delta {
				l += ref_delta[0]
				if i4 == 1 do l += mode_delta[0]
			}
			l = clamp(l, 0, 63)
			f := &filters[s][i4]
			if l > 0 {
				il := l
				if sharp > 0 {
					il >>= sharp > 4 ? uint(2) : uint(1)
					il = min(il, 9 - sharp)
				}
				il = max(il, 1)
				f.ilevel = i32(il)
				f.limit = i32(2 * l + il)
				f.hev = l >= 40 ? 2 : l >= 15 ? 1 : 0
			}
			f.inner = i4 == 1
		}
	}

	mbw, mbh := (w + 15) >> 4, (h + 15) >> 4
	ys, uvs := mbw * 16, mbw * 8
	yp := make([]u8, ys * mbh * 16, context.temp_allocator)
	up := make([]u8, uvs * mbh * 8, context.temp_allocator)
	vp := make([]u8, uvs * mbh * 8, context.temp_allocator)
	top_modes := make([]u8, mbw * 4, context.temp_allocator)
	Nz :: struct {
		y:  [4]u8,
		uv: [4]u8,
		dc: u8,
	}
	top_nz := make([]Nz, mbw, context.temp_allocator)
	finfo := make([]VP8_Filter, mbw * mbh, context.temp_allocator)
	yw: [VP8_BPS * 18]u8
	uw, vw: [VP8_BPS * 10]u8
	coeffs: [25 * 16]i32
	ORG, BPS := VP8_ORG, VP8_BPS

	for mb_y in 0 ..< mbh {
		left_modes: [4]u8
		left_nz: Nz
		token := &parts[mb_y & (nparts - 1)]
		for mb_x in 0 ..< mbw {
			segment := 0
			if seg_map {
				if vp8_bit(&b, seg_probs[0]) == 0 {
					segment = vp8_bit(&b, seg_probs[1])
				} else {
					segment = 2 + vp8_bit(&b, seg_probs[2])
				}
			}
			skip := use_skip && vp8_bit(&b, skip_prob) == 1
			// the luma mode: subblock modes, or one mode for the whole block
			is_i4 := vp8_bit(&b, 145) == 0
			imodes: [16]u8
			ymode: u8
			if !is_i4 {
				if vp8_bit(&b, 156) == 0 {
					ymode = u8(vp8_bit(&b, 163)) // DC or V
				} else {
					ymode = 2 + u8(vp8_bit(&b, 128)) // H or TM
				}
				implied_modes := [4]u8{0, 2, 3, 1}
				implied := implied_modes[ymode] // the subblock mode neighbors see
				for i in 0 ..< 4 {
					top_modes[mb_x * 4 + i] = implied
					left_modes[i] = implied
				}
			} else {
				for y in 0 ..< 4 {
					l := left_modes[y]
					for x in 0 ..< 4 {
						t := top_modes[mb_x * 4 + x]
						base := (int(t) * 10 + int(l)) * 9
						m := vp8_tree_bmode(&b, VP8_KF_BMODE[base:base + 9])
						imodes[y * 4 + x] = m
						l = m
						top_modes[mb_x * 4 + x] = m
					}
					left_modes[y] = l
				}
			}
			uvmode: u8
			if vp8_bit(&b, 142) == 0 {
				uvmode = 0
			} else if vp8_bit(&b, 114) == 0 {
				uvmode = 1
			} else {
				uvmode = 2 + u8(vp8_bit(&b, 183))
			}

			// residuals
			tn := &top_nz[mb_x]
			nonzero := false
			if skip {
				tn.y, tn.uv = {}, {}
				left_nz.y, left_nz.uv = {}, {}
				if !is_i4 {
					tn.dc = 0
					left_nz.dc = 0
				}
			} else {
				coeffs = {}
				qq := &quants[segment]
				first := 0
				kind := 3
				if !is_i4 {
					dc: [16]i32
					n := vp8_coeffs(token, &probs, 1, int(tn.dc + left_nz.dc), qq.y2, 0, dc[:])
					tn.dc = n > 0 ? 1 : 0
					left_nz.dc = tn.dc
					if n > 0 do nonzero = true
					vp8_wht(dc[:], coeffs[:])
					first, kind = 1, 0
				}
				for y in 0 ..< 4 {
					l := left_nz.y[y]
					for x in 0 ..< 4 {
						i := y * 4 + x
						n := vp8_coeffs(token, &probs, kind, int(l + tn.y[x]), qq.y1, first, coeffs[i * 16:i * 16 + 16])
						l = n > first ? 1 : 0
						tn.y[x] = l
						if l != 0 do nonzero = true
					}
					left_nz.y[y] = l
				}
				for ch in 0 ..< 2 {
					for y in 0 ..< 2 {
						l := left_nz.uv[ch * 2 + y]
						for x in 0 ..< 2 {
							i := 16 + ch * 4 + y * 2 + x
							n := vp8_coeffs(token, &probs, 2, int(l + tn.uv[ch * 2 + x]), qq.uv, 0, coeffs[i * 16:i * 16 + 16])
							l = n > 0 ? 1 : 0
							tn.uv[ch * 2 + x] = l
							if l != 0 do nonzero = true
						}
						left_nz.uv[ch * 2 + y] = l
					}
				}
			}
			f := filters[segment][is_i4 ? 1 : 0]
			f.inner = f.inner || nonzero
			finfo[mb_y * mbw + mb_x] = f

			// the borders the prediction reads: unfiltered, because the loop filter runs afterwards
			if mb_y > 0 {
				py := (mb_y * 16 - 1) * ys + mb_x * 16
				copy(yw[ORG - BPS:ORG - BPS + 16], yp[py:py + 16])
				if mb_x < mbw - 1 {
					copy(yw[ORG - BPS + 16:ORG - BPS + 20], yp[py + 16:py + 20])
				} else {
					for i in 16 ..< 20 do yw[ORG - BPS + i] = yp[py + 15]
				}
				pu := (mb_y * 8 - 1) * uvs + mb_x * 8
				copy(uw[ORG - BPS:ORG - BPS + 8], up[pu:pu + 8])
				copy(vw[ORG - BPS:ORG - BPS + 8], vp[pu:pu + 8])
				if mb_x > 0 {
					yw[ORG - BPS - 1] = yp[py - 1]
					uw[ORG - BPS - 1] = up[pu - 1]
					vw[ORG - BPS - 1] = vp[pu - 1]
				} else {
					yw[ORG - BPS - 1], uw[ORG - BPS - 1], vw[ORG - BPS - 1] = 129, 129, 129
				}
			} else {
				for i in -1 ..< 20 do yw[ORG - BPS + i] = 127
				for i in -1 ..< 8 {
					uw[ORG - BPS + i] = 127
					vw[ORG - BPS + i] = 127
				}
			}
			for y in 0 ..< 16 {
				yw[ORG - 1 + y * BPS] = mb_x > 0 ? yp[(mb_y * 16 + y) * ys + mb_x * 16 - 1] : 129
			}
			for y in 0 ..< 8 {
				uw[ORG - 1 + y * BPS] = mb_x > 0 ? up[(mb_y * 8 + y) * uvs + mb_x * 8 - 1] : 129
				vw[ORG - 1 + y * BPS] = mb_x > 0 ? vp[(mb_y * 8 + y) * uvs + mb_x * 8 - 1] : 129
			}

			if is_i4 {
				// subblocks down the right side all use the row above the macroblock
				for row in 1 ..< 4 {
					for i in 16 ..< 20 do yw[ORG + (row * 4 - 1) * BPS + i] = yw[ORG - BPS + i]
				}
				for i in 0 ..< 16 {
					at := ORG + (i % 4) * 4 + (i / 4) * 4 * BPS
					vp8_pred4(imodes[i], yw[:], at)
					if !skip do vp8_idct(coeffs[i * 16:i * 16 + 16], yw[:], at)
				}
			} else {
				vp8_pred_block(ymode, yw[:], 16, mb_x, mb_y)
				if !skip {
					for i in 0 ..< 16 do vp8_idct(coeffs[i * 16:i * 16 + 16], yw[:], ORG + (i % 4) * 4 + (i / 4) * 4 * BPS)
				}
			}
			vp8_pred_block(uvmode, uw[:], 8, mb_x, mb_y)
			vp8_pred_block(uvmode, vw[:], 8, mb_x, mb_y)
			if !skip {
				for i in 0 ..< 4 {
					at := ORG + (i % 2) * 4 + (i / 2) * 4 * BPS
					vp8_idct(coeffs[(16 + i) * 16:(17 + i) * 16], uw[:], at)
					vp8_idct(coeffs[(20 + i) * 16:(21 + i) * 16], vw[:], at)
				}
			}
			for y in 0 ..< 16 {
				copy(yp[(mb_y * 16 + y) * ys + mb_x * 16:][:16], yw[ORG + y * BPS:][:16])
			}
			for y in 0 ..< 8 {
				copy(up[(mb_y * 8 + y) * uvs + mb_x * 8:][:8], uw[ORG + y * BPS:][:8])
				copy(vp[(mb_y * 8 + y) * uvs + mb_x * 8:][:8], vw[ORG + y * BPS:][:8])
			}
		}
	}

	// the loop filter, a macroblock at a time. A level of 0 in the frame header turns it off altogether.
	if level > 0 {
		for mb_y in 0 ..< mbh {
			for mb_x in 0 ..< mbw {
				f := finfo[mb_y * mbw + mb_x]
				if f.limit == 0 do continue
				y0 := mb_y * 16 * ys + mb_x * 16
				u0 := mb_y * 8 * uvs + mb_x * 8
				if simple {
					if mb_x > 0 do vp8_edge_simple(yp, y0, 1, ys, 16, f.limit + 4)
					if f.inner {
						for k in 1 ..< 4 do vp8_edge_simple(yp, y0 + k * 4, 1, ys, 16, f.limit)
					}
					if mb_y > 0 do vp8_edge_simple(yp, y0, ys, 1, 16, f.limit + 4)
					if f.inner {
						for k in 1 ..< 4 do vp8_edge_simple(yp, y0 + k * 4 * ys, ys, 1, 16, f.limit)
					}
					continue
				}
				if mb_x > 0 {
					vp8_edge_normal(yp, y0, 1, ys, 16, f.limit + 4, f.ilevel, f.hev, true)
					vp8_edge_normal(up, u0, 1, uvs, 8, f.limit + 4, f.ilevel, f.hev, true)
					vp8_edge_normal(vp, u0, 1, uvs, 8, f.limit + 4, f.ilevel, f.hev, true)
				}
				if f.inner {
					for k in 1 ..< 4 do vp8_edge_normal(yp, y0 + k * 4, 1, ys, 16, f.limit, f.ilevel, f.hev, false)
					vp8_edge_normal(up, u0 + 4, 1, uvs, 8, f.limit, f.ilevel, f.hev, false)
					vp8_edge_normal(vp, u0 + 4, 1, uvs, 8, f.limit, f.ilevel, f.hev, false)
				}
				if mb_y > 0 {
					vp8_edge_normal(yp, y0, ys, 1, 16, f.limit + 4, f.ilevel, f.hev, true)
					vp8_edge_normal(up, u0, uvs, 1, 8, f.limit + 4, f.ilevel, f.hev, true)
					vp8_edge_normal(vp, u0, uvs, 1, 8, f.limit + 4, f.ilevel, f.hev, true)
				}
				if f.inner {
					for k in 1 ..< 4 do vp8_edge_normal(yp, y0 + k * 4 * ys, ys, 1, 16, f.limit, f.ilevel, f.hev, false)
					vp8_edge_normal(up, u0 + 4 * uvs, uvs, 1, 8, f.limit, f.ilevel, f.hev, false)
					vp8_edge_normal(vp, u0 + 4 * uvs, uvs, 1, 8, f.limit, f.ilevel, f.hev, false)
				}
			}
		}
	}

	// to RGB, with the chroma planes smoothly upsampled
	pix = make([]Color, w * h)
	vp8_row_pair(pix, w, 0, -1, yp, ys, up, vp, uvs, 0, 0)
	y := 1
	for ; y + 1 < h; y += 2 {
		k := y / 2
		vp8_row_pair(pix, w, y, y + 1, yp, ys, up, vp, uvs, k, k + 1)
	}
	if y < h {
		k := y / 2
		vp8_row_pair(pix, w, y, -1, yp, ys, up, vp, uvs, k, k)
	}
	return pix, w, h, true
}

@(private = "file")
VP8_COEFF_UPDATE := [1056]u8 {
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255, 249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255, 234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255, 250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255,
	234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255,
	255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255, 249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255, 234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255,
	251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255,
	255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255,
	248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255, 255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255, 252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255,
	255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255, 248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
	253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255, 253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255, 252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
}

@(private = "file")
VP8_COEFF_DEFAULT := [1056]u8 {
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128,
	189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128, 106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128,
	1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128, 181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128,
	78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128, 1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128,
	184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128, 77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128,
	1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128, 170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128,
	37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128, 1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
	207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128, 102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128,
	1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128, 177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128,
	80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62, 131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1,
	68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128, 1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128,
	184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128, 81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128,
	1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128, 99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
	23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128, 1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128,
	109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128, 44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128,
	1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128, 94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128,
	22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128, 1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128,
	124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128, 35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128,
	1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128, 121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128,
	45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128, 1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128,
	203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128, 137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
	253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128, 175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128,
	73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128, 1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128,
	239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128, 155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128,
	1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128, 201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128,
	69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128, 1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128,
	223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128, 141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128,
	1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128, 190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128,
	149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128, 240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128, 213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128,
	55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255, 126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128,
	61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128, 1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128,
	166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128, 39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128,
	1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128, 124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
	24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128, 1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128,
	149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128, 28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128,
	1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128, 123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128,
	20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128, 1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128,
	168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128, 47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128,
	1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128, 141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128,
	42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
	244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
}

@(private = "file")
VP8_KF_BMODE := [900]u8 {
	231, 120, 48, 89, 115, 113, 120, 152, 112, 152, 179, 64, 126, 170, 118, 46, 70, 95, 175, 69, 143, 80,
	85, 82, 72, 155, 103, 56, 58, 10, 171, 218, 189, 17, 13, 152, 144, 71, 10, 38, 171, 213, 144, 34,
	26, 114, 26, 17, 163, 44, 195, 21, 10, 173, 121, 24, 80, 195, 26, 62, 44, 64, 85, 170, 46, 55,
	19, 136, 160, 33, 206, 71, 63, 20, 8, 114, 114, 208, 12, 9, 226, 81, 40, 11, 96, 182, 84, 29,
	16, 36, 134, 183, 89, 137, 98, 101, 106, 165, 148, 72, 187, 100, 130, 157, 111, 32, 75, 80, 66, 102,
	167, 99, 74, 62, 40, 234, 128, 41, 53, 9, 178, 241, 141, 26, 8, 107, 104, 79, 12, 27, 217, 255,
	87, 17, 7, 74, 43, 26, 146, 73, 166, 49, 23, 157, 65, 38, 105, 160, 51, 52, 31, 115, 128, 87,
	68, 71, 44, 114, 51, 15, 186, 23, 47, 41, 14, 110, 182, 183, 21, 17, 194, 66, 45, 25, 102, 197,
	189, 23, 18, 22, 88, 88, 147, 150, 42, 46, 45, 196, 205, 43, 97, 183, 117, 85, 38, 35, 179, 61,
	39, 53, 200, 87, 26, 21, 43, 232, 171, 56, 34, 51, 104, 114, 102, 29, 93, 77, 107, 54, 32, 26,
	51, 1, 81, 43, 31, 39, 28, 85, 171, 58, 165, 90, 98, 64, 34, 22, 116, 206, 23, 34, 43, 166,
	73, 68, 25, 106, 22, 64, 171, 36, 225, 114, 34, 19, 21, 102, 132, 188, 16, 76, 124, 62, 18, 78,
	95, 85, 57, 50, 48, 51, 193, 101, 35, 159, 215, 111, 89, 46, 111, 60, 148, 31, 172, 219, 228, 21,
	18, 111, 112, 113, 77, 85, 179, 255, 38, 120, 114, 40, 42, 1, 196, 245, 209, 10, 25, 109, 100, 80,
	8, 43, 154, 1, 51, 26, 71, 88, 43, 29, 140, 166, 213, 37, 43, 154, 61, 63, 30, 155, 67, 45,
	68, 1, 209, 142, 78, 78, 16, 255, 128, 34, 197, 171, 41, 40, 5, 102, 211, 183, 4, 1, 221, 51,
	50, 17, 168, 209, 192, 23, 25, 82, 125, 98, 42, 88, 104, 85, 117, 175, 82, 95, 84, 53, 89, 128,
	100, 113, 101, 45, 75, 79, 123, 47, 51, 128, 81, 171, 1, 57, 17, 5, 71, 102, 57, 53, 41, 49,
	115, 21, 2, 10, 102, 255, 166, 23, 6, 38, 33, 13, 121, 57, 73, 26, 1, 85, 41, 10, 67, 138,
	77, 110, 90, 47, 114, 101, 29, 16, 10, 85, 128, 101, 196, 26, 57, 18, 10, 102, 102, 213, 34, 20,
	43, 117, 20, 15, 36, 163, 128, 68, 1, 26, 138, 31, 36, 171, 27, 166, 38, 44, 229, 67, 87, 58,
	169, 82, 115, 26, 59, 179, 63, 59, 90, 180, 59, 166, 93, 73, 154, 40, 40, 21, 116, 143, 209, 34,
	39, 175, 57, 46, 22, 24, 128, 1, 54, 17, 37, 47, 15, 16, 183, 34, 223, 49, 45, 183, 46, 17,
	33, 183, 6, 98, 15, 32, 183, 65, 32, 73, 115, 28, 128, 23, 128, 205, 40, 3, 9, 115, 51, 192,
	18, 6, 223, 87, 37, 9, 115, 59, 77, 64, 21, 47, 104, 55, 44, 218, 9, 54, 53, 130, 226, 64,
	90, 70, 205, 40, 41, 23, 26, 57, 54, 57, 112, 184, 5, 41, 38, 166, 213, 30, 34, 26, 133, 152,
	116, 10, 32, 134, 75, 32, 12, 51, 192, 255, 160, 43, 51, 39, 19, 53, 221, 26, 114, 32, 73, 255,
	31, 9, 65, 234, 2, 15, 1, 118, 73, 88, 31, 35, 67, 102, 85, 55, 186, 85, 56, 21, 23, 111,
	59, 205, 45, 37, 192, 55, 38, 70, 124, 73, 102, 1, 34, 98, 102, 61, 71, 37, 34, 53, 31, 243,
	192, 69, 60, 71, 38, 73, 119, 28, 222, 37, 68, 45, 128, 34, 1, 47, 11, 245, 171, 62, 17, 19,
	70, 146, 85, 55, 62, 70, 75, 15, 9, 9, 64, 255, 184, 119, 16, 37, 43, 37, 154, 100, 163, 85,
	160, 1, 63, 9, 92, 136, 28, 64, 32, 201, 85, 86, 6, 28, 5, 64, 255, 25, 248, 1, 56, 8,
	17, 132, 137, 255, 55, 116, 128, 58, 15, 20, 82, 135, 57, 26, 121, 40, 164, 50, 31, 137, 154, 133,
	25, 35, 218, 51, 103, 44, 131, 131, 123, 31, 6, 158, 86, 40, 64, 135, 148, 224, 45, 183, 128, 22,
	26, 17, 131, 240, 154, 14, 1, 209, 83, 12, 13, 54, 192, 255, 68, 47, 28, 45, 16, 21, 91, 64,
	222, 7, 1, 197, 56, 21, 39, 155, 60, 138, 23, 102, 213, 85, 26, 85, 85, 128, 128, 32, 146, 171,
	18, 11, 7, 63, 144, 171, 4, 4, 246, 35, 27, 10, 146, 174, 171, 12, 26, 128, 190, 80, 35, 99,
	180, 80, 126, 54, 45, 85, 126, 47, 87, 176, 51, 41, 20, 32, 101, 75, 128, 139, 118, 146, 116, 128,
	85, 56, 41, 15, 176, 236, 85, 37, 9, 62, 146, 36, 19, 30, 171, 255, 97, 27, 20, 71, 30, 17,
	119, 118, 255, 17, 18, 138, 101, 38, 60, 138, 55, 70, 43, 26, 142, 138, 45, 61, 62, 219, 1, 81,
	188, 64, 32, 41, 20, 117, 151, 142, 20, 21, 163, 112, 19, 12, 61, 195, 128, 48, 4, 24,
}

@(private = "file")
VP8_DC_Q := [128]i32 {
	4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17, 18, 19, 20, 20, 21, 21,
	22, 22, 23, 23, 24, 25, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39,
	40, 41, 42, 43, 44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
	61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 76, 77, 78, 79, 80, 81,
	82, 83, 84, 85, 86, 87, 88, 89, 91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114,
	116, 118, 122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
}

@(private = "file")
VP8_AC_Q := [128]i32 {
	4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
	26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
	48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80,
	82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110, 112, 114, 116, 119, 122, 125, 128,
	131, 134, 137, 140, 143, 146, 149, 152, 155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201,
	205, 209, 213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
}
