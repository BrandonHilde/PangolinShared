package pangolin

import "core:math"

// Pure-Odin JPEG decoder, identical on every platform. stb_image has no CMYK support and
// Odin's core:image/jpeg is baseline-only, so photos (often progressive) need this.
// Supports baseline + progressive Huffman coding, 8-bit precision, 1/3/4 components
// (grey, YCbCr/RGB, CMYK/YCCK), any sampling factors, restart markers and EXIF
// orientation. Not supported: arithmetic coding, lossless, 12-bit (rare in practice).

@(private = "file")
ZIGZAG := [64]u8 {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

@(private = "file")
JPG_FAST_BITS :: 9

@(private = "file")
Jpg_Huff :: struct {
	fast:    [1 << JPG_FAST_BITS]u16, // (length << 8) | symbol for short codes; 0 = slow path
	maxcode: [17]i32,
	mincode: [17]i32,
	valptr:  [17]i32,
	vals:    [256]u8,
	ok:      bool,
}

@(private = "file")
Jpg_Comp :: struct {
	id:             u8,
	h, v, tq:       int,
	bw, bh:         int, // blocks allocated (padded to whole MCUs)
	cbw, cbh:       int, // blocks covering the component itself (non-interleaved scans)
	coefs:          []i16,
	pred:           int,
	dc_tbl, ac_tbl: int,
}

@(private = "file")
Jpg :: struct {
	qt:              [4][64]u16,
	dc:              [4]Jpg_Huff,
	ac:              [4]Jpg_Huff,
	comps:           [4]Jpg_Comp,
	ncomp:           int,
	w, h:            int,
	hmax, vmax:      int,
	mcux, mcuy:      int,
	progressive:     bool,
	frame_ok:        bool,
	any_scan:        bool,
	restart:         int,
	eobrun:          int,
	adobe:           bool,
	adobe_transform: int,
	orientation:     int,
	file_len:        int,
}

@(private = "file")
Jpg_Bits :: struct {
	data:   []u8,
	pos:    int,
	buf:    u32, // MSB-aligned
	cnt:    u32,
	marker: bool, // hit a marker: feed zeros from now on
}

// Largest image we try to decode (pixels); guards against absurd headers.
JPEG_MAX_PIXELS :: 1 << 28

jpeg_decode :: proc(data: []u8) -> (pix: []Color, w, h: int, ok: bool) {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return
	}
	j := new(Jpg)
	j.file_len = len(data)
	defer {
		for &c in j.comps {
			delete(c.coefs)
		}
		free(j)
	}
	pos := 2
	parse: for {
		for pos < len(data) && data[pos] != 0xFF {
			pos += 1
		}
		for pos < len(data) && data[pos] == 0xFF {
			pos += 1
		}
		if pos >= len(data) {
			break
		}
		m := data[pos]
		pos += 1
		switch m {
		case 0xD9:
			break parse
		case 0x01, 0xD0 ..= 0xD7:
			continue parse
		}
		if pos + 2 > len(data) {
			break
		}
		seg_len := int(data[pos]) << 8 | int(data[pos + 1])
		if seg_len < 2 || pos + seg_len > len(data) {
			break
		}
		seg := data[pos + 2:pos + seg_len]
		pos += seg_len
		switch m {
		case 0xDB:
			if !jpg_dqt(j, seg) do return
		case 0xC4:
			if !jpg_dht(j, seg) do return
		case 0xC0, 0xC1, 0xC2:
			if !jpg_sof(j, seg, m == 0xC2) do return
		case 0xC3, 0xC5 ..= 0xC7, 0xC9 ..= 0xCB, 0xCD ..= 0xCF:
			return // lossless, hierarchical or arithmetic coded
		case 0xDD:
			if len(seg) >= 2 {
				j.restart = int(seg[0]) << 8 | int(seg[1])
			}
		case 0xE1:
			jpg_exif(j, seg)
		case 0xEE:
			if len(seg) >= 12 && string(seg[:5]) == "Adobe" {
				j.adobe = true
				j.adobe_transform = int(seg[11])
			}
		case 0xDA:
			if !j.frame_ok do return
			np, sok := jpg_scan(j, data, pos, seg)
			if !sok do return
			pos = np
		}
	}
	if !j.frame_ok || !j.any_scan {
		return
	}
	pix = jpg_output(j)
	pix, w, h = image_orient(pix, j.w, j.h, j.orientation)
	ok = true
	return
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

@(private = "file")
jpg_dqt :: proc(j: ^Jpg, seg: []u8) -> bool {
	p := 0
	for p < len(seg) {
		pq, tq := seg[p] >> 4, int(seg[p] & 15)
		p += 1
		n := pq == 0 ? 64 : 128
		if tq > 3 || p + n > len(seg) {
			return false
		}
		for k in 0 ..< 64 {
			v := pq == 0 ? u16(seg[p + k]) : u16(seg[p + 2 * k]) << 8 | u16(seg[p + 2 * k + 1])
			j.qt[tq][ZIGZAG[k]] = v
		}
		p += n
	}
	return true
}

@(private = "file")
jpg_dht :: proc(j: ^Jpg, seg: []u8) -> bool {
	p := 0
	for p < len(seg) {
		if p + 17 > len(seg) {
			return false
		}
		tc, th := seg[p] >> 4, int(seg[p] & 15)
		if tc > 1 || th > 3 {
			return false
		}
		counts: [16]u8
		total := 0
		for i in 0 ..< 16 {
			counts[i] = seg[p + 1 + i]
			total += int(counts[i])
		}
		p += 17
		if total > 256 || p + total > len(seg) {
			return false
		}
		t := tc == 0 ? &j.dc[th] : &j.ac[th]
		if !jpg_build_huff(t, counts, seg[p:p + total]) {
			return false
		}
		p += total
	}
	return true
}

@(private = "file")
jpg_build_huff :: proc(t: ^Jpg_Huff, counts: [16]u8, syms: []u8) -> bool {
	t^ = {}
	code, k: i32
	for l in 1 ..= 16 {
		n := i32(counts[l - 1])
		t.valptr[l] = k
		t.mincode[l] = code
		code += n
		k += n
		t.maxcode[l] = n > 0 ? code - 1 : -1
		if code > 1 << uint(l) {
			return false
		}
		code <<= 1
	}
	copy(t.vals[:], syms)
	for l in 1 ..= JPG_FAST_BITS {
		for i in 0 ..< i32(counts[l - 1]) {
			sym := t.vals[t.valptr[l] + i]
			shift := uint(JPG_FAST_BITS - l)
			base := int((t.mincode[l] + i) << shift)
			for f in 0 ..< 1 << shift {
				t.fast[base + f] = u16(l) << 8 | u16(sym)
			}
		}
	}
	t.ok = true
	return true
}

@(private = "file")
jpg_sof :: proc(j: ^Jpg, seg: []u8, progressive: bool) -> bool {
	if j.frame_ok || len(seg) < 6 || seg[0] != 8 {
		return false
	}
	j.h = int(seg[1]) << 8 | int(seg[2])
	j.w = int(seg[3]) << 8 | int(seg[4])
	nc := int(seg[5])
	// each 8x8 block takes at least one bit of the file, so a small file can't hold a huge picture: without this a
	// few bytes of header could ask for gigabytes
	if j.w == 0 || j.h == 0 || j.w * j.h > JPEG_MAX_PIXELS || j.w * j.h > j.file_len * 512 + 4096 || (nc != 1 && nc != 3 && nc != 4) || len(seg) < 6 + nc * 3 {
		return false
	}
	j.ncomp = nc
	j.hmax, j.vmax = 1, 1
	for i in 0 ..< nc {
		c := &j.comps[i]
		c.id = seg[6 + i * 3]
		c.h = int(seg[7 + i * 3] >> 4)
		c.v = int(seg[7 + i * 3] & 15)
		c.tq = int(seg[8 + i * 3])
		if c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 || c.tq > 3 {
			return false
		}
		if nc == 1 {
			c.h, c.v = 1, 1 // a lone component is always one block per MCU
		}
		j.hmax = max(j.hmax, c.h)
		j.vmax = max(j.vmax, c.v)
	}
	j.mcux = (j.w + 8 * j.hmax - 1) / (8 * j.hmax)
	j.mcuy = (j.h + 8 * j.vmax - 1) / (8 * j.vmax)
	for i in 0 ..< nc {
		c := &j.comps[i]
		c.bw = j.mcux * c.h
		c.bh = j.mcuy * c.v
		c.cbw = ((j.w * c.h + j.hmax - 1) / j.hmax + 7) / 8
		c.cbh = ((j.h * c.v + j.vmax - 1) / j.vmax + 7) / 8
		c.coefs = make([]i16, c.bw * c.bh * 64)
	}
	j.progressive = progressive
	j.frame_ok = true
	return true
}

@(private = "file")
jpg_exif :: proc(j: ^Jpg, seg: []u8) {
	if len(seg) < 14 || string(seg[:6]) != "Exif\x00\x00" {
		return
	}
	t := seg[6:]
	le := t[0] == 'I' && t[1] == 'I'
	if !le && !(t[0] == 'M' && t[1] == 'M') {
		return
	}
	r16 :: proc(t: []u8, o: int, le: bool) -> int {
		return le ? int(t[o]) | int(t[o + 1]) << 8 : int(t[o]) << 8 | int(t[o + 1])
	}
	r32 :: proc(t: []u8, o: int, le: bool) -> int {
		return le ? r16(t, o, le) | r16(t, o + 2, le) << 16 : r16(t, o, le) << 16 | r16(t, o + 2, le)
	}
	ifd := r32(t, 4, le)
	if ifd < 8 || ifd + 2 > len(t) {
		return
	}
	n := r16(t, ifd, le)
	for i in 0 ..< n {
		e := ifd + 2 + i * 12
		if e + 12 > len(t) {
			return
		}
		if r16(t, e, le) == 0x0112 {
			j.orientation = r16(t, e + 8, le)
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Entropy decoding
// ---------------------------------------------------------------------------

@(private = "file")
jpg_fill :: proc(b: ^Jpg_Bits) {
	for b.cnt <= 24 {
		v: u32
		if !b.marker && b.pos < len(b.data) {
			c := b.data[b.pos]
			if c == 0xFF {
				nx: u8 = b.pos + 1 < len(b.data) ? b.data[b.pos + 1] : 0xD9
				if nx == 0 {
					v = 0xFF
					b.pos += 2
				} else if nx == 0xFF {
					b.pos += 1 // fill byte
					continue
				} else {
					b.marker = true
				}
			} else {
				v = u32(c)
				b.pos += 1
			}
		}
		b.buf |= v << (24 - b.cnt)
		b.cnt += 8
	}
}

@(private = "file")
jpg_bits :: proc(b: ^Jpg_Bits, n: int) -> int {
	if n == 0 {
		return 0
	}
	jpg_fill(b)
	v := int(b.buf >> (32 - u32(n)))
	b.buf <<= u32(n)
	b.cnt -= u32(n)
	return v
}

@(private = "file")
jpg_extend :: proc(v, s: int) -> int {
	if s == 0 {
		return 0
	}
	return v < 1 << uint(s - 1) ? v - (1 << uint(s)) + 1 : v
}

@(private = "file")
jpg_huff :: proc(b: ^Jpg_Bits, t: ^Jpg_Huff) -> int {
	jpg_fill(b)
	if f := t.fast[b.buf >> (32 - JPG_FAST_BITS)]; f != 0 {
		l := u32(f >> 8)
		b.buf <<= l
		b.cnt -= l
		return int(f & 0xFF)
	}
	code: i32
	for l in 1 ..= 16 {
		code = code << 1 | i32(b.buf >> 31)
		b.buf <<= 1
		b.cnt -= 1
		if code <= t.maxcode[l] {
			return int(t.vals[t.valptr[l] + code - t.mincode[l]])
		}
	}
	return -1
}

// Re-syncs after a restart interval: skips to just past the RSTn marker.
@(private = "file")
jpg_restart :: proc(b: ^Jpg_Bits) {
	b.buf, b.cnt, b.marker = 0, 0, false
	for b.pos + 1 < len(b.data) {
		if b.data[b.pos] == 0xFF {
			m := b.data[b.pos + 1]
			if m >= 0xD0 && m <= 0xD7 {
				b.pos += 2
				return
			}
			if m != 0 && m != 0xFF {
				return // some other marker: leave it for the parser
			}
		}
		b.pos += 1
	}
}

@(private = "file")
jpg_scan :: proc(j: ^Jpg, data: []u8, start: int, seg: []u8) -> (next: int, ok: bool) {
	if len(seg) < 1 {
		return
	}
	ns := int(seg[0])
	if ns < 1 || ns > 4 || len(seg) < 1 + ns * 2 + 3 {
		return
	}
	sc: [4]^Jpg_Comp
	for i in 0 ..< ns {
		id, tb := seg[1 + i * 2], seg[2 + i * 2]
		for k in 0 ..< j.ncomp {
			if j.comps[k].id == id {
				sc[i] = &j.comps[k]
			}
		}
		if sc[i] == nil || tb >> 4 > 3 || tb & 15 > 3 {
			return
		}
		sc[i].dc_tbl = int(tb >> 4)
		sc[i].ac_tbl = int(tb & 15)
	}
	q := 1 + ns * 2
	ss, se := int(seg[q]), int(seg[q + 1])
	ah, al := int(seg[q + 2] >> 4), int(seg[q + 2] & 15)
	if !j.progressive {
		ss, se, ah, al = 0, 63, 0, 0
	}
	if se > 63 || ss > se || al > 13 || (j.progressive && ((ss == 0 && se != 0) || (ss > 0 && ns != 1))) {
		return
	}
	for i in 0 ..< ns {
		c := sc[i]
		if ss == 0 && ah == 0 && !j.dc[c.dc_tbl].ok {
			return
		}
		if se > 0 && !j.ac[c.ac_tbl].ok {
			return
		}
		c.pred = 0
	}
	j.eobrun = 0
	j.any_scan = true
	b := Jpg_Bits {
		data = data,
		pos  = start,
	}
	todo := j.restart
	if ns == 1 {
		c := sc[0]
		for by in 0 ..< c.cbh {
			for bx in 0 ..< c.cbw {
				blk := c.coefs[(by * c.bw + bx) * 64:][:64]
				if !jpg_block(j, &b, c, blk, ss, se, ah, al) {
					return
				}
				if j.restart > 0 {
					if todo -= 1; todo == 0 {
						todo = j.restart
						jpg_restart(&b)
						c.pred = 0
						j.eobrun = 0
					}
				}
			}
		}
	} else {
		for my in 0 ..< j.mcuy {
			for mx in 0 ..< j.mcux {
				for i in 0 ..< ns {
					c := sc[i]
					for v in 0 ..< c.v {
						for h in 0 ..< c.h {
							bx, by := mx * c.h + h, my * c.v + v
							blk := c.coefs[(by * c.bw + bx) * 64:][:64]
							if !jpg_block(j, &b, c, blk, ss, se, ah, al) {
								return
							}
						}
					}
				}
				if j.restart > 0 {
					if todo -= 1; todo == 0 {
						todo = j.restart
						jpg_restart(&b)
						for i in 0 ..< ns {
							sc[i].pred = 0
						}
						j.eobrun = 0
					}
				}
			}
		}
	}
	// continue parsing at the next marker
	p := b.pos
	for p + 1 < len(data) {
		if data[p] == 0xFF {
			m := data[p + 1]
			if m != 0 && m != 0xFF && !(m >= 0xD0 && m <= 0xD7) {
				return p, true
			}
		}
		p += 1
	}
	return len(data), true
}

@(private = "file")
jpg_block :: proc(j: ^Jpg, b: ^Jpg_Bits, c: ^Jpg_Comp, blk: []i16, ss, se, ah, al: int) -> bool {
	if !j.progressive {
		t := jpg_huff(b, &j.dc[c.dc_tbl])
		if t < 0 || t > 16 {
			return false
		}
		c.pred += jpg_extend(jpg_bits(b, t), t)
		blk[0] = i16(c.pred)
		ac := &j.ac[c.ac_tbl]
		for k := 1; k < 64; {
			rs := jpg_huff(b, ac)
			if rs < 0 {
				return false
			}
			r, s := rs >> 4, rs & 15
			if s == 0 {
				if r != 15 {
					break
				}
				k += 16
				continue
			}
			k += r
			if k > 63 {
				return false
			}
			blk[ZIGZAG[k]] = i16(jpg_extend(jpg_bits(b, s), s))
			k += 1
		}
		return true
	}

	// progressive: DC scans
	if ss == 0 {
		if ah == 0 {
			t := jpg_huff(b, &j.dc[c.dc_tbl])
			if t < 0 || t > 16 {
				return false
			}
			c.pred += jpg_extend(jpg_bits(b, t), t)
			blk[0] = i16(c.pred * (1 << uint(al)))
		} else if jpg_bits(b, 1) != 0 {
			blk[0] += i16(1 << uint(al))
		}
		return true
	}

	ac := &j.ac[c.ac_tbl]
	// AC first pass
	if ah == 0 {
		if j.eobrun > 0 {
			j.eobrun -= 1
			return true
		}
		for k := ss; k <= se; {
			rs := jpg_huff(b, ac)
			if rs < 0 {
				return false
			}
			r, s := rs >> 4, rs & 15
			if s == 0 {
				if r < 15 {
					j.eobrun = (1 << uint(r)) - 1
					if r > 0 {
						j.eobrun += jpg_bits(b, r)
					}
					break
				}
				k += 16
			} else {
				k += r
				if k > 63 {
					return false
				}
				blk[ZIGZAG[k]] = i16(jpg_extend(jpg_bits(b, s), s) * (1 << uint(al)))
				k += 1
			}
		}
		return true
	}

	// AC refinement pass
	bit := i16(1 << uint(al))
	refine :: proc(b: ^Jpg_Bits, p: ^i16, bit: i16) {
		if jpg_bits(b, 1) != 0 && p^ & bit == 0 {
			p^ += p^ > 0 ? bit : -bit
		}
	}
	if j.eobrun > 0 {
		j.eobrun -= 1
		for k in ss ..= se {
			if p := &blk[ZIGZAG[k]]; p^ != 0 {
				refine(b, p, bit)
			}
		}
		return true
	}
	for k := ss; k <= se; {
		rs := jpg_huff(b, ac)
		if rs < 0 {
			return false
		}
		r, s := rs >> 4, rs & 15
		val: i16
		if s == 0 {
			if r < 15 {
				j.eobrun = (1 << uint(r)) - 1
				if r > 0 {
					j.eobrun += jpg_bits(b, r)
				}
				r = 64 // refine the rest of this block, then stop
			}
		} else {
			if s != 1 {
				return false
			}
			val = jpg_bits(b, 1) != 0 ? bit : -bit
		}
		for k <= se {
			p := &blk[ZIGZAG[k]]
			k += 1
			if p^ != 0 {
				refine(b, p, bit)
			} else {
				if r == 0 {
					p^ = val
					break
				}
				r -= 1
			}
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Reconstruction
// ---------------------------------------------------------------------------

@(private = "file")
idct_tab: [8][8]f32 // [x][u] = C(u)/2 * cos((2x+1)u*pi/16)

@(init, private = "file")
jpg_init_idct :: proc "contextless" () {
	for x in 0 ..< 8 {
		for u in 0 ..< 8 {
			cu: f32 = u == 0 ? 1 / math.SQRT_TWO : 1
			idct_tab[x][u] = cu / 2 * math.cos(f32(2 * x + 1) * f32(u) * math.PI / 16)
		}
	}
}

@(private = "file")
jpg_idct :: proc(blk: []i16, q: ^[64]u16, out: []u8, stride: int) {
	coef, tmp: [64]f32
	for i in 0 ..< 64 {
		coef[i] = f32(blk[i]) * f32(q[i])
	}
	for v in 0 ..< 8 {
		row := coef[v * 8:][:8]
		if row[1] == 0 && row[2] == 0 && row[3] == 0 && row[4] == 0 && row[5] == 0 && row[6] == 0 && row[7] == 0 {
			dc := row[0] * idct_tab[0][0]
			for x in 0 ..< 8 do tmp[v * 8 + x] = dc
			continue
		}
		for x in 0 ..< 8 {
			s: f32
			for u in 0 ..< 8 do s += idct_tab[x][u] * row[u]
			tmp[v * 8 + x] = s
		}
	}
	for x in 0 ..< 8 {
		for y in 0 ..< 8 {
			s: f32
			for v in 0 ..< 8 do s += idct_tab[y][v] * tmp[v * 8 + x]
			out[y * stride + x] = jpeg_clamp_u8(s + 128)
		}
	}
}

@(private = "file")
jpg_output :: proc(j: ^Jpg) -> []Color {
	w, h := j.w, j.h
	planes: [4][]u8 // full-resolution w*h samples per component
	defer for p in planes do delete(p)
	for i in 0 ..< j.ncomp {
		c := &j.comps[i]
		pw := c.bw * 8
		raw := make([]u8, pw * c.bh * 8)
		defer delete(raw)
		for by in 0 ..< c.cbh {
			for bx in 0 ..< c.cbw {
				jpg_idct(c.coefs[(by * c.bw + bx) * 64:][:64], &j.qt[c.tq], raw[by * 8 * pw + bx * 8:], pw)
			}
		}
		planes[i] = make([]u8, w * h)
		if c.h == j.hmax && c.v == j.vmax {
			for y in 0 ..< h {
				copy(planes[i][y * w:][:w], raw[y * pw:][:w])
			}
			continue
		}
		// subsampled chroma: centred bilinear upsampling
		cw := (w * c.h + j.hmax - 1) / j.hmax
		ch := (h * c.v + j.vmax - 1) / j.vmax
		rx := f32(c.h) / f32(j.hmax)
		ry := f32(c.v) / f32(j.vmax)
		for y in 0 ..< h {
			fy := (f32(y) + 0.5) * ry - 0.5
			y0 := int(math.floor(fy))
			ty := fy - f32(y0)
			ya := raw[clamp(y0, 0, ch - 1) * pw:]
			yb := raw[clamp(y0 + 1, 0, ch - 1) * pw:]
			for x in 0 ..< w {
				fx := (f32(x) + 0.5) * rx - 0.5
				x0 := int(math.floor(fx))
				tx := fx - f32(x0)
				xa, xb := clamp(x0, 0, cw - 1), clamp(x0 + 1, 0, cw - 1)
				top := f32(ya[xa]) + (f32(ya[xb]) - f32(ya[xa])) * tx
				bot := f32(yb[xa]) + (f32(yb[xb]) - f32(yb[xa])) * tx
				planes[i][y * w + x] = jpeg_clamp_u8(top + (bot - top) * ty)
			}
		}
	}

	ycc :: proc(y, cb, cr: u8) -> (r, g, b: u8) {
		Y, Cb, Cr := f32(y), f32(cb) - 128, f32(cr) - 128
		return jpeg_clamp_u8(Y + 1.402 * Cr), jpeg_clamp_u8(Y - 0.344136 * Cb - 0.714136 * Cr), jpeg_clamp_u8(Y + 1.772 * Cb)
	}
	pix := make([]Color, w * h)
	switch j.ncomp {
	case 1:
		for v, i in planes[0] {
			pix[i] = Color{v, v, v, 255}
		}
	case 3:
		is_rgb := (j.adobe && j.adobe_transform == 0) || (j.comps[0].id == 'R' && j.comps[1].id == 'G' && j.comps[2].id == 'B')
		for i in 0 ..< w * h {
			a, b, c := planes[0][i], planes[1][i], planes[2][i]
			if is_rgb {
				pix[i] = Color{a, b, c, 255}
			} else {
				r, g, bb := ycc(a, b, c)
				pix[i] = Color{r, g, bb, 255}
			}
		}
	case 4:
		// Adobe CMYK/YCCK JPEGs store inverted ink values
		for i in 0 ..< w * h {
			c, m, y, k := planes[0][i], planes[1][i], planes[2][i], u32(planes[3][i])
			if j.adobe_transform == 2 {
				r, g, b := ycc(c, m, y)
				c, m, y = 255 - r, 255 - g, 255 - b
			}
			pix[i] = Color{u8(u32(c) * k / 255), u8(u32(m) * k / 255), u8(u32(y) * k / 255), 255}
		}
	}
	return pix
}

// Applies an EXIF orientation (1..8) so the image comes out upright. Frees `pix` when it
// has to build a new buffer.
image_orient :: proc(pix: []Color, w, h, orientation: int) -> ([]Color, int, int) {
	o := orientation
	if o < 2 || o > 8 {
		return pix, w, h
	}
	nw, nh := w, h
	if o >= 5 {
		nw, nh = h, w
	}
	out := make([]Color, w * h)
	for y in 0 ..< h {
		for x in 0 ..< w {
			dx, dy: int
			switch o {
			case 2:
				dx, dy = w - 1 - x, y
			case 3:
				dx, dy = w - 1 - x, h - 1 - y
			case 4:
				dx, dy = x, h - 1 - y
			case 5:
				dx, dy = y, x
			case 6:
				dx, dy = h - 1 - y, x
			case 7:
				dx, dy = h - 1 - y, w - 1 - x
			case:
				dx, dy = y, w - 1 - x
			}
			out[dy * nw + dx] = pix[y * w + x]
		}
	}
	delete(pix)
	return out, nw, nh
}

@(private = "file")
jpeg_clamp_u8 :: proc(v: f32) -> u8 {
	return u8(clamp(v, 0, 255) + 0.5)
}
