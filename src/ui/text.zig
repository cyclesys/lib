const std = @import("std");
const hb = @import("harfbuzz");
const ft = @import("freetype");
const kf = @import("known_folders");
const bidi = @import("text/bidi.zig");
const LineBreak = @import("text/LineBreak.zig");
const Script = @import("text/ucd/Script.zig");
const ucd = @import("text/ucd.zig");

pub const FontCache = struct {
    allocator: std.mem.Allocator,
    lib: ft.Library,
    face: ft.Face,
    font: hb.Font,

    pub const Key = union(enum) {
        index: u32,
        size: f16,
    };

    pub fn init(allocator: std.mem.Allocator) !FontCache {
        const fonts_path = if (try kf.getPath(allocator, .fonts)) |path| path else {
            return error.NoFontsFolder;
        };
        defer allocator.free(fonts_path);

        const face_path = try std.fs.path.joinZ(allocator, &.{ fonts_path, "segoeui.ttf" });
        defer allocator.free(face_path);

        const lib = try ft.Library.init();
        const face = try lib.createFace(@ptrCast(face_path), 0);
        const font = hb.Font.init(hb.Face.fromFreetypeFace(face));

        return FontCache{
            .allocator = allocator,
            .lib = lib,
            .face = face,
            .font = font,
        };
    }

    pub fn deinit(self: FontCache) void {
        self.font.deinit();
        self.face.deinit();
        self.lib.deinit();
    }
};

