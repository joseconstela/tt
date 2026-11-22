# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

tt is a block-based terminal / IDE / browser for macOS, written in Zig and drawn with Metal. There are no Swift or Objective-C sources: AppKit, Metal, CoreText, WebKit and the rest are driven from Zig through the Objective-C runtime (`src/objc.zig`, `src/apple.zig`). The one dependency is libghostty-vt, pinned by commit in `build.zig.zon` and unpacked into the git-ignored `zig-pkg/`.

Product constraint from the README: **local only**. No account, sync, telemetry or update check; the only outbound traffic is what the user sends to an AI agent they configured, the pages they open in website tabs, and, for a repository whose git host they added an account for (Settings › Git › Hosting), the pull-request requests to that host and no other. A feature that reaches a server is off until the user configures it, the way these are. Assets a feature needs are vendored and embedded (e.g. `assets/notebook/plotly.min.js`), never fetched from a CDN.

## Commands

Requires Zig 0.17.1 (`minimum_zig_version` in `build.zig.zon`) and the Xcode command line tools.

```sh
zig build                         # zig-out/bin/tt
zig build run                     # build and launch (args after `--` are passed through)
zig build app                     # zig-out/tt.app, ad-hoc signed; needs full Xcode (actool compiles icon.icon)
zig build install-app             # `app`, then copy it to ~/Applications/tt.app (add -Doptimize=ReleaseFast for a daily driver)
zig build test                    # unit tests, and the import boundaries (`zig build arch` alone)
zig build -Doptimize=ReleaseFast
```

If the first build fails while fetching ghostty, run it again.

**Tests.** `src/tests.zig` is the test root: a module's `test` blocks only run if it is imported there, so add new pure-logic modules to that list (a feature is listed once, by its public file, whose own `test` block names the files inside). `build.zig` wires no test filter, so there is no single-test command; `zig build test` runs everything, including `tooling/arch_check.zig`, which fails the run when an `@import` crosses a boundary described under "Features" below. Its messages say which file to import instead.

**Headless UI runs.** These are how UI changes are checked, since unit tests cover logic only:

```sh
./zig-out/bin/tt --script demo.tt [--size 1440x900] [--scale 2]   # real app core, offscreen Metal, PNG via `snap`
./zig-out/bin/tt --probe 'ls' 'false'                             # pty + shell integration only, prints blocks as text
```

The script language (`type`, `key`, `click`, `drag`, `open`, `action <App.Action>`, `settle`, `snap out.png` …) is documented at the top of `src/script.zig`. Things to know:

- A script runs the user's real zsh with their real dotfiles and history, and reads `~/.tt/config.yml` and `~/.tt_projects`. Point `HOME` at a throwaway directory when a run must be isolated or reproducible.
- Scripts and the selftest do not read or write `~/.tt_workspace` unless `TT_WORKSPACE=<file>` names one.
- Headless there is no window, so nothing hosted in a native view exists (website tabs show only their chrome, notebook HTML outputs have no web view). The clipboard and "open in browser" are printed as `clipboard → …` / `browser → …`.
- Scripts and the selftest do not listen for `tt <path>` either unless `TT_SOCKET=<file>` names a socket of their own; the script command `cli /path` does what the argument does.
- `TT_SELFTEST=1` on the windowed binary posts real NSEvents through the window to exercise the AppKit side (hit testing, first responder, key routing); extra legs are selected with `TT_SELFTEST_*` variables, each described in a comment in `src/platform/cocoa.zig`. `TT_SELFTEST_SNAP` / `TT_SELFTEST_WINDOW_PNG` name the output images. `TT_SELFTEST_NOFOCUS=1` shows the windows without taking the keyboard (for legs that only post mouse events, like `TT_SELFTEST_WINDOWS`), so a run does not swallow what the user is typing elsewhere.
- Headless there are no real windows either, but separate tab windows exist in the app all the same: `window N` addresses one (pointer, keyboard, `snap`), `frame` says where a window is on screen, `tabs` prints where every tab is.
- `TT_DEBUG_EVENTS=1` prints input events, web-bridge messages and what a notebook kernel sends.

## Architecture

### Layers

