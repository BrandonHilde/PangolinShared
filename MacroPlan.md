# Node macros: plan (Paints, Pixels, Scales)

## Goal
The user builds a macro as a node graph, in an editor that feels like Substance Designer: a pan-and-zoom canvas,
typed sockets, wires, a node library with search and a properties panel. The nodes are the app's own operations:
select, erase, fill, effects, layers, frames, transform, save and export. A macro can go in a tool group, so a group's
hotkey runs it. The graph model, file format, interpreter and editor live here in PangolinShared. Each app supplies
its node catalogue and the code that runs each node.

## What we build on
- **Commands.** Each app has a `Cmd` enum and a `run_cmd` switch: `PangolinPaints/src/commands.odin:423`,
  `PangolinPixels/src/commands.odin:411`, `PangolinScales/src/commands.odin:164`. `cmd_help` (in each app's `help.odin`)
  already gives every command a description, and the shared UI calls it (`src/ui.odin:908`).
- **Many commands open a dialog.** In Paints, Image Size, Canvas Size, Feather, Grow, Shrink, Rotate, Export, Layer
  Properties and every effect call `dialog_open`. A macro can't stop to ask, so it needs a version of each that takes
  its settings directly.
- **Paints effects are data-driven.** `FX_DEFS` (`PangolinPaints/src/fx.odin:64`) lists each effect's sliders (range,
  default, help text), checkbox and choice. `fx_run` and `live_begin` / `live_store` / `live_finish`
  (`PangolinPaints/src/edit.odin:221`) apply one without its dialog. Nodes for all 26 effects can be generated from this table.
  Pixels has per-layer filters (`Filter_Kind`, `PangolinPixels/src/filters.odin:8`).
- **Tool groups are the hotkey groups.** Each app's `toolgroups.odin` has a `Tool_Group` that holds tools, colours,
  blend modes (Paints), patterns (Pixels) or path operations (Scales). It has a hotkey, a name, and a place in the prefs
  and workspace files (`tool_groups_serialize`). Scales already has groups that hold *commands*: `PATH_OPS` and
  `group_run_op` (`PangolinScales/src/toolgroups.odin:40`, `:75`). The hotkey runs the group's last-used operation. Macro
  groups build on this but move on to the next macro after each run (see "Macros in hotkey groups").
- **Undo.** Each app has `history_push(d)`, which saves a snapshot of the whole document before an edit
  (`PangolinPaints/src/doc.odin:224`, `PangolinPixels/src/doc.odin:145`, `PangolinScales/src/doc.odin:215`).
  So a macro can be one undo step if only its first push is kept.
- **Shared UI.** `src/ui.odin` has buttons, sliders, `field_int`, `combo`, `checkbox`, popups, tooltips, clipping and
  `dialog_frame`. `src/gfx.odin` has `draw_line` (1 px, `gfx.odin:577`), rounded boxes and shadows. There's no curve or
  thick-line primitive yet, and no graph view.
