//! Tells kinds of document apart from a path and the first bytes of the
//! file. Magic numbers win over extensions, so a renamed file still opens
//! in the right viewer; the extension decides when the head says nothing
//! (empty or truncated file) or the format has no reliable signature.
const std = @import("std");

/// Bytes worth reading from the start of a file before deciding.
pub const sniff_bytes: usize = 1024;

/// Extension without the dot ("" for none; dotfiles have none).
pub fn extension(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |i| path[i + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot + 1 ..];
}

pub fn hasExtension(path: []const u8, exts: []const []const u8) bool {
    const ext = extension(path);
    if (ext.len == 0) return false;
    for (exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

// ── images ──────────────────────────────────────────────────────────────
/// What ImageIO decodes on a stock macOS.
pub const image_extensions = [_][]const u8{
    "png",  "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff", "heic", "heif", "avif",
    "webp", "ico", "icns", "psd", "tga", "jp2", "exr", "hdr",  "dng",  "cr2",  "nef",
    "arw",  "raf", "orf",  "rw2", "pbm", "pgm", "ppm", "sgi",  "pict", "ktx",  "astc",
};

pub fn imageMagic(head: []const u8) bool {
    if (starts(head, "\x89PNG\r\n\x1a\n")) return true;
    if (starts(head, "\xFF\xD8\xFF")) return true; // JPEG
    if (starts(head, "GIF87a") or starts(head, "GIF89a")) return true;
    if (starts(head, "II*\x00") or starts(head, "MM\x00*")) return true; // TIFF (and most RAW)
    if (head.len >= 12 and starts(head, "RIFF") and std.mem.eql(u8, head[8..12], "WEBP")) return true;
    if (head.len >= 12 and std.mem.eql(u8, head[4..8], "ftyp")) {
        const brands = [_][]const u8{ "heic", "heix", "hevc", "hevx", "heif", "mif1", "msf1", "avif", "avis" };
        for (brands) |b| {
            if (std.mem.eql(u8, head[8..12], b)) return true;
        }
    }
    // "BM" alone is any text starting with those letters; BMP reserves bytes 6–9 as zero.
    if (head.len >= 14 and starts(head, "BM") and std.mem.allEqual(u8, head[6..10], 0)) return true;
    if (starts(head, "icns")) return true;
    if (starts(head, "8BPS")) return true; // Photoshop
    if (starts(head, "\x00\x00\x00\x0cjP  \r\n\x87\n")) return true; // JPEG 2000
    if (starts(head, "v/1\x01")) return true; // OpenEXR
    if (starts(head, "#?RADIANCE") or starts(head, "#?RGBE")) return true;
    return false;
}

pub fn isImage(path: []const u8, head: []const u8) bool {
    return imageMagic(head) or hasExtension(path, &image_extensions);
}

// ── PDF ─────────────────────────────────────────────────────────────────
pub fn pdfMagic(head: []const u8) bool {
    // The header may follow a little junk (the spec allows up to 1 KB).
    return std.mem.indexOf(u8, head[0..@min(head.len, sniff_bytes)], "%PDF-") != null;
}

pub fn isPdf(path: []const u8, head: []const u8) bool {
    return pdfMagic(head) or hasExtension(path, &.{"pdf"});
}

fn starts(head: []const u8, magic: []const u8) bool {
    return std.mem.startsWith(u8, head, magic);
}

// ── tests ───────────────────────────────────────────────────────────────
test "extension" {
    try std.testing.expectEqualStrings("png", extension("/a/b/photo.png"));
    try std.testing.expectEqualStrings("gz", extension("archive.tar.gz"));
    try std.testing.expectEqualStrings("", extension("/a/b/Makefile"));
    try std.testing.expectEqualStrings("", extension("/a/.zshrc"));
    try std.testing.expectEqualStrings("", extension("/a.b/file"));
    try std.testing.expect(hasExtension("/x/IMG_0001.JPG", &image_extensions));
    try std.testing.expect(!hasExtension("/x/notes.txt", &image_extensions));
}

test "image magic beats extension; extension covers an empty head" {
    try std.testing.expect(isImage("/x/renamed.dat", "\x89PNG\r\n\x1a\n...."));
    try std.testing.expect(isImage("/x/a.jpg", "\xFF\xD8\xFF\xE0"));
    try std.testing.expect(isImage("/x/a.bin", "RIFF\x00\x00\x00\x00WEBPVP8 "));
    try std.testing.expect(isImage("/x/a.bin", "\x00\x00\x00\x18ftypheic\x00\x00"));
    try std.testing.expect(isImage("/x/a.bin", "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00"));
    try std.testing.expect(!isImage("/x/notes.txt", "BMW drivers, please note..."));
    try std.testing.expect(isImage("/x/empty.png", ""));
    try std.testing.expect(!isImage("/x/main.zig", "const std = @import(\"std\");"));
}

test "pdf" {
    try std.testing.expect(isPdf("/x/doc", "%PDF-1.7\n%\xE2\xE3\xCF\xD3"));
    try std.testing.expect(isPdf("/x/doc.bin", "\xEF\xBB\xBFjunk\n%PDF-1.4"));
    try std.testing.expect(isPdf("/x/scan.PDF", ""));
    try std.testing.expect(!isPdf("/x/readme.md", "# PDF notes\n%PDF is the magic"));
}

// ── text languages ──────────────────────────────────────────────────────
/// What a text file is written in, for syntax colouring. Detection never
/// guesses from content beyond a shebang: filename, then extension, then
/// the first line; anything else is plain text.
pub const Language = enum {
    plain,
    markdown,
    sql,
    csv,
    json,
    zig,
    shell,
    python,
    javascript,
    typescript,
    c,
    cpp,
    objc,
    rust,
    go,
    java,
    swift,
    ruby,
    php,
    yaml,
    toml,
    ini,
    make,
    dockerfile,
    lua,
    css,
    html,
    xml,
    diff,

    /// Name shown in the viewer header.
    pub fn label(self: Language) []const u8 {
        return switch (self) {
            .plain => "Text",
            .markdown => "Markdown",
            .sql => "SQL",
            .csv => "CSV",
            .json => "JSON",
            .zig => "Zig",
            .shell => "Shell",
            .python => "Python",
            .javascript => "JavaScript",
            .typescript => "TypeScript",
            .c => "C",
            .cpp => "C++",
            .objc => "Objective-C",
            .rust => "Rust",
            .go => "Go",
            .java => "Java",
            .swift => "Swift",
            .ruby => "Ruby",
            .php => "PHP",
            .yaml => "YAML",
            .toml => "TOML",
            .ini => "INI",
            .make => "Makefile",
            .dockerfile => "Dockerfile",
            .lua => "Lua",
            .css => "CSS",
            .html => "HTML",
            .xml => "XML",
            .diff => "Diff",
        };
    }
};

const lang_by_name = std.StaticStringMap(Language).initComptime(.{
    .{ ".zshrc", .shell },          .{ ".zshenv", .shell },            .{ ".zprofile", .shell },
    .{ ".bashrc", .shell },         .{ ".bash_profile", .shell },      .{ ".profile", .shell },
    .{ "Makefile", .make },         .{ "makefile", .make },            .{ "GNUmakefile", .make },
    .{ "Dockerfile", .dockerfile }, .{ "Containerfile", .dockerfile }, .{ ".gitconfig", .ini },
    .{ ".editorconfig", .ini },     .{ ".npmrc", .ini },               .{ "Gemfile", .ruby },
    .{ "Rakefile", .ruby },         .{ "Podfile", .ruby },             .{ "go.mod", .go },
    .{ "Cargo.lock", .toml },       .{ ".gitignore", .shell },
});

const lang_by_ext = std.StaticStringMap(Language).initComptime(.{
    .{ "md", .markdown },    .{ "markdown", .markdown }, .{ "mdown", .markdown },
    .{ "sql", .sql },        .{ "psql", .sql },          .{ "mysql", .sql },
    .{ "csv", .csv },        .{ "tsv", .csv },           .{ "json", .json },
    .{ "jsonc", .json },     .{ "json5", .json },        .{ "zig", .zig },
    .{ "zon", .zig },        .{ "sh", .shell },          .{ "zsh", .shell },
    .{ "bash", .shell },     .{ "py", .python },         .{ "pyi", .python },
    .{ "pyw", .python },     .{ "js", .javascript },     .{ "mjs", .javascript },
    .{ "cjs", .javascript }, .{ "jsx", .javascript },    .{ "ts", .typescript },
    .{ "tsx", .typescript }, .{ "mts", .typescript },    .{ "cts", .typescript },
    .{ "c", .c },            .{ "h", .c },               .{ "cc", .cpp },
    .{ "cpp", .cpp },        .{ "cxx", .cpp },           .{ "hpp", .cpp },
    .{ "hh", .cpp },         .{ "hxx", .cpp },           .{ "ino", .cpp },
    .{ "m", .objc },         .{ "mm", .objc },           .{ "rs", .rust },
    .{ "go", .go },          .{ "java", .java },         .{ "kt", .java },
    .{ "swift", .swift },    .{ "rb", .ruby },           .{ "rake", .ruby },
    .{ "gemspec", .ruby },   .{ "php", .php },           .{ "phtml", .php },
    .{ "yaml", .yaml },      .{ "yml", .yaml },          .{ "toml", .toml },
    .{ "ini", .ini },        .{ "cfg", .ini },           .{ "conf", .ini },
    .{ "properties", .ini }, .{ "mk", .make },           .{ "make", .make },
    .{ "lua", .lua },        .{ "css", .css },           .{ "scss", .css },
    .{ "less", .css },       .{ "html", .html },         .{ "htm", .html },
    .{ "xhtml", .html },     .{ "vue", .html },          .{ "svelte", .html },
    .{ "xml", .xml },        .{ "svg", .xml },           .{ "plist", .xml },
    .{ "xsl", .xml },        .{ "xsd", .xml },           .{ "storyboard", .xml },
    .{ "xib", .xml },        .{ "diff", .diff },         .{ "patch", .diff },
});

/// Interpreters named on a `#!` line.
const lang_by_shebang = std.StaticStringMap(Language).initComptime(.{
    .{ "sh", .shell },       .{ "zsh", .shell },      .{ "bash", .shell },     .{ "dash", .shell },      .{ "ksh", .shell },
    .{ "python", .python },  .{ "python3", .python }, .{ "python2", .python }, .{ "node", .javascript }, .{ "deno", .javascript },
    .{ "bun", .javascript }, .{ "ruby", .ruby },      .{ "php", .php },        .{ "lua", .lua },
});

pub fn language(path: []const u8, head: []const u8) Language {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |i| path[i + 1 ..] else path;
    if (lang_by_name.get(name)) |l| return l;
    const ext = extension(name);
    if (ext.len > 0 and ext.len <= 16) {
        var buf: [16]u8 = undefined;
        if (lang_by_ext.get(std.ascii.lowerString(&buf, ext))) |l| return l;
    }
    return shebangLanguage(head) orelse .plain;
}

fn shebangLanguage(head: []const u8) ?Language {
    if (!std.mem.startsWith(u8, head, "#!")) return null;
    const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    var it = std.mem.tokenizeAny(u8, head[2..nl], " \t\r");
    var interp = it.next() orelse return null;
    // "#!/usr/bin/env zsh" names the interpreter second.
    if (std.mem.endsWith(u8, interp, "/env")) interp = it.next() orelse return null;
    const base = if (std.mem.lastIndexOfScalar(u8, interp, '/')) |i| interp[i + 1 ..] else interp;
    return lang_by_shebang.get(base);
}

test "language: filename, extension, shebang, plain" {
    try std.testing.expectEqual(Language.shell, language("/home/x/.zshrc", ""));
    try std.testing.expectEqual(Language.sql, language("/x/schema.SQL", ""));
    try std.testing.expectEqual(Language.csv, language("data.tsv", ""));
    try std.testing.expectEqual(Language.markdown, language("/x/README.md", ""));
    try std.testing.expectEqual(Language.shell, language("/x/deploy", "#!/usr/bin/env bash\necho hi"));
    try std.testing.expectEqual(Language.shell, language("/x/deploy", "#!/bin/sh"));
    try std.testing.expectEqual(Language.python, language("/x/notes", "#!/usr/bin/env python3"));
    try std.testing.expectEqual(Language.plain, language("/x/notes", "#!/usr/bin/perl"));
    try std.testing.expectEqual(Language.plain, language("/x/notes.txt", "SELECT 1;"));
    try std.testing.expectEqual(Language.make, language("/x/Makefile", ""));
    try std.testing.expectEqual(Language.dockerfile, language("/x/Dockerfile", ""));
    try std.testing.expectEqual(Language.cpp, language("/x/a.HPP", ""));
    try std.testing.expectEqual(Language.objc, language("/x/View.m", ""));
    try std.testing.expectEqual(Language.typescript, language("/x/app.tsx", ""));
    try std.testing.expectEqual(Language.xml, language("/x/Info.plist", ""));
    try std.testing.expectEqual(Language.diff, language("/x/fix.patch", ""));
    try std.testing.expectEqual(Language.ini, language("/x/.gitconfig", ""));
    try std.testing.expectEqual(Language.plain, language("/x/CMakeLists.txt", ""));
}
