"""The base image's anatomy, on a 256 x 256 tile. It is built on one line of action: from the tail, up over the dome of
the back and down the head to the nose, as a single curve. The limbs are slim and leave air under the body. Everything
is a list of shapes with a role, so that each style can dress the same drawing its own way."""
import math

def catmull(pts, per=30):
    out = []
    n = len(pts)
    for i in range(n - 1):
        p0, p1, p2, p3 = pts[max(i - 1, 0)], pts[i], pts[i + 1], pts[min(i + 2, n - 1)]
        for k in range(per):
            t = k / per
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[c]) + (-p0[c] + p2[c]) * t + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2 + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3) for c in range(3)))
    out.append(pts[-1])
    return out

class Part:
    """A limb of the drawing: a spine with a half width at each point. Going along it, `back` is to the left, y down."""
    def __init__(self, spine):
        self.samples = catmull(spine)
        self.arc = [0.0]
        for a, b in zip(self.samples, self.samples[1:]):
            self.arc.append(self.arc[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
        self.len = self.arc[-1]

    def at(self, s):
        s = max(0, min(self.len - 1e-3, s))
        lo, hi = 0, len(self.arc) - 1
        while hi - lo > 1:
            m = (lo + hi) // 2
            if self.arc[m] <= s:
                lo = m
            else:
                hi = m
        f = (s - self.arc[lo]) / max(self.arc[hi] - self.arc[lo], 1e-6)
        a, b = self.samples[lo], self.samples[hi]
        x, y, w = (a[c] + (b[c] - a[c]) * f for c in range(3))
        dx, dy = b[0] - a[0], b[1] - a[1]
        d = math.hypot(dx, dy) or 1
        tx, ty = dx / d, dy / d
        return x, y, tx, ty, -ty, tx, w

    def point(self, s, v):
        x, y, tx, ty, nx, ny, w = self.at(s)
        return x + nx * w * v, y + ny * w * v

    def outline(self, top=1.0, under=1.0):
        a, b = [], []
        for i in range(0, 121):
            s = self.len * i / 120
            x, y, tx, ty, nx, ny, w = self.at(s)
            a.append((x + nx * w * top, y + ny * w * top))
            b.append((x - nx * w * under, y - ny * w * under))
        return a + b[::-1]

    def scales(self, L, W, step, under=0.6, ref=34, fmin=.5, start=4, end=2):
        """(s, v, geometry), far end first, so that those nearer the start lie on top, like roof tiles. Each lies along
        the flow of the part where it is. The top row sits so its edge is on the outline: the real animal has a smooth
        back, and scales that poke out of it make a hedgehog."""
        rows, s, r = [], start, 0
        while s < self.len - end:
            rows.append((s, r))
            s += step * max(fmin + .1, min(1, self.at(s)[6] / ref))
            r += 1
        out = []
        for s, r in reversed(rows):
            x, y, tx, ty, nx, ny, w = self.at(s)
            f = max(fmin, min(1, w / ref))
            wid = W * f
            top = max(.15, 1 - wid * .44 / max(w, 1))
            span = w * (top + under)
            n = round(span / (wid * 0.82))
            if n < 2:
                wid = max(2 * w * .98, 4)
                out.append((s, 0.0, (x, y, tx, ty, nx, ny, max(L * f, wid * 1.2), wid)))
                continue
            ds = step * max(fmin + .1, min(1, w / ref))
            qs = [min((k + (0.5 if r % 2 else 0.0)) / (n - 0.5), 1) for k in range(n)]
            if r % 2:
                qs.insert(0, 0.0)
            for q in qs:
                v = top - q * (top + under)
                cx, cy = self.point(s, v)
                ex, ey = self.point(s + ds, v)
                ax, ay = ex - cx, ey - cy
                d = math.hypot(ax, ay) or 1
                st = max(1, min(d / ds, 1.3))
                ax, ay = ax / d, ay / d
                out.append((s, v, (cx, cy, ax, ay, -ay, ax, L * f * st, wid * (0.9 + 0.1 * st))))
        return out

def shield(g):
    """The path of a scale: a wide shield whose rounded point lies away from its base."""
    cx, cy, ax, ay, bx, by, L, W = g
    def P(a, b):
        return f'{cx + ax * a + bx * b:.1f} {cy + ay * a + by * b:.1f}'
    return (f'M{P(0, -W / 2)} C{P(L * .42, -W * .60)} {P(L * .84, -W * .42)} {P(L, 0)} '
            f'C{P(L * .84, W * .42)} {P(L * .42, W * .60)} {P(0, W / 2)} Z')

def facet(g, side=1):
    """The side of a scale that faces the light, as a flat shape."""
    cx, cy, ax, ay, bx, by, L, W = g
    s = side
    def P(a, b):
        return f'{cx + ax * a + bx * b * s:.1f} {cy + ay * a + by * b * s:.1f}'
    return (f'M{P(L * .10, W * .46)} C{P(L * .46, W * .55)} {P(L * .84, W * .38)} {P(L * .97, W * .03)} '
            f'C{P(L * .80, W * .16)} {P(L * .44, W * .22)} {P(L * .22, W * .10)} Z')

def ribs(g, n=4):
    """Fine lines running along a scale, like the grain of the real thing."""
    cx, cy, ax, ay, bx, by, L, W = g
    out = []
    for i in range(n):
        q = (i + .5) / n * 2 - 1
        a0, a1 = L * .34, L * (.93 - .34 * q * q)
        b0, b1 = W * .36 * q, W * .30 * q
        out.append(f'M{cx + ax * a0 + bx * b0:.1f} {cy + ay * a0 + by * b0:.1f} L{cx + ax * a1 + bx * b1:.1f} {cy + ay * a1 + by * b1:.1f}')
    return ' '.join(out)

def light_of(name, g):
    """How much of the one light from above and ahead reaches a scale, 0 to 1. It falls on the dome as on a ball, so
    the form turns from light into shadow as a whole."""
    cx, cy, ax, ay, bx, by, L, W = g
    x, y = cx + ax * L * .6, cy + ay * L * .6
    t = 1 - (y - 34) / 150
    t += (x - 110) / 420
    t += {'near_arm': .28, 'head': .18, 'near_leg': .14, 'far_arm': 0, 'far_leg': 0}.get(name, 0)
    return max(0, min(1, t))

# The drawing --------------------------------------------------------------------------------------------------

# the line of action, from the neck over the dome of the back, down the rump and along the tail
BODY = Part([(182, 100, 22), (156, 88, 42), (120, 90, 52), (84, 112, 54), (58, 148, 41), (38, 184, 28), (28, 214, 18), (36, 236, 11), (60, 247, 6), (90, 249, 1.5)])
# the same line carried on along the head, from the snout back to the neck
HEAD_TOP = Part([(230, 130, 2.5), (214, 115, 8), (196, 102, 14), (176, 90, 20)])
NEAR_ARM = Part([(148, 124, 14), (158, 146, 12.5), (172, 164, 10.5), (184, 174, 9)])
FAR_ARM = Part([(190, 132, 8), (204, 150, 8), (210, 166, 7), (210, 176, 6)])
NEAR_LEG = Part([(92, 150, 25), (92, 184, 16), (96, 216, 11.5), (102, 238, 10)])
FAR_LEG = Part([(130, 150, 16), (136, 184, 11), (134, 216, 9), (138, 238, 8)])

HEAD_SKIN = ('M164 88 C186 86 208 104 224 120 C233 129 244 136 245 143 C246 150 238 153 230 151 '
             'C214 147 200 148 184 148 C164 148 150 120 164 88 Z')
EYE = (207, 126, 3.8)
EAR = (186, 126, 3.2)
NOSE = (240.5, 145, 4.2)
NEAR_PAW = 'M172 164 C182 160 196 166 196 178 C196 186 186 190 176 188 C168 186 164 172 172 164 Z'
FAR_PAW = 'M202 166 C210 162 220 168 219 178 C218 185 208 188 202 184 C196 180 196 170 202 166 Z'

def claw(x, y, dx, dy, width, bend):
    """A long sickle of a claw from (x, y), reaching by (dx, dy), its back curved by `bend`."""
    length = math.hypot(dx, dy)
    tx, ty = dx / length, dy / length
    nx, ny = -ty, tx
    tip = (x + dx, y + dy)
    c1 = (x + dx * .30 + nx * bend, y + dy * .30 + ny * bend)
    c2 = (x + dx * .75 + nx * bend * 1.0, y + dy * .75 + ny * bend * 1.0)
    a = (x + nx * width / 2, y + ny * width / 2)
    b = (x - nx * width / 2, y - ny * width / 2)
    return (f'M{a[0]:.1f} {a[1]:.1f} C{c1[0] + nx * width * .5:.1f} {c1[1] + ny * width * .5:.1f} {c2[0] + nx * width * .10:.1f} {c2[1] + ny * width * .10:.1f} {tip[0]:.1f} {tip[1]:.1f} '
            f'C{c2[0] - nx * width * .30:.1f} {c2[1] - ny * width * .30:.1f} {c1[0] - nx * width * .55:.1f} {c1[1] - ny * width * .55:.1f} {b[0]:.1f} {b[1]:.1f} Z')

def near_claws():
    # thick at the root and hooked back towards the body, ready to dig
    return [claw(174, 182, -10, 36, 12, -13), claw(183, 184, -10, 40, 13, -14), claw(192, 180, -8, 38, 12, -13)]

def far_claws():
    return [claw(204, 180, -8, 30, 9, -9), claw(212, 178, -8, 32, 9, -10)]

def foot(x, y, far=False):
    """A hind foot: a low pad with short claws."""
    k = .85 if far else 1
    pad = f'M{x - 14 * k} {y - 13} C{x + 4 * k} {y - 20} {x + 20 * k} {y - 11} {x + 25 * k} {y} C{x + 15 * k} {y + 3} {x - 10 * k} {y + 3} {x - 16 * k} {y} Z'
    cl = [claw(x + d * k, y - 3, 11 * k, 3, 5, 2) for d in (9, 15, 21)]
    return pad, cl

def poly(pts):
    return 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts) + ' Z'

# how the amount of detail changes with the size the icon is shown at: 0 for 96 and up, 1 for 48 and 64
DETAIL = {0: dict(L=38, W=36, step=21, arm=(15, 14, 8.5), leg=(18, 17, 10), head=(11, 8, 6)),
          1: dict(L=58, W=56, step=33, arm=(26, 24, 15), leg=(30, 30, 17), head=(26, 20, 14))}

def layers(detail=0):
    """The drawing as (role, data) from back to front. Roles: under, skin, skin_far, scale, scale_far, claw, claw_far,
    eye, ear, nose. A scale's data is (part name, s, v, geometry, how far along the part 0-1, its light)."""
    D = DETAIL[detail]
    o = []
    def add_scales(name, part, role, **kw):
        for s, v, g in part.scales(**kw):
            o.append((role, (name, s, v, g, s / part.len, light_of(name, g))))
    al, aw, ast = D['arm']
    ll, lw, lst = D['leg']
    # the far leg, then the near one
    o.append(('skin_far', poly(FAR_LEG.outline())))
    pad, cl = foot(138, 244, True)
    o.append(('skin_far', pad))
    o += [('claw_far', d) for d in cl]
    add_scales('far_leg', FAR_LEG, 'scale_far', L=ll * .9, W=lw * .9, step=lst, under=.9, ref=14, fmin=.65, end=8)
    o.append(('skin', poly(NEAR_LEG.outline())))
    pad, cl = foot(102, 246)
    o.append(('skin', pad))
    o += [('claw', d) for d in cl]
    add_scales('near_leg', NEAR_LEG, 'scale', L=ll, W=lw, step=lst, under=.9, ref=18, fmin=.65, end=9)
    # the body
    o.append(('under', poly(BODY.outline(.96, .70))))
    add_scales('body', BODY, 'scale', L=D['L'], W=D['W'], step=D['step'], under=.68, ref=44, fmin=.34)
    # the far arm and its paw, the head, then the near arm in front of the chest
    o.append(('skin_far', poly(FAR_ARM.outline())))
    o.append(('skin_far', FAR_PAW))
    o += [('claw_far', d) for d in far_claws()]
    add_scales('far_arm', FAR_ARM, 'scale_far', L=al * .8, W=aw * .75, step=ast * .85, under=.9, ref=9, fmin=.7, end=9)
    o.append(('skin', HEAD_SKIN))
    o.append(('ear', EAR))
    o.append(('eye', EYE))
    o.append(('nose', NOSE))
    hl, hw, hst = D['head']
    add_scales('head', HEAD_TOP, 'scale', L=hl, W=hw, step=hst, under=.42, ref=12, fmin=.55, start=14, end=1)
    o.append(('skin', poly(NEAR_ARM.outline())))
    o.append(('skin', NEAR_PAW))
    o += [('claw', d) for d in near_claws()]
    add_scales('near_arm', NEAR_ARM, 'scale', L=al, W=aw, step=ast, under=.92, ref=12, fmin=.7, start=-3, end=10)
    return o
