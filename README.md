# conch

A calm, block-based terminal for macOS, written in **Zig** and rendered with **Metal**.
The look follows the "1b · Workspace, calm" artboard: a resizable sidebar with your
projects, a tab strip in the titlebar band, a chat-like column of command blocks, a single
input box and a files panel on the right. ⌘K opens the command palette from the "Command
palette" artboard.

The terminal is real: every tab owns a persistent login `zsh` on a PTY, with your own
dotfiles, aliases, `cd` state and environment.

```
zig build run            # build + launch (Zig 0.16, macOS, Xcode command line tools)
zig build app            # → zig-out/conch.app
zig build test           # unit tests for the pure-logic modules
zig build -Doptimize=ReleaseFast
```

No Objective-C, no Swift: AppKit, Metal, CoreText, CoreGraphics, ImageIO and WebKit are driven
straight from Zig through the Objective-C runtime. One dependency: [libghostty-vt](https://github.com/ghostty-org/ghostty),
Ghostty's terminal emulation core, runs the programs that take over the terminal (vim,
htop, Claude Code …). `zig build` fetches it the first time, pinned to a commit in
`build.zig.zon` (about 130 MB unpacked into `zig-pkg/`, git-ignored).

## What works

| Area | Details |
| --- | --- |
| Sidebar | Projects and nothing else, one tree under the header, whose "+" (next to the collapse button) adds a folder as a project (a native folder picker; `Shell › Add Project Folder…` ⌘⇧O does the same). First in the tree, **Default project**: what belongs to no folder — the first shell, ⌘N tabs, Settings. Then the **projects**, one foldable row each (the chevron folds it). **Every row owns a set of tabs**: a project has tabs of its own, and under it sit its **sub-resources** — groups of shells and pinned files — each with its own tabs; the default project has sub-resources too. Clicking a row puts its tabs in the strip (a project or shell group with none starts a shell in its folder, a file resource starts with its viewer; clicking the row again steps through its tabs), and the highlighted row is the one whose tabs are in the strip. A row shows how many tabs it holds and a teal dot while one runs. Hovering the default project or a project shows a terminal button that opens one more shell tab among that row's own tabs (so does "+" in the strip, or ⌘T, for the row on show). Rows have no other buttons; everything else is in the **right-click menu**: a project has *Rename…* (blank goes back to the folder's name), *New Shell Group* (a sub-resource of shells in its folder), *Set Icon…* and *Remove Project*; the default project has *New Shell Group* (in the current directory) and *Set Icon…*; a sub-resource has *Rename…* (the sidebar label only), *Set Icon…* and *Remove from Project*. An icon is a symbol from the app's set or a coloured dot, shown before the name. Removing moves the open tabs to the default project instead of closing them. Saved to `~/.conch_projects`. Chrome: the edge drags to resize (double-click resets), collapses to an icon rail (button, drag, or ⌘B). |
| Files panel | The current shell's directory as a tree (folders first, case-insensitive, dotfiles shown), re-read every two seconds so new files appear. Folders unfold in place, a click opens a file in the viewer that claims it (see below), hover "+" pins the file as a sub-resource of the project that contains it (of the default project otherwise). Follows the active tab's directory; resizable from its left edge; ⌘⇧E or the folder button at the right of the titlebar band hides it. |
| Tabs | The strip shows the tabs of the sidebar row on show (a project, one of its sub-resources, or the default project). Open (⌘T, "+", sidebar), close (⌘W, the tab's menu), switch (click, ⌘1–9, ⌘⇧[ / ⌘⇧], ⌃Tab) — all within that set. A teal dot marks a running command and the title becomes that command; a red dot marks a failure you have not seen yet; an accent dot marks unsaved changes. Seven kinds so far: terminal, text editor, Markdown editor, image, PDF, settings, website. |
| Split panes | The content area splits like VS Code's editor groups, so several tabs — shells, files, a PDF — are on screen at once. **Drag a tab by its title**: onto another strip to move it there (a bar shows where it lands), onto the left / right / top / bottom edge of a pane to open a new pane on that side with it, onto the middle of a pane to add it to that pane. ⌘D / ⌘⇧D split the focused pane right / down with a new shell in the current directory; a tab's menu has *Split Right* / *Split Down* for the tab itself. Every pane has its own strip: in the titlebar band for the panes along the top, at the pane's top otherwise. A click focuses a pane (its active tab gets the accent underline and the keyboard); ⌘] / ⌘[ move the focus along; the lines between panes drag to resize. A pane whose last tab closes or leaves goes away, and the layout belongs to the sidebar resource on show, so each resource keeps its own arrangement. |
| Across relaunches | Quit and reopen: every tab is back where it was — in its sidebar row: a project, one of its sub-resources or the default project (a sub-resource that is gone hands its tabs to its project), **in the same pane of the same split layout** (arrangement, sizes, which pane had the focus, which tab each pane showed), with its name and, for a shell, its directory and its blocks: commands, output with colours, exit codes, durations, notes, collapsed or expanded. A file tab shows its file again — the editor with the caret where it was, Markdown in the mode it was in, an image at fit or 1:1 as it was, a PDF on the page it was on — and a website tab loads its address again; a file that is gone by then is simply not brought back. The shell tab in front of each visible pane starts its shell right away; the others start theirs the first time you press ↵ or run something, in the directory they were in. Saved to `~/.conch_workspace` (0600) a couple of seconds after anything changes and again on quit, so a crash loses at most the last moments. Each block keeps its last 2 000 lines, each tab its newest blocks within 1 MB. |
| Viewers | Opening a file asks the registered viewer kinds in turn which one wants it, judging by the first bytes first and the extension second, so a renamed PNG still opens as a picture. **Images** (anything ImageIO reads: PNG, JPEG, GIF, HEIC, TIFF, BMP, WebP, PSD, RAW …) are decoded with their EXIF rotation, downsampled to 4096 px if larger, and fitted to the card; a click toggles 1:1 pixels, where the wheel pans. **PDFs** show their pages one under another at the card's width, rasterised by CoreGraphics at the backing scale as they scroll into view and dropped again when far away; the header counts pages, ⇞/⇟ and the wheel scroll. Password-protected files say so. **Markdown** opens in its own editor (below). Everything else lands in the **text editor**, which also explains binaries it cannot show. |
| Editing | Text files open in a real editor: caret, selection (mouse drag, double-click word, triple-click line, ⇧ + arrows), the user's Cocoa key bindings, IME, cut/copy/paste, undo/redo (⌘Z / ⌘⇧Z, typing coalesces), auto-indent on ↵, Tab / ⇧Tab indent a selection. **Syntax colours** for 29 languages (SQL, CSV, JSON, Zig, shells, Python, JavaScript/TypeScript, C/C++/Objective-C, Rust, Go, Java, Swift, Ruby, PHP, YAML, TOML, INI, Make, Dockerfile, Lua, CSS, HTML/XML, diff, Markdown), chosen by filename, extension or shebang — never by guessing. **⌘S saves atomically** (temp file + rename, keeping permissions; CRLF files stay CRLF). The header says *Modified*, *Saved*, *Read-only*, *Changed on disk* or *Deleted on disk*: a clean buffer reloads when the file changes underneath it, a dirty one keeps your edits and says so. Closing or quitting with unsaved changes asks first. Files over 4 MB and binaries open read-only. |
| Markdown | An Obsidian-style editor with two modes; the **Preview / Source** switch in the card header, ⌘E, the View menu and the palette flip between them. **Preview** (the default) renders the note in place — headings, bullets, numbered and task lists, quotes, code blocks, bold/emphasis/strike, inline code, links and `[[wikilinks]]`, `#tags`, front matter — while it stays editable: the syntax markers of the caret's line are shown so they can be edited, every other line hides them; ↑/↓ move through wrapped rows, and a click on a task's checkbox ticks it without moving the caret. **Source** is the code editor with Markdown colouring. Both modes edit the same buffer, so the caret, selection, undo history and unsaved state carry across a switch. |
| Websites | The globe next to "+" (also ⌘⇧N, the palette, `Shell › New Website Tab`) opens a website tab: a row with back, forward, reload and an address bar, and under it the page, edge to edge. The page is a **WKWebView** — the system WebKit, the engine behind Safari, driven through the Objective-C runtime like AppKit — that the platform layer hosts over the Metal layer and places wherever the tab is drawn; it hides while the palette or a box covers the window, and the keyboard comes back to the app then. The address bar takes an address as is, puts `https://` in front of anything host-like (`http://` for localhost), and searches DuckDuckGo for the rest; ⌘L focuses it with everything selected, ⌘R reloads (× stops while loading), ⌘⌥← / ⌘⌥→ go back and forward (the trackpad swipe too), Esc gives the page the keyboard back. The tab is titled after the page, the context line shows the address, a teal dot means loading, a lock means HTTPS. A load that fails shows why with a *Try Again*; links that want a new window open in the same tab. Right-click › *Inspect Element* opens the Web Inspector. Not there yet: downloads, find in page, password autofill. Website tabs come back after a relaunch with their address (the workspace keeps it); the web view is made once the window exists. Headless runs (`--script`, tests) have no window and so no web view: the chrome still works and the body says so; `CONCH_SELFTEST_URL=https://… CONCH_SELFTEST=1` verifies the real thing, and `CONCH_SELFTEST_URL=restored` with `CONCH_WORKSPACE=file` checks a tab kept from a previous run. |
| Command palette | ⌘K. A floating panel over a dimmed window with a query, scope chips and grouped rows: app commands (with their shortcuts), the open tabs, recent shell history (↵ runs it in the active terminal) and the accent colour. Fuzzy matching for commands, contiguous matching for history, ↑/↓ + ↵, Tab / ⇧Tab cycle the scope, a leading `>` `@` `!` `:` narrows it, Esc or a click outside closes. |
| Input box | Caret, selection, word/line movement (the user's Cocoa key bindings apply), IME and dead keys, multi-line (⇧↵), paste, history (↑/↓, prefix-filtered), fish-style ghost suggestions from history and from the filesystem (Tab or → accepts). While a program runs the box feeds its stdin; it masks input when the program turns echo off. |
| Blocks | One block per command with live status and duration, ANSI colours (16/256/true colour, bold, dim, underline, inverse, strike), `\r` progress bars, cursor-up redraws, soft wrapping that reflows with the window, collapse of long output, mouse text selection + ⌘C, "Copy output", "Run again". Failed commands get the red outline and action row from the design. |
| Asking the agent | Pick an agent under **Settings › AI › Features** and plain English just works: a line the shell does not know (`how big is this folder`) goes to the agent instead of dying as "command not found", no prefix needed (`# question` still asks outright). The block becomes the agent's turn — a sparkle instead of the `$`, *Thinking* with a timer, the answer streaming in as mono output, *Answered* when it is done — with the same selection, copy (*Copy answer*), collapse and relaunch persistence as any output. **The agent sees the tab**: every request carries a transcript of the commands run so far with what they printed (stdout and stderr together, the last 60 lines / 4 KB of each) and how they ended, plus the earlier questions and answers, newest first within 32 KB, so "why did that fail?" and "and for hidden files too?" make sense. **It proposes, you run**: the agent has one tool, `propose_command`; a command it proposes shows in the block as `→ cmd` and lands in the input box, trimmed of any newline, where it waits for ↵ — it never runs by itself and never overwrites something you are typing. A local model that writes the call into its reply instead of making one (Gemma's `propose_command{…}`, a JSON object, a `<tool_call>` element) is caught too: the text is taken out of the answer and treated the same. ⌃C stops an answer half-way (*Interrupted*, what arrived stays); an agent that cannot answer says why (*No answer*: a wrong key, a missing model, an unreachable server). Only a line that failed with 127 *because* of an unknown command goes over: `foo \| grep x` or `foo; ls` ran something, so they stay shell blocks. Speaks Anthropic's Messages API, OpenAI's chat completions (OpenAI, Mistral, Ollama, any compatible endpoint) and Gemini, all streamed, tool calls included. |
| Settings | ⌘, (or the palette) opens the Settings tab; there is no button for it. The tab turns the sidebar into its menu: **UI › Mode** (Dark / Light / System / E-ink — "System" follows macOS, re-checked every two seconds, and the window's own titlebar switches with it; "E-ink" is ink on paper for e-paper panels: black on white with greys a 16-level panel can show, no colour at all, no blinking caret, no hover tint, no translucent scrims or soft shadows, borders around blocks and cards instead of tints, and the 256/true colours programs print mapped to greys that read on white), **UI › Theme** (the design's four accent colours), **AI › Agents** (the models conch can talk to: one card per agent with a name, a provider — Anthropic, OpenAI, Google, Mistral, Ollama on this Mac, or any OpenAI-compatible endpoint — a model, an API key shown as dots with a Show toggle, and a base URL prefilled per provider; "Make default" stars one, "Remove" asks twice; Tab moves between fields), **AI › MCPs** (soon) and **AI › Features** (what the agents are used for: which agent, if any, gets the commands the shell does not recognise, and the `#` questions (see *Asking the agent*), and the prompt it is given in a multi-line box; blank means the built-in default). Everything is saved to `~/.conch/config.yml`, a small readable YAML file meant to be edited by hand too (a custom `accent: "#RRGGBB"` works from there). |
| Shell | ⌃C / ⌃D / ⌃Z are forwarded, ⌃L or `clear` clears the blocks, `exit` closes the tab, the context line shows the git branch. |
| Full-screen programs | A program that takes over the terminal — by switching to the alternate screen (vim, htop, less, fzf) or by putting the tty in raw mode (Claude Code and other Ink apps, ssh, REPLs) — gets the whole tab: no card, no margins, one cell grid from the top-left corner, until it exits. The emulation is Ghostty's (`term/screen.zig`): alternate screen, scroll regions, wide characters, 256/true colour, cursor shapes, the Kitty keyboard protocol, mouse reporting, bracketed paste, focus events, and the replies to the queries programs make (cursor position, device attributes, colour scheme, size). Keys, ⌃ chords, paste and the mouse go straight to the program; the wheel pages the alternate screen as arrow keys or the main screen's history. Box-drawing and block glyphs are drawn as rectangles so lines meet across cells. What the program printed before it took over becomes the screen's starting content, and what it leaves on the main screen when it exits (Claude Code's transcript, a REPL session) becomes the block's output; a program that leaves nothing gets a one-line note. Tabs show the program's own title while it runs. |

