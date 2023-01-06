const std = @import("std");
const ini_config = @import("ini_config.zig");
const builtin = @import("builtin");

pub var gpa = std.heap.GeneralPurposeAllocator(.{
    .stack_trace_frames = 1000,
}){};
pub const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

pub const message = "冬子は己のすぐ前をゆっくりと歩いている。";

pub const stdout = std.io.getStdOut().writer();

pub const Configuration = struct {
    list_titles: bool,
    max_entries: u32,
    gtk: bool,
    verbose: bool,
    dictionary: std.ArrayList([]const u8),
};

pub const c = @cImport({
    @cInclude("iconv.h");
    @cInclude("mecab.h");
    @cInclude("gtk/gtk.h");
    @cInclude("eb/eb.h");
    @cInclude("eb/text.h");
    @cInclude("eb/error.h");
});

pub const Entry = struct {
    names: std.ArrayList([:0]const u8),
    descriptions: std.ArrayList([:0]const u8),

    pub fn deinit(self: Entry) void {
        for (self.names.items) |name| allocator.free(name);
        for (self.descriptions.items) |desc| allocator.free(desc);

        self.descriptions.deinit();
        self.names.deinit();
    }
};

pub const QueryResult = struct {
    query_name: []const u8,
    query_lemma: []const u8,
    entry: Entry,

    pub fn deinit(self: QueryResult) void {
        self.entry.deinit();

        allocator.free(self.query_lemma);
        allocator.free(self.query_name);
    }
};

pub const Library = struct {
    pub const MecabError = error{
        MecabImproper,
        MecabNotEnoughFields,
    };

    dicts: []Dictionary,
    config: Configuration,

    pub fn queryLibrary(self: *Library, phrase: [*c]const u8, index: usize) !std.ArrayList(QueryResult) {
        var entries = std.ArrayList(QueryResult).init(allocator);

        if (self.dicts.len == 0) {
            return entries;
        }

        var argv_a = [_][*c]const u8{
            "mecab",
        };
        var cptr = @ptrCast([*c][*c]u8, &argv_a[0]);

        var iter = std.mem.split(u8, std.mem.span(phrase), "\"");

        var quote_i: u32 = 0;

        while (iter.next()) |token| {
            defer quote_i += 1;
            defer quote_i = quote_i % 2;

            if (token.len == 0)
                continue;
            var dupe_token = try allocator.dupeZ(u8, token);

            if (quote_i == 0) {
                defer allocator.free(dupe_token);

                var mecab = c.mecab_new(argv_a.len, cptr);
                defer c.mecab_destroy(mecab);

                var c_response = c.mecab_sparse_tostr(mecab, @ptrCast([*c]const u8, dupe_token));

                if (self.config.verbose)
                    try stdout.print("mecab {s}\n", .{c_response});

                const type_ptr = @as([*:0]const u8, c_response);
                const ptr = std.mem.span(type_ptr);

                var line_iter = std.mem.split(u8, ptr, "\n");

                while (line_iter.next()) |line| {
                    if (std.mem.startsWith(u8, line, "EOS") or line.len == 0)
                        continue;

                    var field_iter = std.mem.split(u8, line, ",");
                    var tab_iter = std.mem.split(u8, line, "\t");

                    var i: u32 = 0;
                    var name: []const u8 = undefined;
                    if (tab_iter.next()) |word| {
                        name = try allocator.dupeZ(u8, word);
                    } else {
                        return MecabError.MecabNotEnoughFields;
                    }
                    var lemma: []const u8 = undefined;
                    var no_field: bool = true;
                    while (field_iter.next()) |field| {
                        if (i == 6) {
                            if (std.mem.startsWith(u8, field, "*")) {
                                lemma = try allocator.dupeZ(u8, name);
                            } else {
                                lemma = try allocator.dupeZ(u8, field);
                            }
                            no_field = false;
                            break;
                        }
                        i += 1;
                    }
                    if (no_field) {
                        return MecabError.MecabNotEnoughFields;
                    }
                    if (self.config.verbose)
                        try stdout.print("lemma & name {s} {s}\n", .{ lemma, name });

                    var dict_union = self.dicts[index];
                    const entry = switch (dict_union) {
                        inline else => |*dict| blk: {
                            if (self.config.verbose) {
                                var dict_name = @typeName(@TypeOf(dict.*));
                                try stdout.print("Searching for \"{s}\" on {s}\n", .{ lemma, dict_name });
                            }
                            break :blk try dict.getEntry(lemma, name);
                        },
                    };
                    try entries.append(QueryResult{ .entry = entry, .query_lemma = lemma, .query_name = name });
                }
            } else {
                var dict_union = self.dicts[index];
                const entry = switch (dict_union) {
                    inline else => |*dict| blk: {
                        if (self.config.verbose) {
                            var dict_name = @typeName(@TypeOf(dict.*));
                            try stdout.print("Searching for \"{s}\" from quote on {s}\n", .{ dupe_token, dict_name });
                        }
                        break :blk try dict.getEntry(dupe_token, dupe_token);
                    },
                };
                try entries.append(QueryResult{ .entry = entry, .query_lemma = dupe_token, .query_name = try allocator.dupeZ(u8, dupe_token) });
            }
        }

        return entries;
    }
};

