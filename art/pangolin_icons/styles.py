"""The three styles, all from the one anatomy in anatomy.py, and all lit by its one light."""
import math, os, random, re, shutil, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
import pack
from anatomy import layers, shield, facet, ribs, ear_svg, is_limb, HEAD_SKIN, NEAR_PAW, FAR_PAW, GROUND

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
os.makedirs(OUT, exist_ok=True)
CHROME = r'C:/Program Files/Google/Chrome/Application/chrome.exe'
FIT, FX, FY = .9, 13, 6
TILE_TOP, TILE_BOTTOM = '#2b2e38', '#14151b'

def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))

def hexc(c):
    return '#%02x%02x%02x' % tuple(int(max(0, min(255, round(v)))) for v in c)

def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def ramp_at(ramp, t):
    t = max(0, min(.9999, t)) * (len(ramp) - 1)
    i = int(t)
    return lerp(ramp[i], ramp[i + 1], t - i)

def render(svg_text, name, size):
    """Draws an SVG at `size` pixels and returns the image, with its alpha: with Chrome where it is installed, and
    otherwise with ImageMagick (librsvg)."""
    p = os.path.join(OUT, name + '.svg')
    with open(p, 'w') as f:
        f.write(svg_text)
    png = os.path.join(OUT, '_r.png').replace(os.sep, '/')
    if os.path.exists(CHROME):
        html = os.path.join(OUT, '_r.html')
        with open(html, 'w') as f:
            f.write(f'<!doctype html><body style="margin:0;background:transparent"><img src="{name}.svg" width="{size}" height="{size}" style="display:block"></body>')
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1', '--default-background-color=00000000', f'--screenshot={png}', f'--window-size={size},{size}', 'file:///' + html.replace(os.sep, '/')], capture_output=True, timeout=90)
    else:
        # the drawings are 256 units wide, and an SVG unit is 1/96 inch
        subprocess.run(['magick', '-background', 'none', '-density', f'{96 * size / 256:g}', p, '-resize', f'{size}x{size}!', 'PNG32:' + png], check=True, capture_output=True, timeout=90)
    return Image.open(png).convert('RGBA').copy()

def tile(accent):
    return f'''<defs>
<linearGradient id="t" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="256"><stop offset="0" stop-color="{TILE_TOP}"/><stop offset="1" stop-color="{TILE_BOTTOM}"/></linearGradient>
<radialGradient id="g" gradientUnits="userSpaceOnUse" cx="128" cy="96" r="136"><stop offset="0" stop-color="{accent}" stop-opacity=".26"/><stop offset="1" stop-color="{accent}" stop-opacity="0"/></radialGradient>
<linearGradient id="rim" gradientUnits="userSpaceOnUse" x1="0" y1="6" x2="0" y2="120"><stop offset="0" stop-color="#ffffff" stop-opacity=".15"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>
<radialGradient id="gr"><stop offset="0" stop-color="#000000" stop-opacity=".6"/><stop offset=".6" stop-color="#000000" stop-opacity=".34"/><stop offset="1" stop-color="#000000" stop-opacity="0"/></radialGradient>
</defs>
<rect x="6" y="6" width="244" height="244" rx="54" fill="url(#t)"/>
<rect x="6" y="6" width="244" height="244" rx="54" fill="url(#g)"/>
<rect x="7" y="7" width="242" height="242" rx="53" fill="none" stroke="url(#rim)" stroke-width="2"/>
'''

def ground():
    """The shadow the animal stands on. It goes inside the drawing's own transform, under everything else."""
    cx, cy, rx, ry = GROUND
    return f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="url(#gr)"/>'

def svg(inner, backdrop=''):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">\n' + backdrop +
            f'<g transform="translate({FX} {FY}) scale({FIT})">\n' + '\n'.join(inner) + '\n</g>\n</svg>\n')

# Pangolin Scales: clean vector art --------------------------------------------------------------------------------

# shadows lean blue and lights lean green, so the turn of the form is carried by color as well as value
TEAL = [rgb(x) for x in ('#0d4a59', '#127a7e', '#2aa79c', '#62d3bf', '#a4f0dc')]
LINE = '#08262e'

