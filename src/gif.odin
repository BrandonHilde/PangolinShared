package pangolin

// Animated GIF: one palette for all frames (median cut when there are more than 255 colors), LZW
// compressed. Pixels with alpha below 128 become the transparent color 0.

Ucol :: struct {
	rgb:   [3]u8,
	count: int,
	box:   int,
}

Cbox :: struct {
	lo, hi: int, // range in `order`
}

gif_build_palette :: proc(comps: [][]Color) -> (pal: [256][3]u8, lookup: map[u32]u8) {
	lookup = make(map[u32]u8, 256, context.temp_allocator)
	counts := make(map[u32]int, 1024, context.temp_allocator)
	for fp in comps {
		for p in fp {
			if p.a >= 128 {
				counts[u32(p.r) << 16 | u32(p.g) << 8 | u32(p.b)] += 1
			}
		}
	}
	ucs := make([dynamic]Ucol, context.temp_allocator)
	for k, v in counts {
		append(&ucs, Ucol{{u8(k >> 16), u8(k >> 8), u8(k)}, v, 0})
	}
	if len(ucs) <= 255 {
		for u, i in ucs {
			pal[i + 1] = u.rgb
			lookup[u32(u.rgb.r) << 16 | u32(u.rgb.g) << 8 | u32(u.rgb.b)] = u8(i + 1)
		}
		return
	}
	// median cut
	order := make([]int, len(ucs), context.temp_allocator)
	for i in 0 ..< len(order) do order[i] = i
	boxes := make([dynamic]Cbox, context.temp_allocator)
	append(&boxes, Cbox{0, len(order)})
	range_of :: proc(ucs: []Ucol, order: []int, b: Cbox) -> (axis, rng: int) {
		mn := [3]int{255, 255, 255}
		mx := [3]int{}
		for i in b.lo ..< b.hi {
			u := ucs[order[i]]
			for c in 0 ..< 3 {
				mn[c] = min(mn[c], int(u.rgb[c]))
				mx[c] = max(mx[c], int(u.rgb[c]))
			}
		}
		for c in 0 ..< 3 {
			if mx[c] - mn[c] > rng {
				rng = mx[c] - mn[c]
				axis = c
			}
		}
		return
	}
	for len(boxes) < 255 {
		best, best_rng, best_axis := -1, 0, 0
		for b, i in boxes {
			if b.hi - b.lo < 2 do continue
			axis, rng := range_of(ucs[:], order, b)
			if rng > best_rng {
				best, best_rng, best_axis = i, rng, axis
			}
		}
		if best < 0 do break
		b := boxes[best]
		sub := order[b.lo:b.hi]
		ax := best_axis
		// sort by chosen axis (closure-free: use a global key)
		gif_sort_axis = ax
		gif_sort_ucs = ucs[:]
		slice.sort_by(sub, proc(a, b: int) -> bool {
			return gif_sort_ucs[a].rgb[gif_sort_axis] < gif_sort_ucs[b].rgb[gif_sort_axis]
		})
		total := 0
		for i in b.lo ..< b.hi do total += ucs[order[i]].count
		acc := 0
		mid := b.lo + 1
		for i in b.lo ..< b.hi - 1 {
			acc += ucs[order[i]].count
			mid = i + 1
			if acc * 2 >= total do break
		}
		boxes[best] = Cbox{b.lo, mid}
		append(&boxes, Cbox{mid, b.hi})
	}
	for b, bi in boxes {
		sum := [3]int{}
		tot := 0
		for i in b.lo ..< b.hi {
			u := ucs[order[i]]
			ucs[order[i]].box = bi
			for c in 0 ..< 3 do sum[c] += int(u.rgb[c]) * u.count
			tot += u.count
		}
		tot = max(tot, 1)
		pal[bi + 1] = {u8(sum[0] / tot), u8(sum[1] / tot), u8(sum[2] / tot)}
	}
	for u in ucs {
		lookup[u32(u.rgb[0]) << 16 | u32(u.rgb[1]) << 8 | u32(u.rgb[2])] = u8(u.box + 1)
	}
	return
}

