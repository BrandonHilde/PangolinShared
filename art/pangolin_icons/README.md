# Pangolin icons

One base drawing of a standing pangolin, made into three styles. `python base.py` draws the base, and `python styles.py`
makes every size of the three icons into `out/`. They need Python with Pillow and NumPy, and Chrome to render the SVGs.

- `anatomy.py`: the drawing itself, on a 256 x 256 tile. Change the pose or proportions here and all three follow.
- `styles.py`: Scales as vector art, Paints painted stroke by stroke, and pixel art.
- `sprite32.py`, and `SPRITE_16` in `styles.py`: the 32 and 16 pixel versions, drawn by hand. Changes to the anatomy don't
  reach them.

The finished files go in each app's `assets/icon`: `icon_<size>.png`, `app.ico`, `app.rc` and `app.res`.

`app.res` is `app.ico` compiled, so that building an app needs no resource compiler. After changing `app.ico`, remake it
from that folder with the Windows SDK's `rc.exe`: `rc /nologo /fo app.res app.rc`. It is the only step here that needs the SDK.