pub const EpwingError = error{
    InvalidPath,
};

pub const CsvDictionary = struct {
    path: []const u8,
    dict_hash_map: std.StringHashMap(usize),
    title: [:0]const u8,
    config: Configuration,

    pub fn init(path: []const u8, config: Configuration) !CsvDictionary {
        var hash_map = std.StringHashMap(usize).init(allocator);
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var offset: usize = 0;

        while (try in_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 32768)) |line| {
            var iter = std.mem.split(u8, line, "\t");
            var name_slice = iter.next().?;
            var name_copy = try allocator.alloc(u8, name_slice.len);
            std.mem.copy(u8, name_copy, name_slice);

            try hash_map.put(name_copy, offset);

            offset += line.len + 1;

            allocator.free(line);
        }

        return CsvDictionary{
            .path = path,
            .dict_hash_map = hash_map,
            .title = try allocator.dupeZ(u8, path),
            .config = config,
        };
    }

    pub fn deinit(self: *CsvDictionary) void {
        self.dict_hash_map.deinit();
    }

    pub fn getDescription(self: *CsvDictionary, offset: usize) !?[:0]u8 {
        var file = try std.fs.cwd().openFile(self.path, .{});
        defer file.close();
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        try in_stream.skipBytes(offset, .{});

        while (try in_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 32768)) |line| {
            var iter = std.mem.split(u8, line, "\t");
            _ = iter.next();
            var description_slice: [:0]u8 = try allocator.dupeZ(u8, iter.next().?);
            allocator.free(line);

            return description_slice;
        }

        return null;
    }

    pub fn getEntry(self: *CsvDictionary, lemma: []const u8, name: []const u8) !Entry {
        var dict_result = self.dict_hash_map.get(lemma);
        var names = std.ArrayList([:0]const u8).init(allocator);
        var entries = std.ArrayList([:0]const u8).init(allocator);
        try names.append(try allocator.dupeZ(u8, name));
        if (dict_result) |offset| {
            if (self.config.verbose)
                try stdout.print("Yes, at {}\n", .{offset});
            var description_slice = try self.getDescription(offset) orelse return Entry{ .names = names, .descriptions = entries };
            const num = std.mem.replace(u8, description_slice[1 .. description_slice.len - 1], "\\n", "\n", description_slice);
            description_slice.len -= num + 1;
            description_slice[description_slice.len - 1] = 0;

            var string_ptr = try allocator.dupeZ(u8, description_slice);
            try entries.append(string_ptr);

            return Entry{ .names = names, .descriptions = entries };
        } else {
            // If not found, create an empty window with a greyed out label
            if (self.config.verbose)
                try stdout.print("Nope, for {s}\n", .{lemma});
            return Entry{ .names = names, .descriptions = entries };
        }
    }
};

