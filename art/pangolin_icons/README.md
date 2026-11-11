# Pangolin icons

One base drawing of a standing pangolin, made into three styles. `python base.py` draws the base, and `python styles.py`
makes every size of the three icons into `out/`. They need Python with Pillow and NumPy, and something to render the
SVGs: Chrome on Windows, and otherwise ImageMagick built with librsvg (`magick`).

- `anatomy.py`: the drawing itself, on a 256 x 256 tile. Change the pose or proportions here and all three follow.
- `base.py`: the anatomy in plain natural colors, as `out/base.svg`. Judge a change to the drawing here first; `base.svg`
  in this folder is a copy of it.
- `styles.py`: Scales as vector art, Paints painted stroke by stroke, and pixel art.
- `SPRITE_16` in `styles.py`: the 16 pixel version, drawn by hand. Changes to the anatomy don't reach it.
- `pack.py`: writes `app.ico` and `app.res` from the finished PNGs.

Which drawing each size gets:

- 256 and 128: the full drawing. For Pixels that is pixel art on a 64 pixel grid.
- 64 and 48: Scales and Paints with fewer, bigger scales; Pixels as the 32 and 24 pixel art at twice its size.
- 32, 24 and 16: pixel art for all three, each in its own colors.

`out/proof.png` shows every size on a dark and a light background. Look at it before copying anything.

The finished files for an app are in `out/pixels`, `out/paints` and `out/scales`: `icon_<size>.png`, `app.ico`, `app.rc`,
`app.res` and the master drawing. Copy the folder's contents over the app's `assets/icon`.

`app.res` is `app.ico` compiled, so that building an app needs no resource compiler. `pack.py` writes the same bytes as
the Windows SDK's `rc /nologo /fo app.res app.rc`.
