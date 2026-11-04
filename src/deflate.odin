package pangolin

import "core:bytes"
import czlib "core:compress/zlib"

// ---------------------------------------------------------------------------
// Raw DEFLATE (RFC 1951) for the project format's tile data: a small LZ77 matcher with the fixed
// Huffman code. Decoding uses core:compress/zlib, so streams written by any DEFLATE encoder load.
// ---------------------------------------------------------------------------

@(private = "file")
LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private = "file")
Bits :: struct {
	out:  [dynamic]u8,
	acc:  u64,
	n:    uint,
}

@(private = "file")
put_bits :: proc(b: ^Bits, v: u32, n: uint) {
	b.acc |= u64(v) << b.n
	b.n += n
	for b.n >= 8 {
		append(&b.out, u8(b.acc))
		b.acc >>= 8
		b.n -= 8
	}
}

// Huffman codes are sent most-significant bit first.
@(private = "file")
put_code :: proc(b: ^Bits, code: u32, n: uint) {
	r: u32
	c := code
	for _ in 0 ..< n {
		r = r << 1 | c & 1
		c >>= 1
	}
	put_bits(b, r, n)
}

@(private = "file")
put_lit :: proc(b: ^Bits, sym: int) {
	switch {
	case sym < 144:
		put_code(b, u32(0x30 + sym), 8)
	case sym < 256:
		put_code(b, u32(0x190 + sym - 144), 9)
	case sym < 280:
		put_code(b, u32(sym - 256), 7)
	case:
		put_code(b, u32(0xC0 + sym - 280), 8)
	}
}

HASH_BITS :: 13
MAX_CHAIN :: 24

// Compresses `src` into a raw DEFLATE stream (allocated with `allocator`).
deflate_raw :: proc(src: []u8, allocator := context.temp_allocator) -> (out: []u8, ok: bool) {
	b := Bits {
		out = make([dynamic]u8, 0, len(src) / 2 + 64, allocator),
	}
	put_bits(&b, 1, 1) // final block
	put_bits(&b, 1, 2) // fixed Huffman
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator)
	for &h in head do h = -1
	prev := make([]i32, len(src), context.temp_allocator)
	hash3 :: #force_inline proc(s: []u8, i: int) -> int {
		return int((u32(s[i]) << 16 | u32(s[i + 1]) << 8 | u32(s[i + 2])) * 2654435761 >> (32 - HASH_BITS))
	}
	insert :: proc(head, prev: []i32, src: []u8, i: int) {
		if i + 3 <= len(src) {
			h := hash3(src, i)
			prev[i] = head[h]
			head[h] = i32(i)
		}
	}
	i := 0
	for i < len(src) {
		best_len, best_dist := 0, 0
		if i + 3 <= len(src) {
			cand := head[hash3(src, i)]
			chain := 0
			max_len := min(258, len(src) - i)
			for cand >= 0 && chain < MAX_CHAIN && i - int(cand) <= 32768 {
				c := int(cand)
				l := 0
				for l < max_len && src[c + l] == src[i + l] do l += 1
				if l > best_len {
					best_len, best_dist = l, i - c
					if l == max_len do break
				}
				cand = prev[c]
				chain += 1
			}
		}
		if best_len >= 3 {
			lc := 28
			for k in 0 ..< 29 {
				if int(LEN_BASE[k]) > best_len {
					lc = k - 1
					break
				}
			}
			put_lit(&b, 257 + lc)
			put_bits(&b, u32(best_len - int(LEN_BASE[lc])), uint(LEN_EXTRA[lc]))
			dc := 29
			for k in 0 ..< 30 {
				if int(DIST_BASE[k]) > best_dist {
					dc = k - 1
					break
				}
			}
			put_code(&b, u32(dc), 5)
			put_bits(&b, u32(best_dist - int(DIST_BASE[dc])), uint(DIST_EXTRA[dc]))
			for k in 0 ..< best_len do insert(head, prev, src, i + k)
			i += best_len
		} else {
			put_lit(&b, int(src[i]))
			insert(head, prev, src, i)
			i += 1
		}
	}
	put_lit(&b, 256)
	if b.n > 0 do put_bits(&b, 0, 8 - b.n)
	return b.out[:], true
}

// Inflates a raw DEFLATE stream whose decoded size is known.
inflate_raw :: proc(src: []u8, out: []u8) -> bool {
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, len(out), context.temp_allocator)
	if err := czlib.inflate_from_byte_array_raw(src, &buf, true, len(out)); err != nil {
		return false
	}
	if len(buf.buf) != len(out) {
		return false
	}
	copy(out, buf.buf[:])
	return true
}
