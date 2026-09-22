//! Streaming VT/ANSI parser. It only tokenises: the handler decides what each
//! sequence means. State survives across `feed` calls, so sequences and UTF-8
//! characters split between reads are handled correctly.
const std = @import("std");

pub const max_params = 24;

pub const Csi = struct {
    /// Private marker byte ('?', '>', '=', '<') or 0.
    private: u8,
    params: []const u16,
    intermediate: u8,
    final: u8,

    /// Parameter `i`, or `default` when absent or zero.
    pub fn param(self: Csi, i: usize, default: u16) u16 {
        if (i >= self.params.len or self.params[i] == 0) return default;
        return self.params[i];
    }
};

pub const Parser = struct {
    state: State = .ground,
    params: [max_params]u16 = [_]u16{0} ** max_params,
    nparams: usize = 0,
    param_open: bool = false,
    private: u8 = 0,
    intermediate: u8 = 0,
    osc: [2048]u8 = undefined,
    osc_len: usize = 0,
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,

    const State = enum { ground, escape, escape_intermediate, csi, osc, osc_esc, string, string_esc };

    /// `handler` needs: print(u21), execute(u8), csi(Csi), osc([]const u8), esc(u8, u8).
    pub fn feed(self: *Parser, bytes: []const u8, handler: anytype) void {
        for (bytes) |b| self.step(b, handler);
    }

    /// One byte; `feed` is a loop over this.
    pub fn step(self: *Parser, b: u8, handler: anytype) void {
        switch (self.state) {
            .ground => self.ground(b, handler),
            .escape => switch (b) {
                '[' => {
                    self.nparams = 0;
                    self.param_open = false;
                    self.private = 0;
                    self.intermediate = 0;
                    @memset(&self.params, 0);
                    self.state = .csi;
                },
                ']' => {
                    self.osc_len = 0;
                    self.state = .osc;
                },
                'P', 'X', '^', '_' => self.state = .string,
                0x20...0x2F => {
                    self.intermediate = b;
                    self.state = .escape_intermediate;
                },
                0x1B => {},
                0x18, 0x1A => self.state = .ground,
                else => {
                    self.state = .ground;
                    if (b >= 0x30 and b <= 0x7E) handler.esc(0, b);
                },
            },
            .escape_intermediate => switch (b) {
                0x20...0x2F => {},
                0x1B => self.state = .escape,
                else => {
                    self.state = .ground;
                    if (b >= 0x30 and b <= 0x7E) handler.esc(self.intermediate, b);
                },
            },
            .csi => switch (b) {
                '0'...'9' => {
                    if (!self.param_open) {
                        self.param_open = true;
                        if (self.nparams < max_params) self.nparams += 1;
                    }
                    const i = self.nparams - 1;
                    self.params[i] = self.params[i] *| 10 +| (b - '0');
                },
                ';', ':' => {
                    if (!self.param_open and self.nparams < max_params) self.nparams += 1;
                    self.param_open = false;
                },
                '<', '=', '>', '?' => self.private = b,
                0x20...0x2F => self.intermediate = b,
                0x40...0x7E => {
                    self.state = .ground;
                    handler.csi(.{
                        .private = self.private,
                        .params = self.params[0..self.nparams],
                        .intermediate = self.intermediate,
                        .final = b,
                    });
                },
                0x1B => self.state = .escape,
                0x18, 0x1A => self.state = .ground,
                // C0 controls inside a CSI are executed immediately.
                0x07...0x0D => handler.execute(b),
                else => {},
            },
            .osc => switch (b) {
                0x07 => {
                    self.state = .ground;
                    handler.osc(self.osc[0..self.osc_len]);
                },
                0x1B => self.state = .osc_esc,
                0x18, 0x1A => self.state = .ground,
                else => if (self.osc_len < self.osc.len) {
                    self.osc[self.osc_len] = b;
                    self.osc_len += 1;
                },
            },
            .osc_esc => {
                // ESC \ terminates; anything else starts a new escape sequence.
                handler.osc(self.osc[0..self.osc_len]);
                self.state = .ground;
                if (b != '\\') {
                    self.state = .escape;
                    self.step(b, handler);
                }
            },
            .string => switch (b) {
                0x1B => self.state = .string_esc,
                0x07, 0x18, 0x1A => self.state = .ground,
                else => {},
            },
            .string_esc => {
                self.state = if (b == '\\') .ground else .string;
            },
        }
    }

    fn ground(self: *Parser, b: u8, handler: anytype) void {
        if (self.utf8_need > 0) {
            if (b & 0xC0 == 0x80) {
                self.utf8_buf[self.utf8_len] = b;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch 0xFFFD;
                    self.utf8_need = 0;
                    self.utf8_len = 0;
                    handler.print(cp);
                }
                return;
            }
            // Broken sequence: emit a replacement and reprocess this byte.
            self.utf8_need = 0;
            self.utf8_len = 0;
            handler.print(0xFFFD);
        }
        switch (b) {
            0x1B => self.state = .escape,
            0x00...0x1A, 0x1C...0x1F => handler.execute(b),
            0x20...0x7E => handler.print(b),
            0x7F => {},
            0x80...0xBF, 0xF8...0xFF => handler.print(0xFFFD),
            0xC0...0xDF => self.beginUtf8(b, 2),
            0xE0...0xEF => self.beginUtf8(b, 3),
            0xF0...0xF7 => self.beginUtf8(b, 4),
        }
    }

    fn beginUtf8(self: *Parser, b: u8, need: u3) void {
        self.utf8_buf[0] = b;
        self.utf8_len = 1;
        self.utf8_need = need;
    }
};

