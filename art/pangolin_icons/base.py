"""The base image: the anatomy drawn plainly in natural colors, so it can be judged before any style goes on it."""
import os, subprocess, sys
from anatomy import layers, shield, ribs

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
os.makedirs(OUT, exist_ok=True)
INK = '#2a1d14'

def mix(a, b, t):
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return '#%02x%02x%02x' % tuple(round(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))

def draw(fit=(.94, 8, 6)):
    out = []
    defs = []
    gid = 0
    for role, d in layers():
        if role in ('scale', 'scale_far'):
            name, s, v, g, along, light = d
            cx, cy, ax, ay, bx, by, L, W = g
            far = role == 'scale_far'
            tip = mix('#6e5138', '#d2ac82', light)
            root = mix('#3f2c1d', '#8f6c4c', light)
            if far:
                tip, root = mix(tip, '#2a1d14', .4), mix(root, '#2a1d14', .4)
            gid += 1
            defs.append(f'<linearGradient id="s{gid}" gradientUnits="userSpaceOnUse" x1="{cx:.1f}" y1="{cy:.1f}" x2="{cx + ax * L:.1f}" y2="{cy + ay * L:.1f}"><stop offset=".2" stop-color="{root}"/><stop offset="1" stop-color="{tip}"/></linearGradient>')
            out.append(f'<path d="{shield(g)}" fill="url(#s{gid})" stroke="{INK}" stroke-width="1.3" stroke-linejoin="round"/>')
            if L > 12:
                out.append(f'<path d="{ribs(g)}" fill="none" stroke="{INK}" stroke-opacity=".25" stroke-width=".7"/>')
        elif role == 'under':
            out.append(f'<path d="{d}" fill="#3a281b"/>')
        elif role == 'skin':
            out.append(f'<path d="{d}" fill="#8f7058"/>')
        elif role == 'skin_far':
            out.append(f'<path d="{d}" fill="#5a4332"/>')
        elif role == 'claw':
            out.append(f'<path d="{d}" fill="#d8c4a2" stroke="{INK}" stroke-width="1.1"/>')
        elif role == 'claw_far':
            out.append(f'<path d="{d}" fill="#a08c6e" stroke="{INK}" stroke-width="1.1"/>')
        elif role == 'eye':
            x, y, r = d
            out.append(f'<circle cx="{x}" cy="{y}" r="{r + 1.5}" fill="#4a3424"/><circle cx="{x}" cy="{y}" r="{r}" fill="#0e0a08"/><circle cx="{x + 1.2}" cy="{y - 1.3}" r="1.1" fill="#ffffff"/>')
        elif role == 'ear':
            x, y, r = d
            out.append(f'<circle cx="{x}" cy="{y}" r="{r + 1.2}" fill="#5a4332"/><circle cx="{x}" cy="{y}" r="{r - .6}" fill="#1a120c"/>')
        elif role == 'nose':
            x, y, r = d
            out.append(f'<ellipse cx="{x}" cy="{y}" rx="{r}" ry="{r * .85}" fill="#1a120c"/>')
    k, fx, fy = fit
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">\n'
            '<rect x="6" y="6" width="244" height="244" rx="54" fill="#c4d6e4"/>\n<defs>' + ''.join(defs) + '</defs>\n'
            f'<g transform="translate({fx} {fy}) scale({k})">\n' + '\n'.join(out) + '\n</g>\n</svg>\n')

def shot(svg, png, size=512):
    chrome = r'C:/Program Files/Google/Chrome/Application/chrome.exe'
    html = os.path.join(OUT, '_shot.html')
    with open(html, 'w') as f:
        f.write(f'<!doctype html><body style="margin:0;background:#3a3d46"><img src="{os.path.basename(svg)}" width="{size}" height="{size}"></body>')
    subprocess.run([chrome, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1', f'--screenshot={png}', f'--window-size={size},{size}', 'file:///' + html.replace(os.sep, '/')], capture_output=True, timeout=60)

if __name__ == '__main__':
    p = os.path.join(OUT, 'base.svg')
    with open(p, 'w') as f:
        f.write(draw())
    shot(p, os.path.join(OUT, 'base.png').replace(os.sep, '/'))
    print('base', os.path.getsize(p))
