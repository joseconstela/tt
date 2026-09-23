//! Text files: the editor tab. What opens when a file is clicked in the files
//! panel or in a project, unless a more specific viewer claims it (images,
//! PDF, Markdown). It is the fallback kind — it accepts any path — so it must
//! be registered after the viewers for specific formats.
//!
//! `FileDoc` is the part every text-editing tab shares: loading, the syntax
//! language, saving atomically, watching the file on disk and the wording
//! of the context line. `FileTab` is that plus the plain code editor.
const std = @import("std");
const tab_mod = @import("tab.zig");
const viewer = @import("viewer.zig");
const ui_mod = @import("../ui/ui.zig");
const theme = @import("../ui/theme.zig");
const filetype = @import("../filetype.zig");
const EditCommand = @import("../events.zig").EditCommand;
const sys = @import("../sys.zig");
const TextEditor = @import("text_editor.zig").TextEditor;

const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

/// Files beyond this open read-only, showing only the first part: a save
/// from a truncated buffer would silently drop the rest of the file.
pub const max_bytes: usize = 10 * 1024 * 1024;
/// How often an active tab checks whether the file changed on disk.
const disk_check_every: f64 = 2.0;
const saved_flash: f64 = 1.6;

var next_salt: usize = 1;

pub const FileDoc = struct {
    gpa: std.mem.Allocator,
    file_path: []u8,
    ed: TextEditor,
    lang: filetype.Language = .plain,
    total_size: usize = 0,
    state: enum { ok, failed, binary, too_big } = .ok,
    writable: bool = true,
    disk_mtime: i128 = 0,
    disk_changed: bool = false,
    missing: bool = false,
    save_failed: bool = false,
    /// Set by a save; `tick` turns it into a short "Saved" in the context line.
    just_saved: bool = false,
    saved_at: f64 = -1e9,
    last_check: f64 = 0,
    now: f64 = 0,

    pub fn init(gpa: std.mem.Allocator, path: []const u8) !FileDoc {
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        const salt = next_salt;
        next_salt += 1;
        var self: FileDoc = .{ .gpa = gpa, .file_path = owned, .ed = TextEditor.init(gpa, salt) };
        self.load();
        return self;
    }

    pub fn deinit(self: *FileDoc) void {
        self.ed.deinit();
        self.gpa.free(self.file_path);
    }

    /// The file was renamed or moved on disk: saves go to the new place.
    pub fn relocate(self: *FileDoc, path: []const u8) void {
        const copy = self.gpa.dupe(u8, path) catch return;
        self.gpa.free(self.file_path);
        self.file_path = copy;
    }

    fn load(self: *FileDoc) void {
        const head = sys.readFileHead(self.gpa, self.file_path, max_bytes) catch {
            self.state = .failed;
            self.ed.read_only = true;
            return;
        };
        defer if (head.data.len > 0) self.gpa.free(head.data);
        self.total_size = head.total;
        if (std.mem.indexOfScalar(u8, head.data, 0) != null) {
            self.state = .binary;
            self.ed.read_only = true;
            return;
        }
        self.state = if (head.total > max_bytes) .too_big else .ok;
        self.lang = filetype.language(self.file_path, head.data);
        self.ed.load(head.data, self.lang) catch {
            self.state = .failed;
        };
        self.writable = sys.isWritable(self.gpa, self.file_path);
        self.ed.read_only = self.state != .ok or !self.writable;
        if (sys.statFile(self.gpa, self.file_path)) |st| self.disk_mtime = st.mtime_ns;
        self.disk_changed = false;
        self.missing = false;
    }

    /// Re-reads a file that changed under a clean buffer, keeping the view.
    fn reload(self: *FileDoc) void {
        const cursor = self.ed.doc.editor.cursor;
        const scroll = self.ed.scroll;
        self.load();
        self.ed.doc.editor.setCursor(cursor, false);
        self.ed.scroll = scroll;
    }

    // ── across relaunches ───────────────────────────────────────────────
    /// The caret's byte offset, as a field for `viewer.keep`.
    pub fn caretField(self: *const FileDoc, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.ed.caretOffset()}) catch "";
    }

    /// Puts the caret back where a saved field says it was.
    pub fn restoreCaret(self: *FileDoc, field: ?[]const u8) void {
        const offset = std.fmt.parseInt(usize, field orelse return, 10) catch return;
        self.ed.placeCaret(offset);
    }

    pub fn editable(self: *const FileDoc) bool {
        return self.state == .ok and self.writable;
    }

    pub fn modified(self: *const FileDoc) bool {
        return self.ed.doc.modified();
    }

    pub fn save(self: *FileDoc) bool {
        if (!self.editable()) return false;
        const data = self.ed.doc.serialize(self.gpa) catch return false;
        defer self.gpa.free(data);
        sys.writeFileAtomic(self.gpa, self.file_path, data) catch {
            self.save_failed = true;
            return false;
        };
        self.save_failed = false;
        self.ed.doc.markSaved();
        if (sys.statFile(self.gpa, self.file_path)) |st| {
            self.disk_mtime = st.mtime_ns;
            self.total_size = st.size;
        }
        self.disk_changed = false;
        self.missing = false;
        self.just_saved = true;
        return true;
    }

    /// What closing the tab would throw away, for the confirm box.
    pub fn closeWarning(self: *const FileDoc) ?[]const u8 {
        return if (self.modified()) "Unsaved changes will be lost." else null;
    }

    pub fn command(self: *FileDoc, cmd: tab_mod.Command) bool {
        return switch (cmd) {
            .save => self.save(),
            .undo => self.ed.undo(),
            .redo => self.ed.redo(),
            else => false,
        };
    }

    /// Blink and the disk watch; true when a redraw is needed.
    pub fn tick(self: *FileDoc, now: f64, active: bool) bool {
        self.now = now;
        var dirty = self.ed.tick(now, active);
        if (self.just_saved) {
            self.just_saved = false;
            self.saved_at = now;
            dirty = true;
        } else if (now - self.saved_at < saved_flash + 0.1 and now - self.saved_at > saved_flash) {
            dirty = true; // the flash ends
        }
        if (active and now - self.last_check > disk_check_every and self.state != .failed) {
            self.last_check = now;
            if (self.checkDisk()) dirty = true;
        }
        return dirty;
    }

    fn checkDisk(self: *FileDoc) bool {
        const st = sys.statFile(self.gpa, self.file_path) orelse {
            const was = self.missing;
            self.missing = true;
            return !was;
        };
        if (st.mtime_ns == self.disk_mtime and !self.missing) return false;
        self.missing = false;
        self.disk_mtime = st.mtime_ns;
        if (self.modified()) {
            self.disk_changed = true;
        } else {
            self.reload();
        }
        return true;
    }

    pub fn status(self: *const FileDoc) tab_mod.Status {
        return if (self.modified()) .attention else .none;
    }

    /// "SQL  ·  4 KB  ·  Read-only": the context line at the right of the
    /// tab strip — the kind, the size and the state (uses `buf`). The name
    /// is the tab's title; the path is not shown.
    pub fn info(self: *const FileDoc, buf: []u8) []const u8 {
        var size_buf: [32]u8 = undefined;
        const size = viewer.formatSize(self.total_size, &size_buf);
        return switch (self.state) {
            .failed => "Could not read this file",
            .binary => std.fmt.bufPrint(buf, "Binary  ·  {s}", .{size}) catch "Binary",
            else => std.fmt.bufPrint(buf, "{s}  ·  {s}{s}", .{ self.lang.label(), size, self.suffix() }) catch "",
        };
    }

    fn suffix(self: *const FileDoc) []const u8 {
        if (self.save_failed) return "  ·  Save failed";
        if (self.disk_changed) return "  ·  Changed on disk";
        if (self.missing) return "  ·  Deleted on disk";
        if (self.now - self.saved_at < saved_flash) return "  ·  Saved";
        if (self.modified()) return "  ·  Modified";
        if (self.state == .too_big) return "  ·  Read-only, first 10 MB"; // keep in step with max_bytes
        if (!self.writable) return "  ·  Read-only";
        return "";
    }

    /// The body and the notices that replace an editor. Returns the body
    /// to draw into, or null when a notice was shown instead.
    pub fn frame(self: *const FileDoc, ui: *Ui, rect: Rect) ?Rect {
        const body = viewer.frame(ui, rect);
        const notice: ?[]const u8 = switch (self.state) {
            .failed => "The file could not be opened.",
            .binary => "This is a binary file; there is nothing to show as text.",
            else => null,
        };
        if (notice) |msg| {
            viewer.notice(ui, body, msg);
            return null;
        }
        return body;
    }
};