## How it is put together

```
src/
  main.zig                 entry point, CLI flags
  app.zig                  platform-neutral core: layout, event routing, frames
  projects.zig             projects + resources model, persisted to ~/.conch_projects
  config.zig               settings (mode, accent, agents, features), persisted to ~/.conch/config.yml (own YAML subset)
  agent.zig                talking to a configured agent: the request per provider (Anthropic, OpenAI-style, Gemini) with the
                           propose_command tool, the reply and its tool calls streamed back (SSE), NSURLSession underneath
  appearance.zig           which colour scheme to be in: the setting, or macOS's when it says "system"
  objc.zig  apple.zig      Objective-C runtime bridge + C API bindings
  platform/cocoa.zig       NSApplication / NSWindow / CAMetalLayer view, menu, IME
  gfx/
    renderer.zig           Metal: one pipeline, one instanced draw call per frame
                           (+ one per distinct image texture on screen)
    shaders.metal          rounded-rect SDF, atlas-sampled glyphs, textured quads (compiled at startup)
    text.zig               CoreText fonts, glyph fallback, shelf-packed alpha atlas
    icons.zig              SVG path data → CoreGraphics strokes → atlas
    draw.zig               draw list: points in, pixel-snapped instances out, batched by texture
    boxdraw.zig            box-drawing and block glyphs as rectangles that fill their cells
    image.zig              ImageIO / CGPDF → BGRA bitmaps (still images, PDF pages)
    texture.zig            bitmaps → mipmapped Metal textures for the viewers
  ui/                      immediate-mode core, theme tokens (dark, light and e-ink palettes, swapped at runtime),
                           form field widget, sidebar (projects), tab strips
                           (in the titlebar band), command palette, files panel
    panes.zig              the split panes: strips, dividers, focus, tab drag & drop
  tabs/
    tab.zig                the Tab interface, kinds registry (+ which kind opens a file), TabManager
    layout.zig             a group's pane tree: split / remove / resize, rectangles for the UI
    terminal_tab.zig       blocks + input box (dormant until the first ↵ when opened as "New")
    viewer.zig             chrome shared by the document viewers (card, header, notices, scrolling)
    text_editor.zig        the editing surface: coloured mono text, gutter, caret, selection, mouse
    file_tab.zig           FileDoc (load, save atomically, watch the disk) + the text editor tab — the fallback for any file
    markdown_tab.zig       Markdown editor: source (text_editor) ⇄ visual (markdown_view)
    markdown_view.zig      live preview: spans as decorations, wrapped layout, editing in place
    image_tab.zig          image viewer (ImageIO)
    pdf_tab.zig            PDF viewer (CGPDF), pages rendered on demand
    settings_tab.zig       the Settings tab: pages, scrolling, keyboard routing; Mode + Theme pages
    settings_agents.zig    Settings › Agents: the agent cards and the add card
    settings_features.zig  Settings › Features: agent for unrecognised commands + its prompt (soft-wrapping text box)
    web_tab.zig            website tab: a WKWebView hosted over the Metal layer (`Env.host`), the chrome drawn by the app
  term/
    pty.zig                forkpty + non-blocking master
    parser.zig             streaming VT/ANSI tokenizer
    buffer.zig             per-block output model (lines, cells, cursor, SGR)
    session.zig            one shell; slices its output into blocks, hands the terminal over
                           to full-screen programs and takes it back when they exit
    screen.zig             a full-screen program's terminal: libghostty-vt behind a small seam
                           (feed bytes, render state, key/mouse/paste encoding, block ⇄ screen)
    shell_integration.zig  private ZDOTDIR that chains to the user's dotfiles
  input/                   editor model (buffer, caret, selection), history, path suggestions
    document.zig           a file being edited: line index, undo/redo, per-line syntax state, dirty tracking
  syntax/
    lexer.zig              Scope/Span/State, the per-line lexing contract, property tests over every language
    langs.zig              spec-driven engine + the language specs (SQL, JSON, Zig, shell, CSV, Python …)
    markdown.zig           Markdown lexer whose spans double as the visual mode's decorations
  filetype.zig             magic numbers + extensions → which viewer a file gets; language detection
assets/
  fonts/                   Spline Sans + Spline Sans Mono (SIL OFL), embedded in the binary
  shell/conch.zsh          precmd/preexec hooks that emit the block marks
```