- **Settings files.** Workspaces are text files in a folder next to the exe (`ws_dir` in each app's `workspaces.odin`).
  Macros can live in a `macros/` folder the same way.

## Design

### Graph model: a Document wire plus value wires (ComfyUI-style, 2026-11-07)
Pangolin operations change the open document, so every action node takes a **Document** input and passes it out the
other side, as ComfyUI passes a LATENT. Following that wire from the one `Start` node sets the order. No separate
"then" wires are needed. This reuses the apps' existing commands rather than rewriting each one as a pure image function.

- **The Document wire** (white, square sockets). Each node has at most one Document wire in and one out, so the wire
  can't loop.
- **Value wires** (round sockets, coloured by type) feed settings: Number, Bool, Color, Choice (an enum such as blend
  mode or format) and Text. A Number can also feed a Choice or a Bool.
- **Every setting is a widget on its node** with a socket beside it. A wired setting takes the wired value instead.
- **Value nodes** have no Document wire, and each gives one result per run. They are Number, On/Off, Color, Text,
  Math, Random and Document Info.
- **Recording** still works, as a quick way to start a graph. The editor is the main way to build one.

### Node kinds
| Kind | Examples | Where |
|---|---|---|
| Flow | Start, If, Repeat N, For each layer, For each frame, For each selected object (Scales), Run macro, Stop with message | shared |
| Value | Number, Color, Bool, Random, Math (+ − × ÷ min max clamp), Compare, Foreground/Background colour | shared |
| Document info | Width, Height, Layer count, Active layer, Frame count, Active frame, Has selection, File name | app (shared names) |
| Action | Select all, Select alpha, Grow selection(px), Clear, Fill(color), Gaussian blur(radius), New layer, Merge down, Next frame, Save, Export(format, quality, scale, path template) | app |

Node ids are strings: `cmd.Select_All`, `fx.Gaussian_Blur`, `flow.repeat`, `value.math`. They're never enum indices:
the `Cmd` enum gets reordered as features are added, and macro files last longer than prefs and get shared between
people. Apps map `cmd.*` ids with `reflect.enum_from_name`.

### Running a macro
- **One undo step.** Add `history_hold: int` to each app's `Doc`. While it's above zero, `history_push` does nothing.
  The interpreter calls `macro_history_begin(d)` (push once, then hold) and `macro_history_end(d)`.
- **All or nothing.** If a node fails (no selection, no layer below to merge into), the macro stops. The document goes
  back to the snapshot (`history_revert`), the status bar says *"Soft outline stopped at Grow: make a selection
  first"*, and the editor marks the node.
- **No dialogs.** Every action runs headless. Commands that only work through UI (Exit, Preferences, Help, the
  Workspaces manager, UI Scale) aren't in the catalogue at all.
- **Safety limits.** A cap on how many nodes one run can execute (e.g. 10,000), a Repeat limit, and a check that a macro
  doesn't call itself through `Run macro`. File writes go only to paths built from a template (`{name}_{frame}.png`
  next to the document, or a folder the user picked in the editor). A macro never opens a native file dialog.
- **Before a run**, the interpreter calls the app's `tools_commit_pending` (as `run_cmd` already does) and stops
  playback. It refuses to start while a dialog or text edit is open (the hotkey path already checks this).

### Macros in hotkey groups
- `Tool_Group` gains `macros: [dynamic]Name` and `next_macro: int`. A group of only macros is a **macro group**, like
  a colour group.
- **The hotkey runs the selected macro, then selects the next one in the group** (wrapping around at the end). So in a
  group of two, pressing the key twice runs both, in order. A group with a single macro runs it on every press, which
  is the usual case.
- If the macro fails (and is reverted), the selection doesn't move on, so the next press retries the same macro.
- Clicking a macro's button in the group panel selects it without running it, and the next hotkey press runs it. The
  selected macro is highlighted in the group panel, and the canvas-mode groups bar shows `[key] → next macro`, so
  it's always clear what the key will run.
- `next_macro` is saved with the group, so the selection survives a restart.
- Groups store macros by name. A group whose macro file is missing shows it greyed out with a tooltip, and the
  hotkey reports it in the status bar.
- `tool_groups_serialize` / `_parse` get one more field at the end, so old prefs and workspace files still load.

### Storage
`macros/<name>.pmacro` next to the exe: a versioned text file, readable and easy to diff, in the same spirit as the
workspace files:

```
pangolin-macro 1
app paints
name Soft outline
node 1 flow.start          x=0   y=0
node 2 cmd.Select_Alpha    x=180 y=0
node 3 cmd.Grow            x=360 y=0   px=4
node 4 fx.Gaussian_Blur    x=540 y=0   radius=20
node 5 value.number        x=360 y=120 v=4
flow 1 2
flow 2 3
flow 3 4
wire 5.out 3.px
```

Macros belong to one app (the `app` line). Flow and value nodes, and commands with the same name (`cmd.Undo`,
`cmd.Frame_Next`), use the same ids in every app, so simple macros may carry over. That's a bonus, not a promise.
The Macros manager imports and exports `.pmacro` files, as the Workspaces dialog does for workspaces.

### The editor
A full-window view that takes over from the side panels while it's open, as canvas mode does. It's opened from a new
`Macro_Editor` command (menu and shortcut). The shortcut opens it on the macro last edited, or a new one.

- **Left: node library.** Categories (Select, Edit, Layers, Effects, Frames, Image, File, Flow, Values), a search box,
  and the `cmd_help` text as tooltips. Drag a node onto the canvas, or double-click to add it.