@(private = "file")
gif_sort_axis: int
@(private = "file")
gif_sort_ucs: []Ucol

Bit_Writer :: struct {
	out:   ^[dynamic]u8,
	acc:   u32,
	nbits: u32,
}

bw_put :: proc(b: ^Bit_Writer, code: u32, size: u32) {
	b.acc |= code << b.nbits
	b.nbits += size
	for b.nbits >= 8 {
		append(b.out, u8(b.acc))
		b.acc >>= 8
		b.nbits -= 8
	}
}

bw_flush :: proc(b: ^Bit_Writer) {
	if b.nbits > 0 {
		append(b.out, u8(b.acc))
		b.acc = 0
		b.nbits = 0
	}
}

lzw_encode :: proc(idx: []u8, out: ^[dynamic]u8) {
	CLEAR :: 256
	EOI :: 257
	bw := Bit_Writer{out = out}
	dict := make(map[u32]u16, 4096, context.temp_allocator)
	next: u32 = 258
	size: u32 = 9
	bw_put(&bw, CLEAR, size)
	if len(idx) == 0 {
		bw_put(&bw, EOI, size)
		bw_flush(&bw)
		return
	}
	prefix := u32(idx[0])
	for i in 1 ..< len(idx) {
		b := idx[i]
		key := prefix << 8 | u32(b)
		if code, ok := dict[key]; ok {
			prefix = u32(code)
			continue
		}
		bw_put(&bw, prefix, size)
		dict[key] = u16(next)
		next += 1
		if next > (1 << size) && size < 12 {
			size += 1
		}
		if next >= 4094 {
			bw_put(&bw, CLEAR, size)
			clear(&dict)
			next = 258
			size = 9
		}
		prefix = u32(b)
	}
	bw_put(&bw, prefix, size)
	bw_put(&bw, EOI, size)
	bw_flush(&bw)
}

gif_w16 :: proc(out: ^[dynamic]u8, v: int) {
	append(out, u8(v), u8(v >> 8))
}

// `frames` are each src_w x src_h, drawn `scale` times as large. Result in the temp allocator.
gif_encode_frames :: proc(frames: [][]Color, src_w, src_h, scale: int, delays_ms: []int, loop: bool) -> []u8 {
	pal, lookup := gif_build_palette(frames)
	w, h := src_w * scale, src_h * scale
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..transmute([]u8)string("GIF89a"))
	gif_w16(&out, w)
	gif_w16(&out, h)
	append(&out, 0xF7, 0, 0)
	for i in 0 ..< 256 do append(&out, pal[i][0], pal[i][1], pal[i][2])
	if loop {
		append(&out, 0x21, 0xFF, 0x0B)
		append(&out, ..transmute([]u8)string("NETSCAPE2.0"))
		append(&out, 3, 1, 0, 0, 0)
	}
	idx := make([]u8, w * h, context.temp_allocator)
	for fp, i in frames {
		for y in 0 ..< h {
			for x in 0 ..< w {
				p := fp[(y / scale) * src_w + x / scale]
				v: u8 = 0
				if p.a >= 128 do v = lookup[u32(p.r) << 16 | u32(p.g) << 8 | u32(p.b)]
				idx[y * w + x] = v
			}
		}
		append(&out, 0x21, 0xF9, 0x04, (2 << 2) | 1)
		gif_w16(&out, max(delays_ms[i] / 10, 2))
		append(&out, 0, 0)
		append(&out, 0x2C)
		gif_w16(&out, 0)
		gif_w16(&out, 0)
		gif_w16(&out, w)
		gif_w16(&out, h)
		append(&out, 0, 8)
		data := make([dynamic]u8, context.temp_allocator)
		lzw_encode(idx, &data)
		pos := 0
		for pos < len(data) {
			chunk := min(255, len(data) - pos)
			append(&out, u8(chunk))
			append(&out, ..data[pos:pos + chunk])
			pos += chunk
		}
		append(&out, 0)
	}
	append(&out, 0x3B)
	return out[:]
}
