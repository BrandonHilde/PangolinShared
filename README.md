# Pangolin Shared

The code the Pangolin tools have in common: Pangolin Paints, Pangolin Pixels and Pangolin Scales.
Each app has this repository as a git submodule in `libs/shared`.

Odin compiles one folder as one package, so the apps do not import this code. Their build scripts run
`sync.bat` / `sync.sh`, which copy `src/*.odin` into the app's `src` folder as `shared_*.odin`. Those copies
are ignored by git: change the code here, commit, then update the submodule in each app.

Everything here is `package pangolin` and can call what each app defines (`Cmd`, `cmd_help`, `Icon`, `dialog_close`, ...).

## License
BSD 3-Clause. See [LICENSE](LICENSE).