- **Centre: graph.** Middle-drag or Space-drag pans; the wheel zooms around the cursor; F frames everything. Drag from a
  socket to connect. Dropping a wire on empty canvas opens the node search, filtered to nodes with a matching socket
  (the Substance workflow). Tab opens the node search at the cursor. Box-select, Delete, Ctrl+C / Ctrl+V / Ctrl+D, and
  grid snapping. Wires are cubic Béziers. Nodes show an error badge after a failed run.
- **Right: properties.** The selected node's settings, built from the catalogue with the existing `slider`,
  `field_int`, `combo` and `checkbox`. Effect sliders use `FX_DEFS`' ranges and help text. A connected setting shows the
  name of the node feeding it.
- **Top bar.** Macro picker, Rename, Save, Run, **Preview**, **Record**, and "Add to group".
- **Preview.** Runs the macro on the open document and shows the result live. Changing a setting re-runs it (on
  release for effects marked `heavy`). Turning Preview off reverts the document, and Run keeps the result. Preview uses
  the same begin, revert and end steps as a failed run.
- **Record.** While on, each `run_cmd` and each dialog OK (with the settings chosen) appends an action to the chain.
  This is the quickest way to start a macro, and it gives Phase 1 something useful before the editor exists.

## Shared code and app code
New shared files (`sync` copies them into each app automatically):

| File | Contents |
|---|---|
| `src/macro.odin` | Graph types (`Macro`, `Macro_Node`, `Macro_Link`, `Macro_Value` union), validation (one Start, no flow cycles except through loop nodes, type checks), the interpreter, the safety limits, Record |
| `src/macro_io.odin` | `.pmacro` read and write, the `macros/` folder list, import and export |
| `src/macro_flow.odin` | Flow and value nodes (Start, If, Repeat, For each, Math, Random, ...) |
| `src/macro_editor.odin` | Graph view, node library, properties panel, top bar, Preview |
| `src/gfx.odin` (add) | `draw_thick_line` and `draw_bezier` (SDL `RenderGeometry` quads), for wires and sockets |

What each app must define (shared code calls these, as it calls `Cmd` and `cmd_help` today):

```odin
macro_app_id       :: proc() -> string                       // "paints", "pixels", "scales"
macro_catalogue    :: proc() -> []Macro_Node_Def             // id, name, category, help, settings (type, range, default), flow or value
macro_exec         :: proc(id: string, args: []Macro_Value) -> (ok: bool, msg: string)
macro_query        :: proc(id: string, args: []Macro_Value) -> Macro_Value   // document-info nodes
macro_for_each     :: proc(kind: string) -> int              // layers, frames, objects: count, and
macro_for_each_set :: proc(kind: string, i: int)             // makes item i the active one
macro_history_begin, macro_history_end, macro_history_revert :: proc(d: ^Doc)
macro_dir          :: proc() -> string
```

**Build order matters.** `sync` copies every shared file into every app. So the commit that adds `macro.odin` breaks
any app without these procedures. Land each piece in all three apps together: first stubs (an empty catalogue,
`macro_exec` returning false), then fill them in app by app.

## Node catalogues per app
Most work happens in each app's new `macros.odin`. The pattern is the same in all three. Split each dialog-backed
command into `do_x(d, settings) -> (ok, msg)` and a dialog that calls it. Then `run_cmd`, the dialog and `macro_exec` all
share one code path. Commands that need no settings map straight to the `run_cmd` body, wrapped so they report failure
instead of only calling `set_status`.

- **Paints.** Selection: All, None, Invert, From alpha, Rectangle/Ellipse (Rect), Colour range (point, tolerance),
  Feather, Grow, Shrink. Edit: Clear, Fill (colour), Copy, Paste, Layer via copy/cut. Image: size, canvas size, crop to
  selection, trim, rotate, flip, flatten, auto contrast. Layers: new, duplicate, delete, move, merge, opacity, blend mode,
  lock alpha, masks. Frames: new, duplicate, delete, move, go to. Effects: all 26 generated from `FX_DEFS`, with Curves
  later. File: Save, Export (format, quality, scale, path template), PNG sequence, GIF. Colours: set FG/BG, swap.
- **Pixels.** The same groups where commands match (selection, layers, frames, flip, rotate, crop, trim), plus Outline,
  Replace colour (from, to), Scale sprite, Canvas size, Layer filter (`Filter_Kind` plus settings), Pixel-art convert,
  palette load and "from sprite", and Export PNG.
