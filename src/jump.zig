//! ⌥ jumps: the keyboard way to the sidebar's rows and their tabs, with
//! keys that never move so they can be learnt. Hold ⌥ and, without letting
//! go of it:
//!
//!   letter   the project with that letter (`Project.key`: handed out once
//!            from its name, kept whatever else changes) — its own tabs
//!   1–9      then that resource of the project, as listed under it
//!   0        …or stay on the project's own tabs
//!   1–9      then that tab of the row on show (reading order, all panes)
//!
//! Each step shows its row at once; letting go of ⌥ ends the chord where
//! it got to (a row with no tabs yet then opens its first one, as a click
//! on it would). Another letter mid-chord starts over on that project.
//! Keys that are not part of a chord go on as typing: ⌥ + a digit first
//! (⌥2 is "@" on Spanish keyboards), ⌥ + a letter no project has.
//!
//! From the moment ⌥ goes down on its own, and all through a chord, the
//! sidebar and the tab strips show the keys on their rows (`hintsVisible`);
//! ⌥ used for typing instead (⌥← by words, ⌥2 for "@") hides them again.
const std = @import("std");
const projects_mod = @import("projects.zig");

/// How long ⌥ has to be held alone before the keys show on the rows: no
/// wait at all (the user's call, 2026-09-30).
pub const hint_delay: f64 = 0;

pub const Stage = enum {
    idle,
    /// A letter picked a project: its own tabs are on show; a digit picks
    /// one of its resources (0: stays on its own tabs).
    project,
    /// A row's tabs are on show; a digit picks one of them.
    group,
};

/// What a key asks the app to do.
pub const Step = union(enum) {
    /// Not a chord key: the key goes on as typing.
    pass,
    /// Part of the chord but nothing to show (a digit with no row or tab).
    none,
    /// Show this group's tabs: a project's own (0: the default project's)
    /// or a resource's.
    show_group: u32,
    /// Focus the n-th tab (0-based, reading order across the panes) of the
    /// group on show.
    tab: usize,
};

pub const Jump = struct {
    stage: Stage = .idle,
    /// The project the chord is on (its group id; 0 for the default one).
    project: u32 = 0,
    /// The group the chord shows now.
    group: u32 = 0,

    /// ⌥ is down on its own (no ⌘ / ⌃ / ⇧ with it), since `alt_since`.
    alt_down: bool = false,
    alt_since: f64 = 0,
    /// A key that is not a chord key was pressed with this ⌥ (⌥← to move
    /// by words, ⌥2 for "@" …): no hints until ⌥ is pressed again.
    alt_used: bool = false,
    /// The hints were drawn for this press of ⌥ (for `tick`).
    hints_shown: bool = false,

    pub fn active(self: *const Jump) bool {
        return self.stage != .idle;
    }

    /// A key typed with ⌥ held: `c` is the key without modifiers (a
    /// lowercase letter or a digit; anything else is 0). A key the chord
    /// does not take is `.pass`.
    pub fn key(self: *Jump, c: u8, projects: *projects_mod.Projects) Step {
        if (std.ascii.isAlphabetic(c)) {
            const gid = projects.byKey(c) orelse {
                // Mid-chord a stray letter is dropped rather than typed.
                if (self.active()) return .none;
                self.alt_used = true;
                return .pass;
            };
            self.stage = .project;
            self.project = gid;
            self.group = gid;
            return .{ .show_group = gid };
        }
        if (std.ascii.isDigit(c) and self.active()) {
            const d = c - '0';
            switch (self.stage) {
                .idle => unreachable,
                .project => {
                    if (d == 0) {
                        self.stage = .group;
                        return .{ .show_group = self.project };
                    }
                    const p: ?*projects_mod.Project = if (self.project == 0) null else (projects.find(self.project) orelse return .none);
                    const list = projects.resourcesOf(p).items;
                    if (d > list.len) return .none;
                    self.stage = .group;
                    self.group = list[d - 1].id;
                    return .{ .show_group = self.group };
                },
                .group => return if (d == 0) .none else .{ .tab = d - 1 },
            }
        }
        if (self.active()) return .none;
        self.alt_used = true;
        return .pass;
    }

    /// The modifiers changed. Returns the group the chord ended on when
    /// this let go of ⌥ during one.
    pub fn flags(self: *Jump, alt: bool, others: bool, now: f64) ?u32 {
        const alone = alt and !others;
        if (alone and !self.alt_down) {
            self.alt_down = true;
            self.alt_since = now;
            self.alt_used = false;
            self.hints_shown = false;
        } else if (!alone and self.alt_down) {
            self.alt_down = false;
        }
        if (!alt and self.active()) {
            self.stage = .idle;
            return self.group;
        }
        return null;
    }

    /// Whether the rows show their keys now.
    pub fn hintsVisible(self: *const Jump, now: f64) bool {
        if (self.active()) return true;
        return self.alt_down and !self.alt_used and now - self.alt_since >= hint_delay;
    }

    /// Per tick: true once, when holding ⌥ has made the hints due (the
    /// frame has to be drawn again to show them).
    pub fn tick(self: *Jump, now: f64) bool {
        if (self.hints_shown or !self.hintsVisible(now)) return false;
        self.hints_shown = true;
        return true;
    }
};

