# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

tt is a block-based terminal / IDE / browser for macOS, written in Zig and drawn with Metal. There are no Swift or Objective-C sources: AppKit, Metal, CoreText, WebKit and the rest are driven from Zig through the Objective-C runtime (`src/objc.zig`, `src/apple.zig`). The one dependency is libghostty-vt, pinned by commit in `build.zig.zon` and unpacked into the git-ignored `zig-pkg/`.

Product constraint from the README: **local only**. No account, sync, telemetry or update check; the only outbound traffic is what the user sends to an AI agent they configured, and the pages they open in website tabs. Assets a feature needs are vendored and embedded (e.g. `assets/notebook/plotly.min.js`), never fetched from a CDN.

## Commands

Requires Zig 0.17.1 (`minimum_zig_version` in `build.zig.zon`) and the Xcode command line tools.

```sh
zig build                         # zig-out/bin/tt
zig build run                     # build and launch (args after `--` are passed through)
zig build app                     # zig-out/tt.app, ad-hoc signed; needs full Xcode (actool compiles icon.icon)
zig build test                    # unit tests
zig build -Doptimize=ReleaseFast
```

If the first build fails while fetching ghostty, run it again.

**Tests.** `src/tests.zig` is the test root: a module's `test` blocks only run if it is imported there, so add new pure-logic modules to that list. `build.zig` wires no test filter, so there is no single-test command; `zig build test` runs everything.

**Headless UI runs.** These are how UI changes are checked, since unit tests cover logic only:

```sh
./zig-out/bin/tt --script demo.tt [--size 1440x900] [--scale 2]   # real app core, offscreen Metal, PNG via `snap`
./zig-out/bin/tt --probe 'ls' 'false'                             # pty + shell integration only, prints blocks as text
```

The script language (`type`, `key`, `click`, `drag`, `open`, `action <App.Action>`, `settle`, `snap out.png` …) is documented at the top of `src/script.zig`. Things to know:

- A script runs the user's real zsh with their real dotfiles and history, and reads `~/.tt/config.yml` and `~/.tt_projects`. Point `HOME` at a throwaway directory when a run must be isolated or reproducible.
- Scripts and the selftest do not read or write `~/.tt_workspace` unless `TT_WORKSPACE=<file>` names one.
- Headless there is no window, so nothing hosted in a native view exists (website tabs show only their chrome, notebook HTML outputs have no web view). The clipboard and "open in browser" are printed as `clipboard → …` / `browser → …`.
- `TT_SELFTEST=1` on the windowed binary posts real NSEvents through the window to exercise the AppKit side (hit testing, first responder, key routing); extra legs are selected with `TT_SELFTEST_*` variables, each described in a comment in `src/platform/cocoa.zig`. `TT_SELFTEST_SNAP` / `TT_SELFTEST_WINDOW_PNG` name the output images.
- `TT_DEBUG_EVENTS=1` prints input events, web-bridge messages and what a notebook kernel sends.

## Architecture

### Layers

- `src/main.zig` parses flags and picks one of three drivers: `probe` (session only), `script.runHeadless`, or `platform/cocoa.zig` `run`.
- `src/platform/cocoa.zig` is the macOS shell: NSApplication, NSWindow and one CAMetalLayer-backed NSView whose class is registered at runtime. It translates AppKit events into the `on*` methods of `App` and nothing else; app behaviour does not belong here.
- `src/app.zig` is the platform-neutral core. `App` owns the renderer, UI state, tab manager, projects, workspace, palette and overlay. The loop is `update(now)` (tick every tab, serve tab requests, save the workspace) → `buildFrame()` (immediate-mode UI into the draw list) → `present()` or `snapshot(path)`. Everything a menu item, shortcut, palette row or script can trigger is an `App.Action` handled in `perform`.

Because `script.zig` and `cocoa.zig` both drive the same `App`, a feature built in `App` and below is testable headless; anything that only exists in `cocoa.zig` is not.

### Rendering and UI

- `src/gfx/`: `draw.zig` is the draw list (the UI emits shapes and text in points; it converts to device pixels and snaps to the pixel grid), `renderer.zig` encodes one instanced Metal draw per frame plus one per distinct image texture, `text.zig` shapes with CoreText into a glyph atlas. Shaders (`shaders.metal`) and fonts are embedded through `addAnonymousImport` in `build.zig`.
- `src/ui/ui.zig` is a small immediate-mode core (input state, hit testing, hover/active). There is no retained widget tree: each view draws itself every frame and widgets live next to the views that use them. `ui/overlay.zig` holds the one modal menu or box that can be open; while it is, the app routes input to it.
- `src/ui/theme.zig` holds the design tokens. Colours and spacing are runtime variables (dark, light, e-ink, terminal themes from `themes.zig`, compact mode), so use the tokens rather than literals. App-wide zoom is folded into the points→pixels scale in `App`.

### Tabs