- **Scales.** Objects rather than pixels: Select all, Deselect, Select by type or colour, Group, Ungroup, order
  (raise, lower, front, back), Align and Distribute, the boolean operations, Combine, Break apart, Offset (distance),
  Simplify, Stroke to path, Object to path, Change fill and stroke (colour), Flip, Rotate, Fit page to content,
  Frames, Save, and Export. It adds a "For each selected object" loop.

Each app also gets a selftest that checks every `Cmd` is either in the catalogue or on an explicit "not for macros"
list. That way a command added later can't be silently left out.

## Steps
1. **Headless commands (each app, Paints first).** Split the dialog-backed commands into `do_x(settings)` plus
   their dialogs. Make the no-settings commands return ok/msg, and add `history_hold`. No UI changes, and it's worth
   doing for its own sake: selftests can call the operations directly.
2. **Shared core, plus stubs in all three apps.** `macro.odin` (linear chains only: Start plus actions) and
   `macro_io.odin`. Paints fills in its catalogue; Pixels and Scales ship stubs.
3. **Record, Run and macro groups (Paints).** Record a chain from the menus, save it, run it, and put it in a tool group
   on a hotkey. A Macros manager dialog (list, rename, delete, import, export), modelled on the Workspaces dialog. This
   is the first version users can try.
4. **Node editor.** `macro_editor.odin` and the gfx wire primitives: library, graph, properties, error badges. Then
   Preview.
5. **Flow and value nodes.** If, Repeat, For each, Math, Random, document info, Run macro, and loop and recursion limits.
6. **Pixels.** Its catalogue, macro groups and selftests. The shared parts are done by now.
7. **Scales.** Its catalogue (object-based), the "For each selected object" loop, macro groups next to its path-operation groups, and selftests.
8. **Later.** Exposed inputs: settings marked on the macro, shown in a small popup when you run it from the group panel
   with a modifier, like Substance's exposed parameters. Comment frames on the graph. Recording brush strokes.

## Tests (per app, in the existing `--selftest` suites)
1. `.pmacro` write → read → write gives the same text. Unknown node ids load as "missing" nodes, without crashing.
2. A macro gives the same document as running its commands one by one.
3. One Undo after a macro restores the document exactly, and Redo brings the macro's result back.
4. A failing node reverts everything and reports the node.
5. Repeat, For each and Run macro stop at their limits; a macro that calls itself is refused at load.
6. Every `Cmd` is in the catalogue or on the excluded list.
7. In a group of two macros, two hotkey presses run both in order, and a third runs the first again. A one-macro group
   runs it on every press. A failed run doesn't move the selection. Prefs and workspace files from before this change
   load with their groups intact.
8. Export through a macro writes only to the templated path.

## Risks and open points
- **Commands that report through the status bar.** Many commands signal failure only with `set_status` (for example
  `Crop_Sel`, `Layer_Merge`). Each needs a real return value. This is most of the work in step 1, and the easy part to
  underestimate.
- **Scales' history** pops "structure" snapshots specially (`history_step`, `PangolinScales/src/doc.odin:265`). Check
  that one held snapshot still restores correctly after many structural changes.
- **Memory in Paints.** Every snapshot is a full state clone. That's fine for one per macro, but Preview re-runs must free
  the snapshot each time.
- **Interactive state.** Tools mid-stroke, a pending transform or crop, or the text tool. Commit them before a run
  (`tools_commit_pending`), and refuse to run while text is being edited.

## Progress (2026-11-07)
- **Done, step 2: shared core.** `src/macro.odin` holds the graph, setting values, the runner (linear chains from
  Start) and Record. `src/macro_io.odin` holds the `.pmacro` format and the macros folder. Wires and value nodes come
  in step 5.
- **Done, steps 1 and 3 for Paints.** `PangolinPaints/src/macros.odin` has 106 nodes: 52 commands, the 25 tools,
  26 effects generated from `FX_DEFS`, and nodes with settings for selection, image, layers, colours, brush, frames and
  export. Other changes:
  - `history_hold` on `Doc`.
  - `doc_sel_modify`, `export_to_path` and `doc_canvas_size_anchored` pulled out of their dialogs.
  - Record hooks in `run_cmd` and the dialogs.
  - The Macros menu and the Macros dialog (run, rename, delete, import, export, record).
  - Macro groups in `toolgroups.odin` and the toolbar.
  - Selftests.