### Blocks from a real shell

`conch.zsh` installs two hooks that print invisible marks (the same OSC 133 convention
other terminals use): "output starts" in `preexec`, "finished with status N" plus cwd and
branch in `precmd`. `session.zig` captures only what arrives between those marks, so the
prompt and zsh's line editor never show up — conch has its own input box. The user's
dotfiles are not modified: a private `ZDOTDIR` sources them first and is restored afterwards.

A third hook is zsh's `command_not_found_handler`: it prints one more mark (`OSC 7777;cnf`) before
printing "command not found" and returning 127 (or before handing over to the handler the user's
dotfiles defined, if any). The session flags the block; when the block ends with 127 and an agent is
chosen under Settings › AI › Features, the terminal tab drops the shell's output, marks the block as
the agent's turn and streams the reply into it (`agent.zig`: the provider's request, its SSE events,
NSURLSession underneath — the reply arrives on its own thread and the tab picks it up on its tick).
The request's messages are the tab itself: each shell block becomes part of the transcript the next
question carries (command, last lines of output, exit code), each answered question a user/assistant
turn, oldest first within a budget (`conversation` in terminal_tab.zig). The one tool the agent gets,
`propose_command`, is answered by the app, not by the model loop: the stream's tool call becomes a
proposal, the tab prints `→ cmd` in the block and puts the command — trimmed, no newline — in the
input box for the user to run. Agent blocks are saved with the `g` flag and their reply as `out` lines.