`src/tabs/tab.zig` defines a tab as pointer + vtable (the shape of `std.mem.Allocator`), built at comptime by `Tab.from(T, ptr)`: only `deinit` and `draw` are required, every other hook (`tick`, `save`, `command`, `closeWarning`, `path`, `relocate` …) has a default. A *kind* is a factory registered with `TabManager.register` in `App.create`. File viewers add an `accepts(path, head)` predicate; registration order is most-specific-first and `file` takes what is left. The header of `tab.zig` lists the steps for adding a kind.

Tabs do not reach into `App`. They get an `Env` (allocator, history, clipboard, textures, native-view host) and ask for app-level effects by queueing a `Request` on it (`openUrl`, `sendToShell`, `runInShell`, `closeTab` …), which `App.update` serves on the next tick. `Env.textures` and `Env.host` are null in tests and headless runs, and tab code must cope with that.

Tabs live in *groups*, one per sidebar row (see below). Each group has a pane tree (`tabs/layout.zig`: splits by weight, panes holding an ordered list of tabs); `layout.zig` only computes geometry, `ui/panes.zig` and `ui/tabbar.zig` draw.

### Projects, groups and persistence

`src/projects.zig` is the sidebar's model: the default project plus folder projects, each with *resources* (shell groups and pinned files). Projects and resources share one id space and each owns a tab group; id 0 is the default project's own tabs. Ids are reassigned on every load, so nothing on disk refers to them: the workspace file names groups by root and path instead. `.ai/features/main-sidebar.md` fixes the vocabulary for the sidebar's parts; use those names.

State is three plain files, each with its format documented at the top of its module:

| File | Module | Notes |
| --- | --- | --- |
| `~/.tt/config.yml` | `src/config.zig` | Hand-editable YAML subset; unknown keys ignored; older key names still read |
| `~/.tt_projects` | `src/projects.zig` | Tab-separated lines |
| `~/.tt_workspace` | `src/workspace.zig` | Records per `src/records.zig`; a kind takes part by implementing `save` and reading `OpenArgs.saved` |

Changes to these formats must keep older files readable (see the version and legacy-key handling already there).

### Terminal

- `term/session.zig` is one long-lived zsh on a PTY (`term/pty.zig`). `assets/shell/tt.zsh`, installed into a private `ZDOTDIR` by `term/shell_integration.zig`, emits OSC 133 marks from `preexec`/`precmd`; the session keeps only what arrives between marks and slices it into *blocks* (command, output, exit code, cwd, branch). The prompt and zsh's line editor are never shown: tt has its own input box (`src/input/`).
- Normal output goes through tt's own parser and line buffer (`term/parser.zig`, `term/buffer.zig`). When a program enters the alternate screen or raw mode, the block hands its stream to libghostty-vt through `term/screen.zig`, the only file that imports `ghostty-vt`; on exit the final screen becomes the block's output. Keep ghostty behind that seam, and keep `simd = false` in `build.zig`.
- `tabs/terminal_tab.zig` is the frontend: blocks, the input box, the command queue, and the agent features (`src/agent.zig` for API agents answering plain-English lines and Explain, `src/coding_agents.zig` for launching a CLI coding agent on a failed block).

### Documents, notebooks, web

- Text editing is shared: `input/editor.zig` (buffer, caret, selection, IME) → `input/document.zig` (line index, undo, per-line syntax state) → `tabs/text_editor.zig`. `syntax/` holds the lexers. The Markdown tab's preview (`tabs/markdown_view.zig`) is itself editable.
- Notebooks: `notebook/bridge.zig` starts `assets/notebook/tt_jupyter.py` with the notebook's Python; that script runs the kernel through jupyter_client and relays messages as one JSON line each over pipes. `tabs/notebook_tab.zig` is tt's own cell frontend; `notebook/ipynb.zig` reads and writes plain nbformat 4. HTML/Plotly/SVG outputs are WKWebViews clipped over the Metal layer.
- Website tabs (`tabs/web_tab.zig`, `web_bridge.zig`, `web_menu.zig`) host a WKWebView through `Env.host`; permissions and notifications go through `platform/media.zig` and `platform/notify.zig`.

### Settings

`tabs/settings_tab.zig` owns the page model; each page body is its own `tabs/settings_*.zig` file, and while the Settings tab is in front the sidebar becomes its navigation menu. What pages change lives in `config.zig`.

## Conventions

- All Objective-C goes through `objc.msg(ReturnType, target, "selector:", .{args})`; new C APIs get hand-written bindings in `apple.zig`. Do not add `.m`, `.swift` or C source files.
- File and libc access goes through `src/sys.zig` rather than `std.fs`/`std.Io`, to stay independent of std's changing I/O layer.
- Every module opens with a `//!` comment explaining its role and, for persisted data, its format. Keep those current when behaviour changes; they are the project's design documentation.
- `README.md` must keep "Local only (except for external AI agents)" as a headline feature, and its hero image `docs/screenshot-workspace.jpg` is the author's own capture: do not regenerate or replace it.