// The final product of a `TextBuffer`.
pub const ShapedText = struct {
    allocator: std.mem.Allocator,
    glyphs: []const Glyph,
    lines: []const Line,

    pub const Glyph = struct {
        font: struct {
            index: u32,
            size: f16,
        },
        x: u32,
        y: u32,
    };

    pub const Line = struct {
        start: usize,
        ascent: f32,
        descent: f32,
        paragraph_start: bool,
    };

    pub fn deinit(self: ShapedText) void {
        self.allocator.free(self.paragraphs);
        self.allocator.free(self.lines);
        self.allocator.free(self.glyphs);
    }
};

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    fonts: *FontCache,
    paragraphs: std.ArrayList(Paragraph),

    const Paragraph = struct {
        start: usize,
        chars: std.ArrayList(u32),
        level: bidi.Level,
        levels: []const bidi.Level,
        glyphs: std.ArrayList(Glyph),

        fn deinit(self: *Paragraph) void {
            self.lines.deinit();
            self.breaks.deinit();
            self.glyphs.deinit();
        }
    };

    const Glyph = struct {
        index: u32,
        cluster: usize,
        next_cluster: ?usize,
        x_advance: f32,
        y_advance: f32,
        x_offset: f32,
        y_offset: f32,
        ascent: f32,
        descent: f32,

        fn new(upem: f32, ascent: f32, descent: f32, info: hb.GlyphInfo, pos: hb.Position) Glyph {
            const x_advance: f32 = @floatFromInt(pos.x_advance);
            const y_advance: f32 = @floatFromInt(pos.y_advance);
            const x_offset: f32 = @floatFromInt(pos.x_offset);
            const y_offset: f32 = @floatFromInt(pos.y_offset);
            return Glyph{
                .index = info.codepoint,
                .cluster = info.cluster,
                .next_cluster = null,
                .x_advance = x_advance / upem,
                .y_advance = y_advance / upem,
                .x_offset = x_offset / upem,
                .y_offset = y_offset / upem,
                .ascent = ascent / upem,
                .descent = descent / upem,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, fonts: *FontCache) !TextBuffer {
        return TextBuffer{
            .allocator = allocator,
            .fonts = fonts,
            .paragraphs = std.ArrayList(Paragraph).init(allocator),
        };
    }

    pub fn deinit(self: *TextBuffer) void {
        if (self.paragraphs) |pg| {
            pg.deinit();
        }
        self.paragraphs.deinit();
    }

    pub fn setText(self: *TextBuffer, chars: []const u32) !void {
        for (self.paragraphs.items) |pg| {
            pg.deinit();
        }
        self.paragraphs.clearRetainingCapacity();

        const cats = try bidi.charCats(self.allocator, chars);
        defer self.allocator.free(cats);

        const buffer = hb.Buffer.init().?;
        defer buffer.deinit();

        var pg_iter = bidi.ParagraphIterator.init(cats);
        while (pg_iter.hasNext()) {
            const pg_start = pg_iter.i;
            const pg_level = pg_iter.next();
            const pg_end = pg_iter.i;

            const pg_chars = chars[pg_start..pg_end];
            const pg_cats = cats[pg_start..pg_end];

            const levels = try bidi.resolve(self.allocator, pg_chars, pg_cats, pg_level);
            var glyphs = try std.ArrayList(Glyph).initCapacity(self.allocator, levels.len);

            var shape_start: usize = 0;
            var prev_script = ucd.trieValue(Script, pg_chars[0]);
            var prev_level = levels[0];
            for (pg_chars[1..], 1..) |c, i| {
                const script = ucd.trieValue(Script, c);
                const level = levels[i];
                if (prev_script == script and prev_level == level) {
                    continue;
                }

                self.shapeSegment(buffer, prev_script, prev_level, pg_chars, shape_start, i);
                try self.addGlyphs(&glyphs, prev_level, buffer);

                shape_start = i;
                prev_script = script;
                prev_level = level;
            }
            self.shapeSegment(buffer, prev_script, prev_level, pg_chars, shape_start, pg_chars.len);
            try self.addGlyphs(&glyphs, prev_level, buffer);

            var rev_i: usize = glyphs.items.len;
            while (rev_i > 1) {
                rev_i -= 1;
                const glyph = glyphs.items[rev_i];
                const prev_glyph = glyphs.items[rev_i - 1];
                if (prev_glyph.cluster == glyph.cluster) {
                    prev_glyph.next_cluster = glyph.next_cluster;
                } else {
                    prev_glyph.next_cluster = glyph.cluster;
                }
            }

            try self.paragraphs.append(Paragraph{
                .start = pg_start,
                .level = pg_level,
                .levels = levels,
                .glyphs = glyphs,
            });
        }
    }

    fn shapeSegment(
        self: *TextBuffer,
        buffer: hb.Buffer,
        script: Script.Value,
        level: bidi.Level,
        chars: []const u32,
        start: usize,
        end: usize,
    ) void {
        buffer.clearContents();
        buffer.addUTF32(chars, start, end - start);
        buffer.setScript(ucdScriptToHarfbuzzScript(script));
        buffer.setDirection(if (level % 2 == 0) .ltr else .rtl);
        buffer.guessSegmentProps();
        self.fonts.font.shape(buffer, null);
    }

    fn addGlyphs(self: *TextBuffer, glyphs: *std.ArrayList(Glyph), prev_level: bidi.Level, buffer: hb.Buffer) !void {
        const upem: f32 = @floatFromInt(self.fonts.face.unitsPerEM());

        const ascent: f32 = self.fonts.face.ascender();
        const descent: f32 = self.fonts.face.descender();

        // check if we shaped a ltr segment
        if (prev_level % 2 == 0) {
            const infos = buffer.getGlyphInfos();
            const positions = buffer.getGlyphPositions().?;
            std.debug.assert(infos.len == positions.len);

            // ltr segments can be added as is
            for (infos, positions) |info, pos| {
                try glyphs.append(Glyph.new(upem, ascent, descent, info, pos));
            }
        } else {
            const infos = buffer.getGlyphInfos();
            const positions = buffer.getGlyphPositions().?;
            std.debug.assert(infos.len == positions.len);

            // harfbuzz reverses rtl segments so we have to unreverse them
            var rev_i: usize = infos.len;
            while (rev_i > 0) {
                rev_i -= 1;
                const info = infos[rev_i];
                const pos = positions[rev_i];
                try glyphs.append(Glyph.new(upem, ascent, descent, info, pos));
            }
        }
    }

    pub fn layout(
        self: *TextBuffer,
        font_size: f16,
        max_width: f32,
    ) !ShapedText {
        var shaped_glyphs = std.ArrayList(ShapedText.Glyph).init(self.allocator);
        var shaped_lines = std.ArrayList(ShapedText.Line).init(self.allocator);

        var line_cats = std.ArrayList(bidi.BidiCat).init(self.allocator);
        defer line_cats.deinit();

        var line_levels = std.ArrayList(bidi.Level).init(self.allocator);
        defer line_levels.deinit();

        outer: for (self.paragraphs.items) |pg| {
            try shaped_glyphs.ensureUnusedCapacity(pg.glyphs.items.len);

            var first_line = true;

            var line_start: usize = 0;
            var line_width: f32 = 0;
            var line_ascent: f32 = 0;
            var line_descent: f32 = 0;

            var glyph_i: usize = 0;
            var line_breaks = LineBreak.init(pg.chars.items);
            while (line_breaks.next()) |lb| {
                const start_i = glyph_i;
                const start_width = line_width;

                var cluster_ascent: f32 = 0;
                var cluster_descent: f32 = 0;
                for (pg.glyphs.items[glyph_i..]) |glyph| {
                    if (glyph.cluster > lb.i) {
                        break;
                    }
                    glyph_i += 1;
                    line_width += glyph.x_advance * font_size;
                    cluster_ascent = @max(cluster_ascent, glyph.ascent);
                    cluster_descent = @max(cluster_descent, glyph.descent);

                    try line_cats.append(bidi.charCat(pg.chars.items[glyph.cluster]));
                    try line_levels.append(pg.levels[glyph.cluster]);
                }

                if (line_width > max_width) {
                    if (start_width == 0) {
                        break :outer;
                    }

                    try self.addShapedLine(
                        &shaped_glyphs,
                        &shaped_lines,
                        pg,
                        line_start,
                        line_ascent,
                        line_descent,
                        first_line,
                        line_cats.items[0..start_i],
                        line_levels.items[0..start_i],
                        font_size,
                    );

                    const cluster_width = line_width - start_width;
                    if (cluster_width > max_width) {
                        break :outer;
                    }

                    line_cats.clearRetainingCapacity();
                    line_levels.clearRetainingCapacity();

                    first_line = false;
                    line_start = start_i;
                    line_width = cluster_width;
                    line_ascent = cluster_ascent;
                    line_descent = cluster_descent;
                } else {
                    line_ascent = @max(line_ascent, cluster_ascent);
                    line_descent = @max(line_descent, cluster_descent);
                }
            }

            if (line_width > 0) {
                try self.addShapedLine(
                    &shaped_glyphs,
                    &shaped_lines,
                    pg,
                    line_start,
                    line_ascent,
                    line_descent,
                    first_line,
                    line_cats.items,
                    line_levels.items,
                    font_size,
                );
            }
        }

        return ShapedText{
            .allocator = self.allocator,
            .glyphs = try shaped_glyphs.toOwnedSlice(),
            .lines = try shaped_lines.toOwnedSlice(),
        };
    }

    fn addShapedLine(
        self: *TextBuffer,
        shaped_glyphs: *std.ArrayList(ShapedText.Glyph),
        shaped_lines: *std.ArrayList(ShapedText.Line),
        pg: Paragraph,
        line_start: usize,
        line_ascent: f32,
        line_descent: f32,
        first_line: bool,
        line_cats: []const bidi.BidiCat,
        line_levels: []const bidi.Level,
        font_size: f16,
    ) !void {
        const order = try bidi.reorder(
            self.allocator,
            line_cats,
            line_levels,
            pg.level,
        );

        var x: f32 = 0;
        for (order) |i| {
            const glyph = pg.glyphs.items[i];
            try shaped_glyphs.append(ShapedText.Glyph{
                .font = .{
                    .index = glyph.index,
                    .size = font_size,
                },
                .x = x + (glyph.x_offset * font_size),
                .y = glyph.y_offset * font_size,
            });
            x += glyph.x_advance * font_size;
        }

        try shaped_lines.append(ShapedText.Line{
            .start = line_start,
            .ascent = line_ascent * font_size,
            .descent = line_descent * font_size,
            .paragraph_start = first_line,
        });
    }
};

fn ucdScriptToHarfbuzzScript(script: Script.Value) hb.Script {
    return switch (script) {
        .Common => .common,
        .Latin => .latin,
        .Greek => .greek,
        .Cyrillic => .cyrillic,
        .Armenian => .armenina,
        .Hebrew => .hebrew,
        .Arabic => .arabic,
        .Syriac => .syriac,
        .Thaana => .thaana,
        .Devanagari => .devanagari,
        .Bengali => .bengali,
        .Gurmukhi => .gurmukhi,
        .Gujarati => .gujarati,
        .Oriya => .oriya,
        .Tamil => .tamil,
        .Telugu => .telugu,
        .Kannada => .kannada,
        .Malayalam => .malayalam,
        .Sinhala => .sinhala,
        .Thai => .thai,
        .Lao => .lao,
        .Tibetan => .tibetan,
        .Myanmar => .myanmar,
        .Georgian => .georgian,
        .Hangul => .hangul,
        .Ethiopic => .ethiopic,
        .Cherokee => .cherokee,
        .Canadian_Aboriginal => .canadian_aboriginal,
        .Ogham => .ogham,
        .Runic => .runic,
        .Khmer => .khmer,
        .Mongolian => .mongolian,
        .Hiragana => .hiragana,
        .Katakana => .katakana,
        .Bopomofo => .bopomofo,
        .Han => .han,
        .Yi => .yi,
        .Old_Italic => .old_italic,
        .Gothic => .gothic,
        .Deseret => .desert,
        .Inherited => .inherited,
        .Tagalog => .tagalog,
        .Hanunoo => .hanunoo,
        .Buhid => .buhid,
        .Tagbanwa => .tagbanwa,
        .Limbu => .limbu,
        .Tai_Le => .tai_le,
        .Linear_B => .linear_b,
        .Ugaritic => .ugaritic,
        .Shavian => .shavian,
        .Osmanya => .osmanya,
        .Cypriot => .cypriot,
        .Braille => .braille,
        .Buginese => .buginese,
        .Coptic => .coptic,
        .New_Tai_Lue => .new_tai_lue,
        .Glagolitic => .glagolitic,
        .Tifinagh => .tifinagh,
        .Syloti_Nagri => .syloti_nagri,
        .Old_Persian => .old_persian,
        .Kharoshthi => .kharoshthi,
        .Balinese => .balinese,
        .Cuneiform => .cuneiform,
        .Phoenician => .phoenician,
        .Phags_Pa => .phags_pa,
        .Nko => .nko,
        .Sundanese => .sundanese,
        .Lepcha => .lepcha,
        .Ol_Chiki => .ol_chiki,
        .Vai => .vai,
        .Saurashtra => .saurashtra,
        .Kayah_Li => .kayah_li,
        .Rejang => .rejang,
        .Lycian => .lycian,
        .Carian => .carian,
        .Lydian => .lydian,
        .Cham => .cham,
        .Tai_Tham => .tai_tham,
        .Tai_Viet => .tai_viet,
        .Avestan => .avestan,
        .Egyptian_Hieroglyphs => .egyptian_hieroglyphs,
        .Samaritan => .samaritan,
        .Lisu => .lisu,
        .Bamum => .bamum,
        .Javanese => .javanese,
        .Meetei_Mayek => .meetei_mayek,
        .Imperial_Aramaic => .imperial_aramaic,
        .Old_South_Arabian => .old_south_arabian,
        .Inscriptional_Parthian => .inscriptional_parthian,
        .Inscriptional_Pahlavi => .inscriptional_pahlavi,
        .Old_Turkic => .old_turkic,
        .Kaithi => .kaithi,
        .Batak => .batak,
        .Brahmi => .brahmi,
        .Mandaic => .mandaic,
        .Chakma => .chakma,
        .Meroitic_Cursive => .meroitic_cursive,
        .Meroitic_Hieroglyphs => .meroitic_hieroglyphs,
        .Miao => .miao,
        .Sharada => .sharada,
        .Sora_Sompeng => .sora_sompeng,
        .Takri => .takri,
        .Caucasian_Albanian => .caucasian_albanian,
        .Bassa_Vah => .bassa_vah,
        .Duployan => .duployan,
        .Elbasan => .elbasan,
        .Grantha => .grantha,
        .Pahawh_Hmong => .pahawh_hmong,
        .Khojki => .khojku,
        .Linear_A => .linear_a,
        .Mahajani => .mahajani,
        .Manichaean => .manichaean,
        .Mende_Kikakui => .mende_kikakui,
        .Modi => .modi,
        .Mro => .mro,
        .Old_North_Arabian => .old_north_arabian,
        .Nabataean => .nabataean,
        .Palmyrene => .palmyrene,
        .Pau_Cin_Hau => .pau_cin_hau,
        .Old_Permic => .old_permic,
        .Psalter_Pahlavi => .psalter_pahlavi,
        .Siddham => .siddham,
        .Khudawadi => .khudawadi,
        .Tirhuta => .tirhuta,
        .Warang_Citi => .warang_citi,
        .Ahom => .ahom,
        .Anatolian_Hieroglyphs => .anatolian_hieroglyphs,
        .Hatran => .hatran,
        .Multani => .multani,
        .Old_Hungarian => .old_hungarian,
        .SignWriting => .signwriting,
        .Adlam => .adlam,
        .Bhaiksuki => .bhaiksuki,
        .Marchen => .marchen,
        .Newa => .newa,
        .Osage => .osage,
        .Tangut => .tangut,
        .Masaram_Gondi => .masaram_gondi,
        .Nushu => .nushu,
        .Soyombo => .soyombo,
        .Zanabazar_Square => .zanabazar_square,
        .Dogra => .dogra,
        .Gunjala_Gondi => .gunjala_gondi,
        .Makasar => .makasar,
        .Medefaidrin => .medefaidrin,
        .Hanifi_Rohingya => .hanifi_rohingya,
        .Sogdian => .sogdian,
        .Old_Sogdian => .old_sogdian,
        .Elymaic => .elymaic,
        .Nandinagari => .nandinagari,
        .Nyiakeng_Puachue_Hmong => .nyiakeng_puachue_hmong,
        .Wancho => .wancho,
        .Chorasmian => .chorasmiah,
        .Dives_Akuru => .dives_akuru,
        .Khitan_Small_Script => .khitan_small_script,
        .Yezidi => .yezidi,
        .Cypro_Minoan => .cypro_minoan,
        .Old_Uyghur => .old_uyghur,
        .Tangsa => .tangsa,
        .Toto => .toto,
        .Vithkuqi => .vithkuqi,
        .Kawi => .kawi,
        .Nag_Mundari => .nag_mundari,
        else => .invalid,
    };
}