def scales_art(detail=0, handles=True):
    o = [ground()]
    line_w = 1.7 if detail == 0 else 3.4
    for role, d in layers(detail):
        if role in ('scale', 'scale_far'):
            name, s, v, g, along, light = d
            far = role == 'scale_far'
            c = ramp_at(TEAL, light * .86)
            if far:
                c = lerp(c, rgb(LINE), .46)
            o.append(f'<path d="{shield(g)}" fill="{hexc(c)}" stroke="{LINE}" stroke-width="{line_w}" stroke-linejoin="round"/>')
            # the flat plane of the scale that turns to the light
            if not far and g[6] > 10:
                up = 1 if (g[4] * 0 + g[5]) < 0 else -1
                o.append(f'<path d="{facet(g, up)}" fill="{hexc(ramp_at(TEAL, light * .86 + .24))}"/>')
        elif role == 'under':
            o.append(f'<path d="{d}" fill="#0a3640"/>')
        elif role in ('skin', 'skin_far') and is_limb(d):
            # dark under the scales of a limb, so that no pale skin shows in the gaps between them
            o.append(f'<path d="{d}" fill="{'#0a3640' if role == 'skin' else '#072a33'}" stroke="{LINE}" stroke-width="{line_w}"/>')
        elif role == 'skin':
            # only the face is the palest thing in the drawing; the paws and feet are a step down from it
            o.append(f'<path d="{d}" fill="{'#dcefe9' if d is HEAD_SKIN else '#b3d2cd'}" stroke="{LINE}" stroke-width="{line_w}"/>')
            if d is HEAD_SKIN:
                # the shadow under the jaw
                o.append('<path d="M172 136 C192 138 214 140 232 146 C236 149 234 152 230 151 C214 147 200 148 184 148 C176 148 170 144 172 136 Z" fill="#a4c7c4"/>')
        elif role == 'skin_far':
            o.append(f'<path d="{d}" fill="#6c908e" stroke="{LINE}" stroke-width="{line_w}"/>')
        elif role == 'claw':
            o.append(f'<path d="{d}" fill="#e4f3ee" stroke="{LINE}" stroke-width="{line_w}"/>')
        elif role == 'claw_far':
            o.append(f'<path d="{d}" fill="#a3c0bc" stroke="{LINE}" stroke-width="{line_w}"/>')
        elif role == 'eye':
            x, y, r = d
            if detail:
                r *= 1.4  # at 64 and 48 the eye has to be a whole pixel
            o.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#061a20"/><circle cx="{x + 1.1}" cy="{y - 1.2}" r="1.1" fill="#ffffff"/>')
        elif role == 'ear' and detail == 0:
            x, y, r = d
            o.append(ear_svg(x, y, r, '#a9cbc6', '#8fb5b1', LINE, line_w * .5))
        elif role == 'nose':
            x, y, r = d
            o.append(f'<ellipse cx="{x}" cy="{y}" rx="{r}" ry="{r * .85}" fill="#061a20"/>')
        elif role == 'mouth' and detail == 0:
            o.append(f'<path d="{d}" fill="none" stroke="{LINE}" stroke-opacity=".6" stroke-width="1.2" stroke-linecap="round"/>')
    if handles:
        # one scale on the crown of the back, selected as a path, with its anchors and a bezier handle. Set clear of
        # the face, so that the eye still gets looked at first.
        body = [d for r, d in layers(detail) if r == 'scale' and d[0] == 'body']
        best = min(body, key=lambda d: abs(d[4] - .27) + abs(d[2] - .45) * .35)
        cx, cy, ax, ay, bx, by, L, W = best[3]
        def P(a, b):
            return (cx + ax * a + bx * b, cy + ay * a + by * b)
        # the selected scale is also lighter, which is all that is left of the selection at 64 and 48
        o.append(f'<path d="{shield(best[3])}" fill="#ffffff" fill-opacity=".24" stroke="#ffffff" stroke-opacity="{1 if detail == 0 else .6}" stroke-width="{2.6 if detail == 0 else 3.2}" stroke-linejoin="round"/>')
        if detail:
            return svg(o, tile('#5fd0c0'))
        tip = P(L, 0)
        h1, h2 = P(L, W * .62), P(L, -W * .62)
        o.append(f'<path d="M{h1[0]:.1f} {h1[1]:.1f} L{h2[0]:.1f} {h2[1]:.1f}" stroke="#ffffff" stroke-width="1.8" fill="none"/>')
        for q in (h1, h2):
            o.append(f'<circle cx="{q[0]:.1f}" cy="{q[1]:.1f}" r="3.6" fill="#ffffff" stroke="{LINE}" stroke-width="1.2"/>')
        for q in (tip, P(0, W / 2), P(0, -W / 2)):
            o.append(f'<rect x="{q[0] - 3.6:.1f}" y="{q[1] - 3.6:.1f}" width="7.2" height="7.2" fill="#ffffff" stroke="{LINE}" stroke-width="1.2"/>')
    return svg(o, tile('#5fd0c0'))

# Pixel art -----------------------------------------------------------------------------------------------------

# Each style's ramp, darkest to lightest, then what has no scales. A short ramp with a hue shift is what makes pixels
# read as forms instead of noise.
PIXEL_STYLES = {
    'pixels': dict(accent='#66a6ff', ramp=['#0c1f52', '#173c9c', '#2c6ad8', '#62a2ff', '#a9cfff', '#e7f2ff'], skin='#eef3ff', shade='#a4b4d8', far='#5a6c9c', claw='#ffffff', claw_far='#a4b4d8'),
    'scales': dict(accent='#5fd0c0', ramp=['#08303a', '#0e5c64', '#1f8f88', '#4fc4b4', '#8fe8d6', '#d6fff2'], skin='#eaf6f2', shade='#a0c4c0', far='#5a8482', claw='#ffffff', claw_far='#a0c4c0'),
    # Paints keeps the violet of its painted ground at the sizes that are pixel art
    'paints': dict(tile=('#3b2748', '#1a1226'), accent='#f6aa68', ramp=['#35143f', '#772a6e', '#c84a74', '#ee8052', '#fbb452', '#ffe39a'], skin='#fdeedb', shade='#cfae8e', far='#8c6e62', claw='#fff6e6', claw_far='#cfae8e'),
}
STEPPED = {32: [6, 3, 2, 1, 1, 1], 24: [4, 2, 1, 1], 16: [2, 1]}

def corner_steps(G):
    """How far each row of the tile's rounded corner is set in, from the top row down."""
    if G in STEPPED:
        return STEPPED[G]
    R = round(54 * G / 256) - 1
    out = []
    for r in range(R):
        inset = round(R - math.sqrt(R * R - (R - r - .5) ** 2))
        if inset <= 0:
            break
        out.append(inset)
    return out

def tile_margin(G):
    return max(1, G // 32)

def stepped_tile(accent, G, top=TILE_TOP, bottom=TILE_BOTTOM):
    c = 256 / G
    rects = []
    m = tile_margin(G)
    steps = corner_steps(G)
    for r, inset in enumerate(steps):
        for y in (m + r, G - 1 - m - r):
            rects.append(f'<rect x="{(m + inset) * c:g}" y="{y * c:g}" width="{(G - 2 * m - 2 * inset) * c:g}" height="{c:g}"')
    h = len(steps)
    rects.append(f'<rect x="{m * c:g}" y="{(m + h) * c:g}" width="{(G - 2 * m) * c:g}" height="{(G - 2 * m - 2 * h) * c:g}"')
    defs = f'''<defs>
<linearGradient id="t" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="256"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>
<radialGradient id="g" gradientUnits="userSpaceOnUse" cx="128" cy="96" r="136"><stop offset="0" stop-color="{accent}" stop-opacity=".26"/><stop offset="1" stop-color="{accent}" stop-opacity="0"/></radialGradient>
</defs>
'''
    return defs + '\n'.join(r + ' fill="url(#t)"/>' for r in rects) + '\n' + '\n'.join(r + ' fill="url(#g)"/>' for r in rects) + '\n'

def tile_span(G, y):
    """The first and last column of the tile on row y, or None outside it."""
    m, steps = tile_margin(G), corner_steps(G)
    r = min(y - m, G - 1 - m - y)
    if r < 0:
        return None
    inset = steps[r] if r < len(steps) else 0
    return m + inset, G - 1 - m - inset

def grid_svg(grid, st, G):
    accent = st['accent']
    c = 256 / G
    rects = []
    # the ground shadow, on the grid: the tile's own pixels, darkened
    cx, cy, rx, ry = GROUND[0] * FIT + FX, GROUND[1] * FIT + FY, GROUND[2] * FIT, max(GROUND[3] * FIT, c * .75)
    for gy in range(G):
        span = tile_span(G, gy)
        if not span:
            continue
        xs = [gx for gx in range(span[0], span[1] + 1) if ((gx + .5) * c - cx) ** 2 / rx ** 2 + ((gy + .5) * c - cy) ** 2 / ry ** 2 <= 1]
        if xs:
            rects.append(f'<rect x="{xs[0] * c:g}" y="{gy * c:g}" width="{(xs[-1] - xs[0] + 1) * c:g}" height="{c:g}" fill="#000000" fill-opacity=".4"/>')
    for gy in range(G):
        gx = 0
        while gx < G:
            col = grid.get((gx, gy))
            if not col:
                gx += 1
                continue
            e = gx
            while grid.get((e + 1, gy)) == col:
                e += 1
            rects.append(f'<rect x="{gx * c:g}" y="{gy * c:g}" width="{(e - gx + 1) * c:g}" height="{c:g}" fill="{col}"/>')
            gx = e + 1
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" shape-rendering="crispEdges">\n{stepped_tile(accent, G, *st.get('tile', (TILE_TOP, TILE_BOTTOM)))}' + '\n'.join(rects) + '\n</svg>\n'

# A scale on the grid, with every other row shifted by half: +1 is the edge that catches the light, -1 the shadow of
# the scale above. Big scales, big enough to count, instead of a texture.
SHINGLE = {32: ((0, 1, 1, 0), (0, 0, 0, 0), (-1, 0, 0, -1)), 24: ((0, 1, 1, 0), (0, 0, 0, 0), (-1, 0, 0, -1)),
           # at 64 a scale is big enough to have its own outline: two sides, a round lower edge and the light on its lip
           64: ((-1, 0, 0, 0, 0, 0, 0, 0), (-1, 0, 0, 0, 0, 0, 0, 0), (0, -1, 0, 0, 0, 0, 0, -1), (0, 0, -1, 1, 1, 1, -1, 0), (0, 0, 0, -1, -1, -1, 0, 0), (0, 0, 0, 0, -1, 0, 0, 0))}
# the small scales of the head and the limbs, where the big ones would not fit
SHINGLE_FINE = {64: ((0, 1, 1, 0), (0, 0, 0, 0), (-1, 0, 0, -1))}
DEPTH = {'far_leg': 1, 'near_leg': 2, 'body': 3, 'far_arm': 4, 'far_claw': 5, 'head_skin': 6, 'head': 7, 'near_arm': 8, 'near_claw': 9}

def id_color(i):
    return (20 + 22 * (i % 11), 20 + 36 * ((i // 2) % 6), 240 - 20 * (i % 9))

def pixel_art(style, G):
    """Drawn on the grid: the base says which part of the animal each pixel belongs to and how much light it gets. The
    light picks a step of a short ramp, so that the body turns in big shapes; the scales go on top; and wherever one
    part lies over another, the one behind gets the darkest color along that edge."""
    st = PIXEL_STYLES[style]
    names = list(DEPTH)
    ids = {n: id_color(i) for i, n in enumerate(names)}
    lights, parts = [], []
    stage = 0
    for role, d in layers(0):
        if role in ('scale', 'scale_far'):
            name, s, v, g, along, light = d
            lights.append(f'<path d="{shield(g)}" fill="{hexc((light * 255,) * 3)}"/>')
            parts.append(f'<path d="{shield(g)}" fill="{hexc(ids[name])}"/>')
        elif role in ('under', 'skin', 'skin_far', 'claw', 'claw_far'):
            if d is HEAD_SKIN:
                key, stage = 'head_skin', 1
            elif role == 'under':
                key = 'body'
            elif role == 'skin':
                key = 'near_arm' if stage else 'near_leg'
            elif role == 'skin_far':
                key = 'far_arm' if d is FAR_PAW or stage == 0 and d.startswith('M2') else 'far_leg'
            else:
                key = 'near_claw' if role == 'claw' else 'far_claw'
            lights.append(f'<path d="{d}" fill="{hexc((110,) * 3)}"/>')
            parts.append(f'<path d="{d}" fill="{hexc(ids[key])}"/>')
    k = 16
    lit = np.asarray(render(svg(lights), f'_lit_{style}_{G}', G * k), dtype=np.float32)
    where = np.asarray(render(svg(parts), f'_where_{style}_{G}', G * k), dtype=np.float32)
    id_vals = np.array([ids[n] for n in names], dtype=np.float32)
    part_of, light_of_cell = {}, {}
    for gy in range(G):
        for gx in range(G):
            cell = where[gy * k:(gy + 1) * k, gx * k:(gx + 1) * k]
            alpha = cell[..., 3] / 255
            if alpha.mean() < .42:
                continue
            solid = cell[alpha > .5][:, :3]
            nearest = np.argmin(((solid[:, None, :] - id_vals[None, :, :]) ** 2).sum(axis=2), axis=1)
            counts = np.bincount(nearest, minlength=len(names))
            pick = int(counts.argmax())
            for thin in ('near_claw', 'far_claw'):
                t = names.index(thin)
                if counts[t] > .3 * counts.sum():
                    pick = t
            part_of[gx, gy] = names[pick]
            cl = lit[gy * k:(gy + 1) * k, gx * k:(gx + 1) * k]
            light_of_cell[gx, gy] = float(np.median(cl[alpha > .5][:, 0])) / 255
    # a lone pixel at the edge of the shape is a jaggy, not a feature
    for (gx, gy) in list(part_of):
        n = sum(((gx + a, gy + b) in part_of) for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        if n <= 1 and part_of[gx, gy] not in ('near_claw', 'far_claw'):
            del part_of[gx, gy]
    ramp = st['ramp']
    SCALY = ('near_leg', 'body', 'head', 'near_arm', 'far_leg', 'far_arm')
    pat = SHINGLE[G]
    grid = {}
    for (gx, gy), part in part_of.items():
        here = DEPTH[part]
        behind = False
        for nb in ((gx + 1, gy), (gx - 1, gy), (gx, gy - 1), (gx, gy + 1)):
            other = part_of.get(nb)
            if other and DEPTH[other] > here and not (part in ('head', 'head_skin') and other in ('head', 'head_skin')):
                behind = True
        if part in SCALY:
            t = light_of_cell[gx, gy]
            step = 2 + int(min(.999, t) * 2.6)  # the shape of the light: 2 to 4 of the ramp, so shadow still reads on a dark tile
            if part in ('far_leg', 'far_arm'):
                step = max(1, step - 1)  # dim, but still clear of the dark tile
            p = pat
            if G in SHINGLE_FINE and part != 'body':
                p = SHINGLE_FINE[G]
                if part == 'head':
                    step -= 2  # so the cap of scales stands apart from the pale face under it
            h, w = len(p), len(p[0])
            row = gy // h
            f = p[gy % h][(gx + (w // 2 if row % 2 else 0)) % w]
            step = max(0, min(len(ramp) - 1, step + f))
            col = ramp[step]
        elif part == 'near_claw':
            col = st['claw'] if gx % 2 else st['claw_far']
        elif part == 'far_claw':
            col = st['claw_far'] if gx % 2 else st['far']
        elif part == 'head_skin':
            col = st['skin']
        else:
            col = st['far'] if part in ('far_leg', 'far_arm') else st['shade']
        if behind:
            # on a small face a dark pixel is an eye, so there the edge is only the skin's shadow
            # and at 32 and under a black line across the body is a crack, so the edge is just a darker step
            col = st['shade'] if part == 'head_skin' and G <= 24 else ramp[0 if G > 32 else 1]
        grid[gx, gy] = col
    # the jaw's shadow, the eye and the nose
    def cell_of(x, y):
        return int((x * FIT + FX) * G / 256), int((y * FIT + FY) * G / 256)
    for (gx, gy), part in part_of.items():
        if part == 'head_skin' and part_of.get((gx, gy + 1)) != 'head_skin':
            grid[gx, gy] = st['shade']
    big = G >= 48  # room for an eye of four pixels with a glint, and a nose of two
    for role, d in layers(0):
        if role == 'eye':
            ex, ey = cell_of(d[0], d[1])
            grid[ex, ey] = '#0c0d10'
            if big:
                grid[ex - 1, ey] = grid[ex - 1, ey - 1] = grid[ex, ey - 1] = '#0c0d10'
        if role == 'nose':
            c = cell_of(d[0], d[1])
            if c in grid:
                grid[c] = '#0c0d10'
            if big and (c[0] - 1, c[1]) in grid:
                grid[c[0] - 1, c[1]] = '#0c0d10'
    return grid_svg(grid, st, G)

# At 16 pixels nothing automatic works: this one is drawn by hand, and each app swaps in its colors.
# . empty, 0-5 the ramp, S skin, s its shadow, C claw, c dim claw, E the eye and nose
SPRITE_16 = [
    '................',
    '................',
    '................',
    '.....4444.......',
    '...4454454......',
    '..444444443.....',
    '..34334334SS....',
    '..3333333SESS...',
    '..232232233ssE..',
    '..22222222......',
    '..222.22.3......',
    '..22..22.3......',
    '..12..22........',
    '...122SS........',
    '................',
    '................',
]

def hand_drawn(style, rows):
    st = PIXEL_STYLES[style]
    m = {'S': st['skin'], 's': st['shade'], 'f': st['far'], 'C': st['claw'], 'c': st['claw_far'], 'E': '#0c0d10'}
    grid = {}
    for y, line in enumerate(rows):
        for x, ch in enumerate(line):
            if ch == '.':
                continue
            grid[x, y] = st['ramp'][int(ch)] if ch.isdigit() else m[ch]
    return grid_svg(grid, st, len(rows))

def pixel_16(style):
    return hand_drawn(style, SPRITE_16)

# Pangolin Paints: painted stroke by stroke --------------------------------------------------------------------------

def bristles(draw, height, pts, width, color, rng, jitter=9, taper=.28):
    """One loaded stroke: many bristle lines side by side, each its own shade, each lifting off at its own moment,
    and the middle of the stroke lying thicker than its edges."""
    if len(pts) < 2:
        return
    across = []
    for i in range(len(pts)):
        a, b = pts[max(i - 1, 0)], pts[min(i + 1, len(pts) - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        d = math.hypot(dx, dy) or 1
        across.append((-dy / d, dx / d))
    n = max(3, int(width / 2.6))
    lw = max(2, int(round(width / n * 1.6)))
    for b in range(n):
        off = (b + .5) / n * 2 - 1
        shade = rng.gauss(0, jitter)
        warm = rng.gauss(0, jitter * .5)
        c = (color[0] + shade + warm, color[1] + shade, color[2] + shade - warm)
        c = tuple(int(max(0, min(255, v))) for v in c)
        end = len(pts) - rng.randint(0, max(1, len(pts) // 3))
        begin = rng.randint(0, 1)
        line = []
        for i in range(begin, max(end, begin + 2)):
            t = i / max(len(pts) - 1, 1)
            w = width / 2 * (1 - taper * t * t)
            line.append((pts[i][0] + across[i][0] * off * w, pts[i][1] + across[i][1] * off * w))
        draw.line(line, fill=c + (255,), width=lw, joint='curve')
        h = int(max(0, min(255, 140 + 80 * (1 - off * off) + rng.gauss(0, 30))))
        height.line(line, fill=h, width=lw, joint='curve')

def curve(p0, p1, p2, n=9):
    return [((1 - t) ** 2 * p0[0] + 2 * t * (1 - t) * p1[0] + t * t * p2[0], (1 - t) ** 2 * p0[1] + 2 * t * (1 - t) * p1[1] + t * t * p2[1]) for t in (i / (n - 1) for i in range(n))]

def flatten_path(path, steps=12):
    toks = re.findall(r'[MCLZ]|-?[0-9.]+', path)
    pts, i, cmd, cur = [], 0, None, (0, 0)
    while i < len(toks):
        if toks[i] in 'MCLZ':
            cmd = toks[i]
            i += 1
            if cmd == 'Z':
                continue
        if cmd in 'ML':
            cur = (float(toks[i]), float(toks[i + 1]))
            pts.append(cur)
            i += 2
        else:
            c1 = (float(toks[i]), float(toks[i + 1]))
            c2 = (float(toks[i + 2]), float(toks[i + 3]))
            e = (float(toks[i + 4]), float(toks[i + 5]))
            for q in range(1, steps + 1):
                t = q / steps
                m = 1 - t
                pts.append(tuple(m ** 3 * cur[c] + 3 * m * m * t * c1[c] + 3 * m * t * t * c2[c] + t ** 3 * e[c] for c in (0, 1)))
            cur = e
            i += 6
    return pts

def inside(pts, x, y):
    w = False
    for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
        if (ay <= y) != (by <= y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
            w = not w
    return w

# light turns gold, shadow turns violet: the form is carried by color, the way a painter thinks of it
PAINT = [rgb(x) for x in ('#46206e', '#8a2f78', '#d0507a', '#f0844e', '#fbbe58', '#ffe6a4')]
PLUM = rgb('#26122a')

def paint_color(name, along, light):
    c = ramp_at(PAINT, light * .78 + .17)
    if name == 'body' and along > .55:
        # the tail falls away from the light, into a cool violet blue
        c = lerp(c, rgb('#4d62d8'), min(1, (along - .55) / .45) * .55)
    return c

def painting(size=1024, seed=11, detail=0):
    rng = random.Random(seed)
    S = size / 256
    B = size / 1024  # brush sizes are set for a canvas of 1024
    def X(p):
        return ((p[0] * FIT + FX) * S, (p[1] * FIT + FY) * S)
    canvas = Image.new('RGBA', (size, size), (34, 24, 44, 255))
    height = Image.new('L', (size, size), 110)
    draw = ImageDraw.Draw(canvas, 'RGBA')
    hd = ImageDraw.Draw(height)

    # the ground: broad and quiet, dark and cool, and warmer only behind the dome, so the animal stands clear of it
    def ground(x, y):
        d = math.hypot((x - size * .50) / size, (y - size * .32) / size)
        t = max(0, min(1, 1 - d * 1.5))
        return lerp(rgb('#17142a'), rgb('#6e3a62'), t ** 1.6)
    for w, count in ((190, 70), (120, 110)):
        for _ in range(count):
            w2 = w * B
            x, y = rng.uniform(-60, size + 60), rng.uniform(-60, size + 60)
            ang = -0.65 + rng.gauss(0, .3)
            ln = rng.uniform(1.6, 3.2) * w2
            ex, ey = x + math.cos(ang) * ln, y + math.sin(ang) * ln
            mx, my = (x + ex) / 2 + rng.gauss(0, w2 * .35), (y + ey) / 2 + rng.gauss(0, w2 * .35)
            c = ground((x + ex) / 2, (y + ey) / 2)
            dv = rng.gauss(0, 4.5)
            bristles(draw, hd, curve((x, y), (mx, my), (ex, ey), 12), w2, tuple(c[k] + dv for k in range(3)), rng, 3.5)

    def fill(path_pts, color, rough=2.2):
        pts = [X(p) for p in path_pts]
        pts = [(p[0] + rng.gauss(0, rough * B), p[1] + rng.gauss(0, rough * B)) for p in pts]
        draw.polygon(pts, fill=tuple(int(v) for v in color) + (255,))
        hd.polygon(pts, fill=95)

    def paint_scale(g, color, far, light=1):
        cx, cy, ax, ay, bx, by, L, W = g
        def P(a, b):
            return X((cx + ax * a + bx * b, cy + ay * a + by * b))
        shadow = lerp(color, rgb('#2a1030'), .72 if not far else .86)
        fill([((cx + ax * a + bx * b), (cy + ay * a + by * b)) for a, b in ((0, -W * .5), (L * .45, -W * .58), (L * .85, -W * .40), (L * 1.02, 0), (L * .85, W * .40), (L * .45, W * .58), (0, W * .5))], shadow)
        base = color if not far else lerp(color, PLUM, .5)
        count = 3 if W * S * FIT < 74 else 4
        width = W * S * FIT / count * 1.46
        # which side of the scale faces up, towards the light
        up = 1 if by < 0 else -1
        for i in range(count):
            q = ((i + .5) / count * 2 - 1) * .82
            hue = (rng.gauss(0, 11), rng.gauss(0, 8), rng.gauss(0, 10))
            lift = .5 + .5 * q * up  # 1 on the side towards the light
            c = lerp(lerp(base, rgb('#2a1030'), .30), lerp(base, rgb('#fff1d6'), .14), lift)
            c = tuple(c[k] + hue[k] for k in range(3))
            end = .93 - .32 * q * q
            bristles(draw, hd, curve(P(L * .06, W * .40 * q), P(L * .52, W * .50 * q), P(L * end, W * .24 * q), 7), width, c, rng, 7)
        if not far and rng.random() < .35 + .6 * light:
            hi = lerp(base, rgb('#fff4dc'), rng.uniform(.28, .5) * (.25 + .75 * light))
            side = up * rng.uniform(.12, .34)
            reach = rng.uniform(.12, .24)
            a0, a1 = P(L * rng.uniform(.5, .66), W * (side - reach)), P(L * rng.uniform(.82, .94), W * side * .8)
            a2 = P(L * rng.uniform(.6, .74), W * (side + reach))
            bristles(draw, hd, curve(a0, a1, a2, 6), max(4 * B, W * S * FIT * rng.uniform(.08, .13)), hi, rng, 5)

    def paint_along(path, color, dark, axis, count=9, widthk=1.5):
        """A shape with no scales: strokes that run along its length, light on top and shadow below."""
        pts = flatten_path(path) if isinstance(path, str) else list(path)
        fill(pts, lerp(color, dark, .55), 1.0)
        n = math.hypot(*axis)
        ux, uy = axis[0] / n, axis[1] / n
        vx, vy = -uy, ux
        if vy < 0:
            vx, vy = -vx, -vy
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        os_ = [(p[0] - cx) * vx + (p[1] - cy) * vy for p in pts]
        lo, hi = min(os_), max(os_)
        reach = max(abs((p[0] - cx) * ux + (p[1] - cy) * uy) for p in pts) * 1.1
        for i in range(count):
            f = (i + .5) / count
            o = lo + (hi - lo) * f
            # the part of this line that lies inside the shape
            inner = []
            for k in range(-40, 41):
                a = reach * k / 40
                x, y = cx + ux * a + vx * o, cy + uy * a + vy * o
                if inside(pts, x, y):
                    inner.append((x, y))
            if len(inner) < 2:
                continue
            a, b = inner[0], inner[-1]
            m = ((a[0] + b[0]) / 2 + rng.gauss(0, .5), (a[1] + b[1]) / 2 + rng.gauss(0, .5))
            c = lerp(lerp(color, rgb('#ffffff'), .18), lerp(color, dark, .8), f ** 1.1)
            dv = rng.gauss(0, 3)
            c = tuple(c[k] + dv for k in range(3))
            w = (hi - lo) / count * S * FIT * widthk
            bristles(draw, hd, curve(X(a), X(m), X(b), 8), w, c, rng, 3, .1)

    SKIN, SIENNA = rgb('#f6dcbc'), rgb('#9a5e4a')
    # the ground under the animal: a few long dark strokes, laid before it is painted
    gx, gy, grx, gry = GROUND
    for i in range(7):
        f = (i + .5) / 7
        half = grx * (1 - .5 * abs(f * 2 - 1))
        y = gy + gry * (f * 2 - 1) * .9
        a, b = X((gx - half + rng.gauss(0, 4), y)), X((gx + half + rng.gauss(0, 4), y + rng.gauss(0, 1)))
        bristles(draw, hd, curve(a, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + rng.gauss(0, 3 * B)), b, 12), gry * S * .62, lerp(rgb('#120b1c'), rgb('#2a1838'), abs(f * 2 - 1)), rng, 3, .5)
    stage = 0
    for role, d in layers(detail):
        if role in ('scale', 'scale_far'):
            name, s, v, g, along, light = d
            paint_scale(g, paint_color(name, along, light), role == 'scale_far', light)
        elif role == 'under':
            fill(flatten_path(d), rgb('#2a1030'))
        elif role == 'skin':
            if d is HEAD_SKIN:
                stage = 1
                paint_along(d, SKIN, SIENNA, (72, 54), 11)
            else:
                paint_along(d, lerp(SKIN, SIENNA, .35) if stage else lerp(lerp(SKIN, SIENNA, .7), PLUM, .3), SIENNA if stage else PLUM, (1, 1) if stage else (1, 0), 6)
        elif role == 'skin_far':
            paint_along(d, lerp(SKIN, PLUM, .62), PLUM, (1, 1), 5)
        elif role in ('claw', 'claw_far'):
            pts = flatten_path(d)
            base = rgb('#fff1da') if role == 'claw' else rgb('#c8a988')
            fill(pts, lerp(base, rgb('#2a1030'), .78), 1.0)
            n = len(pts)
            root = ((pts[0][0] + pts[-1][0]) / 2, (pts[0][1] + pts[-1][1]) / 2)
            tip = pts[n // 2]
            mid = pts[n // 4]
            mid2 = pts[n * 3 // 4]
            w = math.hypot(pts[0][0] - pts[-1][0], pts[0][1] - pts[-1][1]) * S * FIT * .72
            M = ((mid[0] + mid2[0]) / 2, (mid[1] + mid2[1]) / 2)
            bristles(draw, hd, curve(X(root), X(M), X(tip), 10), w, lerp(base, rgb('#c07a5a'), .25), rng, 4, .98)
            bristles(draw, hd, curve(X(root), X((M[0] + (mid[0] - M[0]) * .4, M[1])), X(tip), 10), w * .45, base, rng, 3, .96)
        elif role == 'ear':
            # two dabs lying back along the head, close to the skin in value
            x, y, r = d
            ca, sa = math.cos(math.radians(-32)), math.sin(math.radians(-32))
            for k, c, w in ((1, lerp(SKIN, SIENNA, .55), .9), (.45, lerp(SKIN, SIENNA, .95), .55)):
                a, b = X((x - ca * r * k, y - sa * r * k)), X((x + ca * r * k, y + sa * r * k))
                bristles(draw, hd, curve(a, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - r * S * .3), b, 6), r * S * FIT * 1.4 * w, c, rng, 3, .5)
        elif role == 'mouth':
            pts = [X(p) for p in flatten_path(d)]
            draw.line(pts, fill=tuple(int(v) for v in lerp(SIENNA, PLUM, .45)) + (255,), width=max(1, round(1.3 * S)), joint='curve')
        elif role == 'nose':
            x, y, r = d
            A = X((x, y))
            rr = r * S * FIT
            draw.ellipse((A[0] - rr, A[1] - rr * .85, A[0] + rr, A[1] + rr * .85), fill=(24, 12, 20, 255))
            hd.ellipse((A[0] - rr, A[1] - rr * .85, A[0] + rr, A[1] + rr * .85), fill=210)
            draw.ellipse((A[0] - rr * .5, A[1] - rr * .6, A[0], A[1] - rr * .15), fill=(120, 95, 110, 255))

    # thick paint catches the light, softly
    h = np.asarray(height.filter(ImageFilter.GaussianBlur(1.2 * B)), dtype=np.float32)
    hy, hx = np.gradient(h)
    relief = np.clip(1 + (-hx - hy) * .0075 / max(B, .25), .86, 1.16)
    px = np.asarray(canvas.convert('RGB'), dtype=np.float32) * relief[..., None]
    im = Image.fromarray(np.clip(px, 0, 255).astype(np.uint8), 'RGB').convert('RGBA')
    # the eye goes on last, wet and bright
    dr = ImageDraw.Draw(im)
    for role, v in layers(detail):
        if role == 'eye':
            A = X((v[0], v[1]))
            r = v[2] * S * FIT
            dr.ellipse((A[0] - r * 1.25, A[1] - r * 1.25, A[0] + r * 1.25, A[1] + r * 1.25), fill=tuple(int(q) for q in lerp(SKIN, SIENNA, .9)) + (255,))
            dr.ellipse((A[0] - r, A[1] - r, A[0] + r, A[1] + r), fill=(14, 10, 16, 255))
            hr = r * .36
            dr.ellipse((A[0] + r * .24 - hr, A[1] - r * .38 - hr, A[0] + r * .24 + hr, A[1] - r * .38 + hr), fill=(255, 250, 240, 255))
    mask = Image.new('L', (size * 2, size * 2), 0)
    m = 6 * S * 2
    ImageDraw.Draw(mask).rounded_rectangle((m, m, size * 2 - m, size * 2 - m), radius=54 * S * 2, fill=255)
    im.putalpha(mask.resize((size, size), Image.LANCZOS))
    return im

# Export --------------------------------------------------------------------------------------------------------

SIZES = (256, 128, 64, 48, 32, 24, 16)

def main():
    made = {}
    # large sizes: full detail. 64 and 48: fewer, bigger scales. 32 and under: pixel art, 16 by hand
    for sz in (256, 128):
        made['scales', sz] = render(scales_art(0), 'scales', sz)
    small_scales = scales_art(1)
    for sz in (64, 48):
        made['scales', sz] = render(small_scales, 'scales_small', sz)
    # Pixels is pixel art at every size: a 64 pixel drawing for the large ones, then 32, 24 and 16
    g64, g32, g24, g16 = pixel_art('pixels', 64), pixel_art('pixels', 32), pixel_art('pixels', 24), pixel_16('pixels')
    for sz, g, nm in ((256, g64, 'g64'), (128, g64, 'g64'), (64, g32, 'g32'), (48, g24, 'g24'), (32, g32, 'g32'), (24, g24, 'g24'), (16, g16, 'g16')):
        made['pixels', sz] = render(g, f'pixels_{nm}', sz)
    art = painting(1024)
    art.save(os.path.join(OUT, 'paints_1024.png'))
    for sz in (256, 128):
        made['paints', sz] = art.resize((sz, sz), Image.LANCZOS)
    small_art = painting(512, seed=5, detail=1)
    small_art.save(os.path.join(OUT, 'paints_small_512.png'))
    for sz in (64, 48):
        made['paints', sz] = small_art.resize((sz, sz), Image.LANCZOS)
    for name in ('scales', 'paints'):
        made[name, 32] = render(pixel_art(name, 32), f'{name}_g32', 32)
        made[name, 24] = render(pixel_art(name, 24), f'{name}_g24', 24)
        made[name, 16] = render(pixel_16(name), f'{name}_g16', 16)
    for (name, sz), im in made.items():
        im.save(os.path.join(OUT, f'{name}_{sz}.png'))
    # each app's assets/icon folder, ready to copy over it. The master is the largest drawing, in its own form.
    masters = {'scales': ('scales.svg', 'master.svg'), 'pixels': ('pixels_g64.svg', 'master.svg'), 'paints': ('paints_1024.png', 'master_1024.png')}
    for name in ('scales', 'paints', 'pixels'):
        folder = os.path.join(OUT, name)
        os.makedirs(folder, exist_ok=True)
        pngs = []
        for sz in SIZES:
            p = os.path.join(folder, f'icon_{sz}.png')
            made[name, sz].save(p, optimize=True)
            with open(p, 'rb') as f:
                pngs.append(f.read())
        icon = pack.ico(pngs)
        with open(os.path.join(folder, 'app.ico'), 'wb') as f:
            f.write(icon)
        with open(os.path.join(folder, 'app.res'), 'wb') as f:
            f.write(pack.res(icon))
        with open(os.path.join(folder, 'app.rc'), 'w', newline='\n') as f:
            f.write('// The icon of the Windows executable.\n1 ICON "app.ico"\n')
        shutil.copyfile(os.path.join(OUT, masters[name][0]), os.path.join(folder, masters[name][1]))
    proof(made)

def proof(made):
    W, H = 1060, 3 * 300 + 10
    sheet = Image.new('RGBA', (W, H), (58, 61, 70, 255))
    sheet.paste((238, 238, 240, 255), (780, 0, W, H))
    for r, name in enumerate(('paints', 'pixels', 'scales')):
        y = 10 + r * 300
        sheet.alpha_composite(made[name, 256], (10, y))
        x = 280
        for sz in (64, 48, 32, 24, 16):
            sheet.alpha_composite(made[name, sz], (x, y))
            x += sz + 10
        x = 280
        for sz, k in ((32, 6), (24, 6), (16, 8)):
            sheet.alpha_composite(made[name, sz].resize((sz * k, sz * k), Image.NEAREST), (x, y + 76))
            x += sz * k + 12
        x = 795
        for sz in (64, 48, 32, 24, 16):
            sheet.alpha_composite(made[name, sz], (x, y))
            x += sz + 8
        sheet.alpha_composite(made[name, 128], (820, y + 90))
    sheet.save(os.path.join(OUT, 'proof.png'))
    print('proof saved')

if __name__ == '__main__':
    main()