- **Placeholders for Pixels and Scales.** `src/macros.odin` in each has an empty catalogue, so both apps build with
  the shared files.
- **Done, step 4: the node editor.** `src/macro_editor.odin`, shared, opened from Macros > Node Editor in Paints.
  - The canvas pans and zooms. Widgets sit on the nodes at 100%, and zoomed out, nodes show their settings as text.
  - The library on the left lists every node. With a step selected, clicking an action adds it after that step, so
    clicking Start and then actions in turn builds the chain.
  - Search opens on double-click or Tab, and when a wire is dropped on empty canvas, listing only the nodes that fit.
  - Dragging a wire off an input moves it. There is box select (Ctrl-drag), Delete, Ctrl+D, Home to frame everything,
    and Esc to close.
  - The right panel has the selected node's settings and a live preview of the document.
  - Run (F5) shows an error outline on the node that failed. Save is Ctrl+S, and the macro is also saved when the
    editor closes or another macro is picked.
  - `src/gfx.odin` gained `draw_thick_line`, `draw_bezier` and `draw_dot`.
- **Done: branches.** A node can send the Document wire to several nodes. Branches run top to bottom and are numbered
  on the canvas. Each starts from the document as it was at the split: branch 1 keeps its changes, and the others are
  put back afterwards, so they suit exports. Apps provide `macro_snapshot`, `macro_restore` and `macro_snapshot_free`.
- **Done: easier layers and files in Paints.**
  - Pick Layer picks by name, above or below, top or bottom, or by number.
  - Export can export the whole image or only the active layer.
  - Save and Export each have a file setting with a ... picker.
  - Settings with `only = "key=choice"` show only while that choice is picked.
  - Typing on the canvas searches, and choices are listed too ("soft light" → Layer Blend Mode set to Soft Light).
- **Done: live layer effects in Paints** (`PangolinPaints/src/layerfx.odin`, 2026-11-07).
  - A layer can hold up to four macros, run on a copy of the layer whenever it changes.
  - Their result is drawn in place of the layer's pixels.
  - Steps that reach outside the layer are refused.
  - The effects are saved in `.ppnt` version 7, along with their macros.
  - `macro_lib_gen` tells effects that a macro changed.
- **Done, part of step 5: value nodes and value wires.** `wire a b.key` lines in the file. If, Repeat and For each are
  still to come.
- **Done: triggers** (2026-11-08). The Start node has a Trigger (`macro_trigger` in `src/macro.odin`), so a heavy
  macro doesn't run after every brush stroke.
  - **On Hotkey** (the default, and what older files load as): run by the user, from a tool group's key, the Macros
    menu or the Macros window.
  - **Layer effect triggers:** On Paint (after every change to the layer), After a Pause (once the layer has been left
    alone for Seconds), Every N Seconds (at most that often while it keeps changing), and On Demand (when added, and
    on Refresh in Layer Effects).
  - **Each list offers only the macros that fit it.** Groups, the Macros menu and the Macros window's Run take On
    Hotkey macros, and the blend list and Layer Effects take the rest. A macro in the wrong place says why instead of
    running. The editor's Run still runs any macro.
  - **A layer's effects run together**, so they follow the most careful trigger among them.
  - **Some changes apply at once whatever the trigger:** switching, adding or reordering effects, or changing the
    layer's blend mode or opacity. Exports don't wait for a timer, but On Demand still waits for Refresh.
  - **Only Paints offers the triggers** (`macro_layer_effects`). In the other apps, Start has no Trigger and every
    macro is On Hotkey.
  - The Trigger and Seconds settings are `no_wire`: they have no socket.
- **Not done yet.**
  - Choosing a tool by clicking it in a group isn't recorded (only `run_cmd` and dialog OKs are).
  - The editor has no undo of its own, and no copy and paste between macros.
  - Flow nodes (If, Repeat, For each), then steps 6 and 7 (Pixels and Scales catalogues; they already get the editor
    and value nodes from the shared code once they have a menu entry).

## Decisions (2026-11-07)
- A failing step undoes the whole macro.
- A macro group's hotkey runs the selected macro, then selects the next one in the group.
- Macros belong to one app.
- Recording freehand strokes isn't in the first version.