test "jump: letter, resource, tab; digits first and unknown letters pass" {
    var ps = projects_mod.Projects.init(std.testing.allocator);
    defer ps.deinit();
    const cognito = try ps.add("/w/cognito");
    const cid = cognito.id;
    const r1 = (try ps.addShells(cognito, "/w/cognito")).id;
    const r2 = (try ps.addFile(ps.find(cid).?, "/w/cognito/README.md")).id;
    const d1 = (try ps.addShells(null, "/tmp")).id;

    var j: Jump = .{};
    _ = j.flags(true, false, 0);
    // The keys show as soon as ⌥ is down …
    try std.testing.expect(j.hintsVisible(0));
    // … and ⌥2 before any letter is typing ("@" on a Spanish keyboard),
    // which hides them for this press of ⌥.
    try std.testing.expectEqual(Step.pass, j.key('2', &ps));
    try std.testing.expect(!j.hintsVisible(1));
    _ = j.flags(false, false, 1);

    // ⌥C … ⌥2 … ⌥3, then letting go.
    _ = j.flags(true, false, 2);
    try std.testing.expect(j.hintsVisible(2 + hint_delay));
    try std.testing.expectEqual(Step{ .show_group = cid }, j.key('c', &ps));
    try std.testing.expectEqual(Step{ .show_group = r2 }, j.key('2', &ps));
    try std.testing.expectEqual(Step{ .tab = 2 }, j.key('3', &ps));
    try std.testing.expectEqual(Step{ .tab = 0 }, j.key('1', &ps));
    // A stray letter mid-chord is dropped, not typed.
    try std.testing.expectEqual(Step.none, j.key('z', &ps));
    try std.testing.expectEqual(@as(?u32, r2), j.flags(false, false, 3));
    try std.testing.expect(!j.active());

    // ⌥C alone ends on the project; ⌥C0 then a digit picks its own tabs.
    _ = j.flags(true, false, 4);
    _ = j.key('c', &ps);
    try std.testing.expectEqual(@as(?u32, cid), j.flags(false, false, 5));
    _ = j.flags(true, false, 6);
    _ = j.key('c', &ps);
    try std.testing.expectEqual(Step{ .show_group = cid }, j.key('0', &ps));
    try std.testing.expectEqual(Step{ .tab = 1 }, j.key('2', &ps));
    // A resource that is not there keeps the chord where it was.
    _ = j.key('c', &ps);
    try std.testing.expectEqual(Step.none, j.key('9', &ps));
    try std.testing.expectEqual(Step{ .show_group = r1 }, j.key('1', &ps));
    // Another letter starts over: the default project and its resources.
    try std.testing.expectEqual(Step{ .show_group = 0 }, j.key('d', &ps));
    try std.testing.expectEqual(Step{ .show_group = d1 }, j.key('1', &ps));
    try std.testing.expectEqual(@as(?u32, d1), j.flags(false, false, 7));

    // A letter no project has is typing, and so is anything else; after
    // one, holding ⌥ shows no hints until it is pressed again.
    _ = j.flags(true, false, 8);
    try std.testing.expectEqual(Step.pass, j.key('q', &ps));
    try std.testing.expect(!j.hintsVisible(10));
    _ = j.flags(false, false, 10);
    _ = j.flags(true, false, 11);
    try std.testing.expectEqual(Step.pass, j.key(0, &ps));
    try std.testing.expect(!j.hintsVisible(12));

    // ⌥ with ⌘ or ⇧ is not "⌥ alone": no hints; the tick asks for one redraw.
    _ = j.flags(false, false, 13);
    _ = j.flags(true, true, 13);
    try std.testing.expect(!j.hintsVisible(14));
    _ = j.flags(true, false, 15);
    try std.testing.expect(j.tick(15 + hint_delay));
    try std.testing.expect(!j.tick(16));
}