pub const FileTab = struct {
    pub const kind_label = "File";

    gpa: std.mem.Allocator,
    file: FileDoc,

    /// Anything: the text editor is where files land when no other kind wants them.
    pub fn accepts(_: []const u8, _: []const u8) bool {
        return true;
    }

    pub fn create(env: *tab_mod.Env, args: tab_mod.OpenArgs) anyerror!tab_mod.Tab {
        var kept = try viewer.kept(env.gpa, args.saved);
        defer if (kept) |*k| k.deinit(env.gpa);
        const file_path = args.path orelse if (kept) |k| k.path else return error.MissingPath;
        const self = try env.gpa.create(FileTab);
        errdefer env.gpa.destroy(self);
        self.* = .{ .gpa = env.gpa, .file = try FileDoc.init(env.gpa, file_path) };
        if (kept) |k| self.file.restoreCaret(k.field(0));
        return tab_mod.Tab.from(FileTab, self);
    }

    pub fn deinit(self: *FileTab) void {
        self.file.deinit();
        self.gpa.destroy(self);
    }

    // ── tab interface ───────────────────────────────────────────────────
    pub fn title(self: *FileTab, _: []u8) []const u8 {
        return sys.basename(self.file.file_path);
    }

    pub fn path(self: *FileTab) []const u8 {
        return self.file.file_path;
    }

    pub fn relocate(self: *FileTab, new_path: []const u8) void {
        self.file.relocate(new_path);
    }

    pub fn cwd(self: *FileTab) []const u8 {
        return sys.dirname(self.file.file_path);
    }

    pub fn status(self: *FileTab) tab_mod.Status {
        return self.file.status();
    }

    pub fn info(self: *FileTab, buf: []u8) []const u8 {
        return self.file.info(buf);
    }

    pub fn tick(self: *FileTab, now: f64, active: bool) bool {
        return self.file.tick(now, active);
    }

    pub fn onText(self: *FileTab, utf8: []const u8) void {
        self.file.ed.onText(utf8);
    }

    pub fn onMarkedText(self: *FileTab, utf8: []const u8) void {
        self.file.ed.onMarkedText(utf8);
    }

    pub fn onEdit(self: *FileTab, cmd: EditCommand) void {
        self.file.ed.onEdit(cmd);
    }

    pub fn copy(self: *FileTab, out: *std.ArrayList(u8), cut: bool) bool {
        return self.file.ed.copy(out, cut);
    }

    pub fn paste(self: *FileTab, utf8: []const u8) void {
        self.file.ed.paste(utf8);
    }

    pub fn hasMarkedText(self: *FileTab) bool {
        return self.file.ed.hasMarkedText();
    }

    pub fn caretRect(self: *FileTab) Rect {
        return self.file.ed.caret;
    }

    pub fn selectSpan(self: *FileTab, line: u32, col: u32, len: u32) void {
        self.file.ed.selectSpan(line, col, len);
    }

    pub fn command(self: *FileTab, cmd: tab_mod.Command) bool {
        return self.file.command(cmd);
    }

    pub fn position(self: *FileTab) ?tab_mod.Position {
        return self.file.ed.position();
    }

    pub fn goTo(self: *FileTab, line: usize, col: usize) bool {
        self.file.ed.goTo(line, col);
        return true;
    }

    pub fn closeWarning(self: *FileTab, _: []u8) ?[]const u8 {
        return self.file.closeWarning();
    }

    // ── drawing ─────────────────────────────────────────────────────────
    // ── across relaunches ───────────────────────────────────────────────
    /// The file and the caret; the text itself is read again from disk.
    pub fn save(self: *FileTab, out: *std.ArrayList(u8)) bool {
        var buf: [32]u8 = undefined;
        return viewer.keep(out, self.gpa, self.file.file_path, self.file.caretField(&buf));
    }

    pub fn saveVersion(self: *FileTab) u64 {
        var buf: [32]u8 = undefined;
        return viewer.keptVersion(self.file.file_path, self.file.caretField(&buf));
    }

    pub fn draw(self: *FileTab, ui: *Ui, rect: Rect, focused: bool) void {
        const body = self.file.frame(ui, rect) orelse return;
        self.file.ed.draw(ui, body, focused);
    }
};