### Editing files

Syntax colouring is one function per language, `lexLine(state, line) → spans, state'`: each
line is lexed on its own from a one-byte *state* (inside a block comment, inside a code
fence …) that the previous line produced. `document.zig` keeps that byte per line, so an
edit re-lexes from the changed line only until the states converge, and the editor lexes
just the lines on screen, every frame, from the stored state. The lexers are byte-oriented,
allocate nothing, never recurse and consume at least one byte per step; a property test in
`lexer.zig` feeds random bytes to every language and checks that they terminate and cover
each line exactly. Adding a language is a spec in `langs.zig` plus its extensions in
`filetype.zig`.

The Markdown visual mode is the same idea one level up: the Markdown lexer's spans are
*decorations* (`.marker` is hidden, `.list` becomes a bullet, `.code` gets the code
background), the source text stays the only truth, and the line under the caret shows its
raw syntax so it can be edited — the model Obsidian's live preview is built on.

### Full-screen programs

`session.zig` keeps its own small parser running for the marks, and decides when a program
owns the terminal: the moment it switches to the alternate screen, or when the tty is found
in raw mode while a command runs (sampled before each read and confirmed only once every
pending byte was read, so zsh's own line editor — which turns raw mode on after writing the
"finished" mark — never counts). From then until the "finished" mark the same bytes also go
to a `Screen`, a libghostty-vt `Terminal` behind `vtStream()`, split exactly at the mark.
The block's captured output seeds the screen first (with the cursor where the block's was,
and the DEC modes the program had already set replayed), so a program that drew its first
frame before it was noticed redraws correctly on the SIGWINCH the resize sends. On exit the
main screen — scrollback included, soft wraps undone — is formatted back as VT bytes and fed
into the block's buffer. The tab draws `RenderState` rows edge to edge and encodes input with
Ghostty's key, mouse, paste and focus encoders, so whatever modes the program set (application
cursor keys, Kitty keyboard flags, SGR mouse …) are honoured.

