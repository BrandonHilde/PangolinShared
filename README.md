# Pangolin Shared

The code the Pangolin tools have in common: Pangolin Paints, Pangolin Pixels and Pangolin Scales.

**Looking for the apps?** This repository is only their shared code. Download them here:

| App | What it's for | Download |
|---|---|---|
| [Pangolin Pixels](https://github.com/BrandonHilde/PangolinPixels) | pixel art and sprite animation | [releases](https://github.com/BrandonHilde/PangolinPixels/releases) |
| [Pangolin Paints](https://github.com/BrandonHilde/PangolinPaints) | painting, oil paint and photo editing | [releases](https://github.com/BrandonHilde/PangolinPaints/releases) |
| [Pangolin Scales](https://github.com/BrandonHilde/PangolinScales) | vector drawings (SVG) and fonts | [releases](https://github.com/BrandonHilde/PangolinScales/releases) |
Each app has this repository as a git submodule in `libs/shared`.

Odin compiles one folder as one package, so the apps do not import this code. Their build scripts run
`sync.bat` / `sync.sh`, which copy `src/*.odin` into the app's `src` folder as `shared_*.odin`. Those copies
are ignored by git: change the code here, commit, then update the submodule in each app.

Everything here is `package pangolin` and can call what each app defines (`Cmd`, `cmd_help`, `Icon`, `dialog_close`, ...).

## Releases
`release/` holds what the apps' release builds share: `package.sh` lays out a ready-to-run folder for Windows,
Linux or macOS (run from an app's folder after building), `INSTALL-*.txt` are the guides that go in it, and
`release.yml` is the GitHub Actions workflow each app has as `.github/workflows/release.yml` (a tag such as
`v0.9.0-beta` builds all three and makes a draft release). Change `release.yml` here, then copy it into each app.

## License
BSD 3-Clause. See [LICENSE](LICENSE).