pub const EpwingDictionary = struct {
    path: []const u8,
    book: c.EB_Book,
    iconv_to: c.iconv_t,
    iconv_from: c.iconv_t,
    title: [:0]const u8,
    config: Configuration,

    /// caller owns memory
    fn iconvOwned(iconv: c.iconv_t, string: *[]const u8) ![:0]const u8 {
        var conversion_ptr = try allocator.alloc(u8, string.len * 4);
        for (conversion_ptr[0..]) |*b| b.* = 0;
        var converted_lemma = conversion_ptr;

        var target_string = string.*;

        var ibl: usize = string.len;
        var obl: usize = string.len * 4;
        var ret: usize = c.iconv(iconv, @ptrCast([*c][*c]u8, &target_string), &ibl, @ptrCast([*c][*c]u8, &conversion_ptr), &obl);
        _ = ret;
        var index = std.mem.indexOf(u8, converted_lemma, "\x00").?;

        var buff = try allocator.dupeZ(u8, converted_lemma[0..index]);

        allocator.free(converted_lemma);

        return buff;
    }

    pub fn init(path: []const u8, config: Configuration) !EpwingDictionary {
        var book: c.EB_Book = undefined;
        var path_null = try allocator.dupeZ(u8, path);
        var subbook_count: i32 = 0;
        var subbook_list: [10]c.EB_Subbook_Code = undefined;
        var iconv_to = c.iconv_open("euc-jp", "UTF-8");
        var iconv_from = c.iconv_open("UTF-8", "euc-jp");
        var title: [c.EB_MAX_TITLE_LENGTH + 1]u8 = undefined;

        defer allocator.free(path_null);

        _ = c.eb_initialize_library();
        c.eb_initialize_book(&book);
        if (c.eb_bind(&book, @ptrCast([*c]const u8, path_null)) < 0) {
            return EpwingError.InvalidPath;
        }
        if (c.eb_subbook_list(&book, @ptrCast([*c]c.EB_Subbook_Code, subbook_list[0..]), &subbook_count) < 0) {
            return EpwingError.InvalidPath;
        }
        if (config.verbose)
            try stdout.print("{}\n", .{subbook_count});
        if (c.eb_set_subbook(&book, subbook_list[0]) < 0) {
            return EpwingError.InvalidPath;
        }

        if (c.eb_subbook_title2(&book, subbook_list[0], @ptrCast([*c]u8, title[0..])) < 0) {
            return EpwingError.InvalidPath;
        }

        var slice: []const u8 = title[0..];

        return EpwingDictionary{
            .path = path,
            .book = book,
            .iconv_to = iconv_to,
            .iconv_from = iconv_from,
            .title = try iconvOwned(iconv_from, &slice),
            .config = config,
        };
    }

    pub fn deinit(self: *EpwingDictionary) void {
        allocator.free(self.title);
        //c.eb_d(&self.book);
    }

    /// caller owns memory
    pub fn getEntry(self: *EpwingDictionary, lemma: []const u8, name: []const u8) !Entry {
        var hits: [50]c.EB_Hit = undefined;

        var entries = std.ArrayList([:0]const u8).init(allocator);
        var names = std.ArrayList([:0]const u8).init(allocator);

        var lemma_sentinel = try allocator.dupeZ(u8, lemma);
        var converted_lemma = try iconvOwned(self.iconv_to, &lemma_sentinel);

        defer allocator.free(converted_lemma);
        defer allocator.free(lemma_sentinel);

        if (c.eb_search_word(&self.book, @ptrCast([*c]const u8, converted_lemma)) == -1) {
            try names.append(try allocator.dupeZ(u8, name));
            return Entry{ .names = names, .descriptions = entries };
        }

        var hitcount: i32 = 0;

        if (c.eb_hit_list(&self.book, hits.len, @ptrCast([*c]c.EB_Hit, hits[0..]), &hitcount) == -1) {
            try names.append(try allocator.dupeZ(u8, name));
            return Entry{ .names = names, .descriptions = entries };
        }

        if (self.config.verbose)
            try stdout.print("hit {}\n", .{hitcount});

        var i: u32 = 0;

        while (i < hitcount) : (i += 1) {
            if (c.eb_seek_text(&self.book, &hits[i].text) == -1) {
                try names.append(try allocator.dupeZ(u8, name));
                return Entry{ .names = names, .descriptions = entries };
            }

            var buff = try allocator.alloc(u8, 32768);
            defer allocator.free(buff);

            var result_len: isize = 0;

            if (c.eb_read_text(&self.book, null, null, null, buff.len - 1, @ptrCast([*c]u8, buff), &result_len) == -1) {
                try names.append(try allocator.dupeZ(u8, name));
                return Entry{ .names = names, .descriptions = entries };
            }

            if (c.eb_seek_text(&self.book, &hits[i].heading) == -1) {
                try names.append(try allocator.dupeZ(u8, name));
                return Entry{ .names = names, .descriptions = entries };
            }

            var response = try iconvOwned(self.iconv_from, &buff);

            if (c.eb_read_heading(&self.book, null, null, null, buff.len - 1, @ptrCast([*c]u8, buff), &result_len) == -1) {
                try names.append(try allocator.dupeZ(u8, name));
                return Entry{ .names = names, .descriptions = entries };
            }

            var heading = try iconvOwned(self.iconv_from, &buff);

            try names.append(heading);
            try entries.append(response);

            if (entries.items.len >= self.config.max_entries)
                break;
        }

        return Entry{ .names = names, .descriptions = entries };
    }
};

pub const StarDictDictionary = @import("stardict.zig").StarDictDictionary;

pub const DictionaryTag = enum {
    csv,
    stardict,
    epwing,
};

pub const Dictionary = union(DictionaryTag) {
    csv: CsvDictionary,
    stardict: StarDictDictionary,
    epwing: EpwingDictionary,
};
