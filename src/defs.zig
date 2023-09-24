const std = @import("std");
const ini_config = @import("ini_config.zig");
const builtin = @import("builtin");

pub fn range(len: usize) []const void {
    return @as([*]void, undefined)[0..len];
}

// TODO: use a better impl
pub fn leven(comptime T: type, alloc: std.mem.Allocator, a: []const T, b: []const T, max: ?usize) !usize {
    if (std.mem.eql(T, a, b)) return 0;

    var left = a;
    var right = b;

    if (left.len > right.len) {
        left = b;
        right = a;
    }

    var ll = left.len;
    var rl = right.len;

    if (max != null and rl - ll >= max.?) {
        return max.?;
    }

    {
        const sl = suffixLen(T, a, b);
        ll -= sl;
        rl -= sl;
    }

    const start = prefixLen(T, a, b);
    ll -= start;
    rl -= start;

    if (ll == 0) return rl;

    var result: usize = 0;

    const charCodeCache = try alloc.alloc(T, ll);
    defer alloc.free(charCodeCache);

    const array = try alloc.alloc(usize, ll);
    defer alloc.free(array);

    for (range(ll), 0..) |_, i| {
        charCodeCache[i] = left[start + i];
        array[i] = i + 1;
    }

    for (range(rl), 0..) |_, j| {
        const bCharCode = right[start + j];
        var temp = j;
        result = j + 1;

        for (range(ll), 0..) |_, i| {
            const temp2 = if (bCharCode == charCodeCache[i]) temp else temp + 1;
            temp = array[i];
            array[i] = if (temp > result) (if (temp2 > result) result + 1 else temp2) else (if (temp2 > temp) temp + 1 else temp2);
            result = array[i];
        }
    }

    if (max != null and result >= max.?) return max.?;
    return result;
}

fn prefixLen(comptime T: type, a: []const T, b: []const T) usize {
    if (a.len == 0 or b.len == 0) return 0;
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {}
    return i;
}

fn suffixLen(comptime T: type, a: []const T, b: []const T) usize {
    if (a.len == 0 or b.len == 0) return 0;
    var i: usize = 0;
    while (a[a.len - 1 - i] == b[b.len - 1 - i]) : (i += 1) {}
    return i;
}

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

    // exclude entries containing
    exclude: std.ArrayList([]const u8),

    // dictionary paths
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
    name: [:0]const u8,
    description: [:0]const u8,
    score: u64,

    pub fn deinit(self: Entry) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub const EntryBatch = struct {
    entries: std.ArrayList(Entry),

    pub fn deinit(self: EntryBatch) void {
        for (self.entries.items) |entry| entry.deinit();

        self.entries.deinit();
    }
};