// ── tests ────────────────────────────────────────────────────────────────
const TestHandler = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn print(self: *TestHandler, cp: u21) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        self.out.appendSlice(self.gpa, buf[0..n]) catch {};
    }
    fn execute(self: *TestHandler, c: u8) void {
        self.out.print(self.gpa, "<{x}>", .{c}) catch {};
    }
    fn csi(self: *TestHandler, c: Csi) void {
        self.out.print(self.gpa, "[CSI {c}", .{c.final}) catch {};
        if (c.private != 0) self.out.print(self.gpa, " p{c}", .{c.private}) catch {};
        for (c.params) |p| self.out.print(self.gpa, " {d}", .{p}) catch {};
        self.out.append(self.gpa, ']') catch {};
    }
    fn osc(self: *TestHandler, data: []const u8) void {
        self.out.print(self.gpa, "[OSC {s}]", .{data}) catch {};
    }
    fn esc(self: *TestHandler, inter: u8, final: u8) void {
        self.out.print(self.gpa, "[ESC {d} {c}]", .{ inter, final }) catch {};
    }
};

fn expectParse(chunks: []const []const u8, expected: []const u8) !void {
    var h = TestHandler{ .gpa = std.testing.allocator };
    defer h.out.deinit(std.testing.allocator);
    var p = Parser{};
    for (chunks) |chunk| p.feed(chunk, &h);
    try std.testing.expectEqualStrings(expected, h.out.items);
}

test "plain text and controls" {
    try expectParse(&.{"hi\r\n"}, "hi<d><a>");
}

test "sgr and private csi" {
    try expectParse(&.{"\x1b[1;31mX\x1b[0m\x1b[?2004h"}, "[CSI m 1 31]X[CSI m 0][CSI h p? 2004]");
}

test "empty params keep their position" {
    try expectParse(&.{"\x1b[;5H\x1b[m"}, "[CSI H 0 5][CSI m]");
}

test "osc with BEL and ST, split across reads" {
    try expectParse(&.{ "\x1b]133;D", ";0\x07a\x1b]7777;cwd;/tmp\x1b", "\\b" }, "[OSC 133;D;0]a[OSC 7777;cwd;/tmp]b");
}

test "utf8 split across reads" {
    try expectParse(&.{ "\xe2\x9c", "\x93 ok" }, "✓ ok");
}

test "dcs is swallowed, charset designation is an esc" {
    try expectParse(&.{"\x1bPq#0;2\x1b\\A\x1b(B"}, "A[ESC 40 B]");
}