### Across relaunches

`workspace.zig` writes which tabs are open — pane by pane in reading order, each with its
sidebar resource (named by project root, kind, name and path, since resource ids are handed
out afresh every launch), its pane, its custom title, its directory and whether it was in
front of its pane — and, for a group with several panes, a `layout` record with the pane
tree as `Layout.encode` writes it (`h(0.6000:_,0.4000:v(0.5000:_,0.5000:_))`: direction,
each child's share and subtree, leaves in reading order) and the focused pane — to
`~/.conch_workspace`, and opens them again on the next launch (`restore` runs before the
first frame; a resource that no longer exists sends its tabs to the default set). A kind
takes part by implementing `save(out) bool`, appending whatever it needs in its own
format, and `saveVersion() u64`, which changes whenever `save` would write something
different so the file is only rewritten when needed; what it wrote comes back through
`OpenArgs.saved`. The terminal's format is `term/block_codec.zig`: one `block` record per
finished command (state, exit code, duration, flags, command), a `note` when the block is
a note, and one `out` line per logical line of output, written as the very VT bytes that
would reproduce it (styles as SGR) and read back through the same parser that built it.
Every file uses `records.zig`: tab-separated fields, one record per line, with tabs,
newlines and escape bytes backslash-escaped. Running blocks are skipped; a restored tab's
shell is dormant until it is used. The viewers share `viewer.keep` / `viewer.kept`: one
`file` record with the path, then the kind's own fields — the editor's caret, the Markdown
mode, whether an image was at 1:1, a PDF's page — and a file that no longer exists is not
restored (`error.FileGone`); a website tab keeps its `url`. On restore the `layout` record rebuilds the group's pane
tree first (`Layout.decode`: every child of a split is created as a leaf beside the previous
one, then the shares are set, then each subtree is built inside its leaf), the tabs open
into their panes by place, and a pane none of whose tabs kept anything is dropped.

### Adding a kind of tab

`tabs/tab.zig` defines a tab as pointer + vtable (the shape of `std.mem.Allocator`), built
at comptime from any struct:

```zig
pub const NotebookTab = struct {
    pub const kind_label = "Notebook";
    pub fn create(env: *tab.Env, args: tab.OpenArgs) anyerror!tab.Tab { ... return tab.Tab.from(NotebookTab, self); }
    pub fn deinit(self: *NotebookTab) void { ... }
    pub fn draw(self: *NotebookTab, ui: *Ui, rect: Rect, focused: bool) void { ... }
    // optional: title, status, info, cwd, path, tick, onText, onEdit, onCtrl, copy, paste, wantsClose,
    //           save / saveVersion (what comes back after a relaunch, see below) …
};

// app.zig
self.tabs.register(.{ .name = "notebook", .label = "Notebook", .create = NotebookTab.create });
_ = try self.tabs.openWith("notebook", .{ .path = "/some/file.ipynb" });
```

Only `deinit` and `draw` are required; every other hook has a default. `OpenArgs` carries
what a tab is opened on (a directory, a file, whether to start a shell); `cwd` and `path`
tell the app what a tab is about, which drives the files panel and the sidebar highlights.

### Adding a viewer for another file format

A viewer is a tab kind with one more function, `accepts(path, head)`, that says whether it
wants a file given its path and first kilobyte. `App.openFile` asks the kinds in
registration order and opens the first taker, so the text viewer (which accepts
everything) is registered last:

```zig
pub const NotebookTab = struct {
    pub const kind_label = "Notebook";
    pub fn accepts(path: []const u8, head: []const u8) bool {
        return filetype.hasExtension(path, &.{"ipynb"}) and std.mem.startsWith(u8, head, "{");
    }
    // create / deinit / draw as above; `viewer.zig` has the card + header every viewer shares
};

// app.zig — before the "file" kind
self.tabs.register(.{ .name = "notebook", .label = "Notebook", .create = NotebookTab.create, .accepts = NotebookTab.accepts });
```

Viewers that show pictures decode into a `Bitmap` (`gfx/image.zig`), upload it through
`env.textures` and draw it with `dl.image(rect, texture, tint)`; the draw list splits its
single draw call only where a different texture is needed. `filetype.zig` has the magic
numbers, so a format's signature is written once and shared.

## Testing without clicking around

* `zig build test` — parser, output buffer, editor, history, completion, the tab manager and the pane tree.
* `conch --probe 'ls' 'false'` — runs commands through the real PTY pipeline and prints the blocks.
* `conch --script file` — drives the full app headlessly (real shell, real layout, real Metal
  rendering into a texture) and writes PNG snapshots. Commands are listed in `src/script.zig`
  (`project /dir` and `open /file` stand in for the folder picker and the files panel;
  `action split_right` and `drag X0 Y0 X1 Y1` on a tab title exercise the split panes).
  Scripts and the selftest leave `~/.conch_workspace` alone; `CONCH_WORKSPACE=/some/file`
  makes a run save to and restore from that file instead, so two runs test a relaunch.
* `CONCH_SELFTEST=1 conch` — opens the window and posts genuine `NSEvent`s (clicks under the
  transparent titlebar, key presses through the text input system); `CONCH_DEBUG_EVENTS=1` logs them.
  With `CONCH_SELFTEST_FULLSCREEN=1` it also goes through macOS full screen (about 3s on the real
  screen), lists the process's windows while there and captures the tab strip at screen size.

## Not there yet

Inside a full-screen program there is no text selection or copy yet, ⌥ is not sent as Meta,
and images (Kitty graphics) are not drawn. Pagers stay disabled via `PAGER=cat` so `git log`
and friends land in blocks (run `less` yourself and it takes the tab). zsh only. No drag-selection across blocks, no undo in
the input box, and "Fix with agent" and "Explain" are placeholders. The text
viewer is read-only and has no text selection; the image viewer shows only the first frame
of an animation and has no zoom beyond fit/100%; the PDF viewer has no text selection,
search or zoom. The files panel shows no git status yet. The palette has no file or agent
scopes yet. After a relaunch a file tab shows what is on disk: edits you had not saved are
gone (quitting asks about them first), and a command still running when you quit is not
kept.