pub const QueryResult = struct {
    query_name: [:0]const u8,
    query_lemma: [:0]const u8,
    entries: ?EntryBatch,

    pub fn deinit(self: QueryResult) void {
        if (self.entries) |entries| entries.deinit();

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
        var cptr = @as([*c][*c]u8, @ptrCast(&argv_a[0]));

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

                var c_response = c.mecab_sparse_tostr(mecab, @as([*c]const u8, @ptrCast(dupe_token)));

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
                    var name: [:0]const u8 = undefined;
                    if (tab_iter.next()) |word| {
                        name = try allocator.dupeZ(u8, word);
                    } else {
                        return MecabError.MecabNotEnoughFields;
                    }
                    var lemma: [:0]const u8 = undefined;
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

                    try entries.append(QueryResult{ .entries = null, .query_lemma = lemma, .query_name = name });
                }
            } else {
                try entries.append(QueryResult{ .entries = null, .query_lemma = dupe_token, .query_name = try allocator.dupeZ(u8, dupe_token) });
            }
        }
        var dict_union = self.dicts[index];
        for (entries.items) |*request| {
            var result = try dict_union.getEntryBatch(request.query_lemma, request.query_name);

            var i: usize = 0;
            while (i < result.entries.items.len) {
                var delete = false;
                const entry = result.entries.items[i];
                for (self.config.exclude.items) |exclude| {
                    const description_res = std.mem.indexOf(u8, entry.description, exclude);
                    const name_res = std.mem.indexOf(u8, entry.name, exclude);
                    if (description_res != null or name_res != null) {
                        delete = true;
                        break;
                    }
                }
                if (delete) {
                    var deleted = result.entries.swapRemove(i);
                    deleted.deinit();
                } else {
                    i += 1;
                }
            }

            const func = struct {
                pub fn inner(_: void, a: Entry, b: Entry) bool {
                    return a.score < b.score;
                }
            }.inner;

            //for (result.entries.items) |*entry| {
            //    entry.score = leven(u8, request.query_lemma, entry.name);
            //}
            std.mem.sort(Entry, result.entries.items, {}, func);
            request.entries = result;
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

    pub fn getEntryBatch(self: *CsvDictionary, lemma: []const u8, name: []const u8) !EntryBatch {
        var dict_result = self.dict_hash_map.get(lemma);

        var batch = EntryBatch{ .entries = std.ArrayList(Entry).init(allocator) };

        var name_dup = try allocator.dupeZ(u8, name);

        if (dict_result) |offset| {
            if (self.config.verbose)
                try stdout.print("Yes, at {}\n", .{offset});
            var description_slice = try self.getDescription(offset) orelse return batch;
            const num = std.mem.replace(u8, description_slice[1 .. description_slice.len - 1], "\\n", "\n", description_slice);
            description_slice.len -= num + 1;
            description_slice[description_slice.len - 1] = 0;

            var entry = try allocator.dupeZ(u8, description_slice);

            try batch.entries.append(Entry{ .name = name_dup, .description = entry, .score = 0 });

            return batch;
        } else {
            // If not found, create an empty window with a greyed out label
            if (self.config.verbose)
                try stdout.print("Nope, for {s}\n", .{lemma});
            return batch;
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
        var ret: usize = c.iconv(iconv, @as([*c][*c]u8, @ptrCast(&target_string)), &ibl, @as([*c][*c]u8, @ptrCast(&conversion_ptr)), &obl);
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
        if (c.eb_bind(&book, @as([*c]const u8, @ptrCast(path_null))) < 0) {
            return EpwingError.InvalidPath;
        }
        if (c.eb_subbook_list(&book, @as([*c]c.EB_Subbook_Code, @ptrCast(subbook_list[0..])), &subbook_count) < 0) {
            return EpwingError.InvalidPath;
        }
        if (config.verbose)
            try stdout.print("{}\n", .{subbook_count});
        if (c.eb_set_subbook(&book, subbook_list[0]) < 0) {
            return EpwingError.InvalidPath;
        }

        if (c.eb_subbook_title2(&book, subbook_list[0], @as([*c]u8, @ptrCast(title[0..]))) < 0) {
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
    pub fn getEntryBatch(self: *EpwingDictionary, lemma: []const u8, name: []const u8) !EntryBatch {
        var batch = EntryBatch{ .entries = std.ArrayList(Entry).init(allocator) };

        var hits: [50]c.EB_Hit = undefined;

        var lemma_sentinel = try allocator.dupeZ(u8, lemma);
        var converted_lemma = try iconvOwned(self.iconv_to, &lemma_sentinel);

        defer allocator.free(converted_lemma);
        defer allocator.free(lemma_sentinel);

        if (c.eb_search_word(&self.book, @as([*c]const u8, @ptrCast(converted_lemma))) == -1) {
            return batch;
        }

        var hitcount: i32 = 0;

        if (c.eb_hit_list(&self.book, hits.len, @as([*c]c.EB_Hit, @ptrCast(hits[0..])), &hitcount) == -1) {
            return batch;
        }

        if (self.config.verbose)
            try stdout.print("hit {}\n", .{hitcount});

        var i: u32 = 0;

        _ = name; // ?

        while (i < hitcount) : (i += 1) {
            if (c.eb_seek_text(&self.book, &hits[i].text) == -1) {
                return batch;
            }

            var buff = try allocator.alloc(u8, 32768);
            defer allocator.free(buff);

            var result_len: isize = 0;

            if (c.eb_read_text(&self.book, null, null, null, buff.len - 1, @as([*c]u8, @ptrCast(buff)), &result_len) == -1) {
                return batch;
            }

            if (c.eb_seek_text(&self.book, &hits[i].heading) == -1) {
                return batch;
            }

            var response = try iconvOwned(self.iconv_from, &buff);

            if (c.eb_read_heading(&self.book, null, null, null, buff.len - 1, @as([*c]u8, @ptrCast(buff)), &result_len) == -1) {
                return batch;
            }

            var heading = try iconvOwned(self.iconv_from, &buff);

            try batch.entries.append(Entry{ .name = heading, .description = response, .score = 0 });

            if (batch.entries.items.len >= self.config.max_entries)
                break;
        }

        return batch;
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

    pub fn getEntryBatch(self: *Dictionary, lemma: [:0]const u8, name: [:0]const u8) !EntryBatch {
        const entry = switch (self.*) {
            inline else => |*dict| blk: {
                break :blk try dict.getEntryBatch(lemma, name);
            },
        };
        return entry;
    }
};