- `src/main.zig` parses flags and picks one of three drivers: `probe` (session only), `script.runHeadless`, or `platform/cocoa.zig` `run`. Paths on the command line (`tt .`, `tt notes.md`) go through `src/cli.zig`: handed to the running tt over the socket `~/.tt/tt.sock` (`$TT_SOCKET` overrides it) and opened by `App.openPath` in the default project, else the app starts detached with them (`--foreground` keeps it attached and hands nothing over). The app menu's "Install CLI Tools…" (`App.Action.install_cli` → `cli.install`) links `/usr/local/bin/tt` to the running binary; `$TT_CLI_LINK` moves the link for tests.
- `src/platform/cocoa.zig` is the macOS shell: NSApplication, and for every window of ours (the main one, plus one per tab the user took out of it) an NSWindow with one CAMetalLayer-backed NSView whose class is registered at runtime, kept in a `Win` record. It translates AppKit events into the `on*` / `pointer*` methods of `App` (saying which window they are for), makes the real windows match the app's list each tick, and nothing else; app behaviour does not belong here.
- `src/app.zig` is the platform-neutral core. `App` owns the renderer, UI state, tab manager, projects, workspace, palette and overlay. The loop is `update(now)` (tick every tab, serve tab requests, save the workspace) → `buildFrame()` (immediate-mode UI into the draw list) → `present()` or `snapshot(path)`, then the same for each separate window (`buildWindowFrame` → `presentWindow`), one after the other since they share the glyph atlas. Everything a menu item, shortcut, palette row or script can trigger is an `App.Action` handled in `perform`.

Because `script.zig` and `cocoa.zig` both drive the same `App`, a feature built in `App` and below is testable headless; anything that only exists in `cocoa.zig` is not.

### Features

New code is organised by feature, after Lauren Tan's Dune architecture: everything one capability needs sits in one folder, the folder has one public file, and the boundaries are checked rather than remembered. Code that predates this (most of `src/`) stays where it is and moves over feature by feature, when it is next reworked.

```text
src/features/<name>/
├── <name>.zig   the public surface: the only file code outside the folder may import
├── hosts.zig    the effects the feature is handed (pointer + function, like `Env`): running a command, HTTP …
├── model/       data and parsing; imports `std` and `model/` only
├── client/      everything that reaches outside (git, a hosting API), through `hosts.zig` only
├── view/        drawing; reads model data, returns what the user asked for as an intent, runs nothing
└── entry/       what the app mounts (a tab kind, a panel, a settings page): a view and its client put together
```

- A frame does no I/O: a view never imports `sys.zig`, `http.zig` or its `client/`. It returns an intent and the entry hands it to the client (`features/repo/view/panel.zig` → `entry/panel.zig`).
- A client takes its effects as parameters, so its tests pass a stand-in (`FakeGit` in `features/repo/client/git.zig`).
- Framework code (`gfx/`, `input/`, `term/`, `syntax/`, `sys.zig`, `objc.zig`, `apple.zig`, `tabs/tab.zig`, and the core of `ui/`: the exact list is at the top of `tooling/arch_check.zig`) imports no feature and not `app.zig`.
- One owner per thing: every git command on a repository goes through `features/repo/client/git.zig` (`Repo` for what changes it, `Query` for what only reads); the `accounts:` section of `config.yml` is read and written only by `features/repo/client/accounts.zig`; requests to a hosting API are sent only by `features/repo/client/forge.zig`.

Features so far:

- `repo`: git for a repository. The files panel's Git view and the tree's colours (`entry/panel.zig`); the repository tab (`entry/tab.zig`, kind `repo`, `App.Action.open_repository`): History with its graph, Changes, Stashes, and Pull Requests; Settings › Git › Hosting (`entry/settings.zig`). Pull requests are the same model whichever host they come from (`model/pull_request.zig`): each of `client/github.zig`, `gitlab.zig`, `bitbucket.zig` and `gitea.zig` only builds requests and decodes answers, `client/forge.zig` sends them through `hosts.Http`, and a pull request's files and diffs come from local git (`client/pull_files.zig`), not from the host. A control a host has no answer for is hidden through `Capabilities`. Each backend is tested against JSON in `fixtures/`, written to the shapes the real APIs return.
- `diff`: the side-by-side comparison tab, of the index and the working tree or of two revisions.
- `windows`: a tab in a window of its own. `entry/window.zig` is `TabWindow`, what one separate window draws with (its own draw list, `Ui`, pane view, size and scale); `model/frames.zig` is where windows are on screen as plain numbers (which window a point is over, where a new one opens, the workspace record). `App` owns the windows (`detachTab`, `dropOutside`, `closeWindow`) and `platform/cocoa.zig` gives each an NSWindow. A separate window is tabs only: the strip in its titlebar band and the panes, no sidebar or files panel. The theme is one for all windows (it follows the display the main window is on).
- `explorer`: the files tree of the files panel (`entry/tree.zig`, mounted by `ui/files.zig` beside the Search and Git views; `ui/files.zig` itself is only the panel's shell: the splitter and the Files / Search / Git strip). Rows carry an icon (`view/icon.zig`: a folder open or closed, a file by what it holds) and no disclosure arrow; an unfolded folder draws one vertical line per level. A click on a folder comes out of the view as an intent and the entry lists it through `hosts.Dirs`, so no frame reads the disk.

`.ai/features/repos/view.md` names the parts of the repository view (and of the Git view's commit button) and says what each host can do; use those names.

`src/http.zig` is the generic HTTP request (NSURLSession: any method, the whole body, the response headers); `agent.zig` keeps its own streaming transport.

### Rendering and UI

- `src/gfx/`: `draw.zig` is the draw list (the UI emits shapes and text in points; it converts to device pixels and snaps to the pixel grid), `renderer.zig` encodes one instanced Metal draw per frame plus one per distinct image texture, `text.zig` shapes with CoreText into a glyph atlas. Shaders (`shaders.metal`) and fonts are embedded through `addAnonymousImport` in `build.zig`.
- `src/ui/ui.zig` is a small immediate-mode core (input state, hit testing, hover/active). There is no retained widget tree: each view draws itself every frame and widgets live next to the views that use them. `ui/overlay.zig` holds the one modal menu or box that can be open; while it is, the app routes input to it.
- `src/ui/theme.zig` holds the design tokens. Colours and spacing are runtime variables (dark, light, e-ink, terminal themes from `themes.zig`, compact mode), so use the tokens rather than literals. App-wide zoom is folded into the points→pixels scale in `App`.

### Tabs

`src/tabs/tab.zig` defines a tab as pointer + vtable (the shape of `std.mem.Allocator`), built at comptime by `Tab.from(T, ptr)`: only `deinit` and `draw` are required, every other hook (`tick`, `save`, `command`, `closeWarning`, `path`, `relocate` …) has a default. A *kind* is a factory registered with `TabManager.register` in `App.create`. File viewers add an `accepts(path, head)` predicate; registration order is most-specific-first and `file` takes what is left. The header of `tab.zig` lists the steps for adding a kind.

Tabs do not reach into `App`. They get an `Env` (allocator, history, clipboard, textures, native-view host) and ask for app-level effects by queueing a `Request` on it (`openUrl`, `sendToShell`, `runInShell`, `closeTab`, `openDiff`, and `askConfirm` / `askMenu` for a box or a menu, whose answer comes back through the tab's `answered` hook …), which `App.update` serves on the next tick. `Env.textures` and `Env.host` are null in tests and headless runs, and tab code must cope with that.

Tabs live in *groups*, one per sidebar row (see below), plus one per separate window (a *window group*, ids from `TabManager.window_group_base`). Each group has a pane tree (`tabs/layout.zig`: splits by weight, panes holding an ordered list of tabs); `layout.zig` only computes geometry, `ui/panes.zig` and `ui/tabbar.zig` draw.

`TabManager.shown` is the row in the main window's strip; `keyed` is the window group that has the keyboard instead, when a separate window is key. `group()`, `pane()`, `current()`, `open*`, `close` and the like mean "where the user is" (`keyed orelse shown`), so actions and typing go to the key window without knowing about windows; code that is about the main window (the sidebar, the files panel, `keepShowingSomething`) says `shown` / `shownGroup()`. Pane ids are unique across groups, so `moveTab` takes a tab to any pane of any group, and `moveTabToGroup` to a row's or a window's tabs: the tab is the same object afterwards. A tab dragged by its title lands in a strip or a pane of its window, on a sidebar row (that row's own tabs), on another window (what it shows), or, let go outside every window, in a new window of its own; the tab menu's "Move to…" and "Move to New Window" do the same without a drag.

### Projects, groups and persistence

`src/projects.zig` is the sidebar's model: the default project plus folder projects, each with *resources* (shell groups and pinned files). Projects and resources share one id space and each owns a tab group; id 0 is the default project's own tabs. Ids are reassigned on every load, so nothing on disk refers to them: the workspace file names groups by root and path instead. `.ai/features/main-sidebar.md` fixes the vocabulary for the sidebar's parts; use those names.

State is three plain files, each with its format documented at the top of its module:

| File | Module | Notes |
| --- | --- | --- |
| `~/.tt/config.yml` | `src/config.zig` | Hand-editable YAML subset; unknown keys ignored; older key names still read |
| `~/.tt_projects` | `src/projects.zig` | Tab-separated lines |
| `~/.tt_workspace` | `src/workspace.zig` | Records per `src/records.zig`; a kind takes part by implementing `save` and reading `OpenArgs.saved`; separate windows come back too (`window` records: frame and tabs) |

Changes to these formats must keep older files readable (see the version and legacy-key handling already there).

### Terminal

- `term/session.zig` is one long-lived zsh on a PTY (`term/pty.zig`). `assets/shell/tt.zsh`, installed into a private `ZDOTDIR` by `term/shell_integration.zig`, emits OSC 133 marks from `preexec`/`precmd`; the session keeps only what arrives between marks and slices it into *blocks* (command, output, exit code, cwd, branch). The prompt and zsh's line editor are never shown: tt has its own input box (`src/input/`).
- Normal output goes through tt's own parser and line buffer (`term/parser.zig`, `term/buffer.zig`). When a program enters the alternate screen or raw mode, the block hands its stream to libghostty-vt through `term/screen.zig`, the only file that imports `ghostty-vt`; on exit the final screen becomes the block's output. Keep ghostty behind that seam, and keep `simd = false` in `build.zig`.
- `tabs/terminal_tab.zig` is the frontend: blocks, the input box, the command queue, and the agent features (`src/agent.zig` for API agents answering plain-English lines and Explain, `src/coding_agents.zig` for launching a CLI coding agent on a failed block, `src/agent_cli.zig` for asking such a CLI one question without its interface when it is the one chosen for plain-English lines).

### Documents, notebooks, web

- Text editing is shared: `input/editor.zig` (buffer, caret, selection, IME) → `input/document.zig` (line index, undo, per-line syntax state) → `tabs/text_editor.zig`. `syntax/` holds the lexers. The Markdown tab's preview (`tabs/markdown_view.zig`) is itself editable.
- Comparisons: a row of the files panel's Git view (the `repo` feature, mounted by `ui/files.zig`) opens the `diff` feature's tab (`features/diff/entry/tab.zig`), two read-only `TextEditor`s side by side over the rows `features/diff/model/rows.zig` computes (the versions come from `git show` and the disk).
- Notebooks: `notebook/bridge.zig` starts `assets/notebook/tt_jupyter.py` with the notebook's Python; that script runs the kernel through jupyter_client and relays messages as one JSON line each over pipes. `tabs/notebook_tab.zig` is tt's own cell frontend; `notebook/ipynb.zig` reads and writes plain nbformat 4. HTML/Plotly/SVG outputs are WKWebViews clipped over the Metal layer.
- Website tabs (`tabs/web_tab.zig`, `web_bridge.zig`, `web_menu.zig`) host a WKWebView through `Env.host`; permissions and notifications go through `platform/media.zig` and `platform/notify.zig`.

### Settings

`tabs/settings_tab.zig` owns the page model; each page body is its own `tabs/settings_*.zig` file, and while the Settings tab is in front the sidebar becomes its navigation menu. What pages change lives in `config.zig`.

## Conventions

- All Objective-C goes through `objc.msg(ReturnType, target, "selector:", .{args})`; new C APIs get hand-written bindings in `apple.zig`. Do not add `.m`, `.swift` or C source files.
- File and libc access goes through `src/sys.zig` rather than `std.fs`/`std.Io`, to stay independent of std's changing I/O layer.
- Every module opens with a `//!` comment explaining its role and, for persisted data, its format. Keep those current when behaviour changes; they are the project's design documentation.
- `README.md` must keep "Local only (except for external AI agents)" as a headline feature, and its hero image `docs/screenshot-workspace.jpg` is the author's own capture: do not regenerate or replace it.
