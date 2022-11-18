const std = @import("std");
const builtin = @import("builtin");

pub const message = "冬子は己のすぐ前をゆっくりと歩いている。";

pub const c = @cImport({
    @cInclude("iconv.h");
    @cInclude("mecab.h");
    @cInclude("gtk/gtk.h");
    @cInclude("eb/eb.h");
    @cInclude("eb/text.h");
    @cInclude("eb/error.h");
});

// caller owns memory
pub fn toNullTerminated(text: []const u8) ![:0]const u8 {
    return allocator.dupeZ(u8, text);
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

pub const Entry = struct {
    names: std.ArrayList([]const u8),
    descriptions: std.ArrayList([]const u8),
};

pub const QueryResult = struct {
    query_name: []const u8,
    query_lemma: []const u8,
    entry: Entry,
};

pub const Library = struct {
    pub const MecabError = error{
        MecabImproper,
        MecabNotEnoughFields,
    };

    dicts: []Dictionary,

    pub fn queryLibrary(self: *Library, phrase: [*c]const u8, index: usize) !std.ArrayList(QueryResult) {
        var entries = std.ArrayList(QueryResult).init(allocator);
        var argv_a = [_][*c]const u8{
            "mecab",
        };
        var cptr = @ptrCast([*c][*c]u8, &argv_a[0]);
        var mecab = c.mecab_new(argv_a.len, cptr);

        var c_response = c.mecab_sparse_tostr(mecab, phrase);
        std.log.info("mecab {s}", .{c_response});
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
                name = try toNullTerminated(word);
            } else {
                return MecabError.MecabNotEnoughFields;
            }
            var lemma: []const u8 = undefined;
            var no_field: bool = true;
            while (field_iter.next()) |field| {
                if (i == 6) {
                    lemma = field;
                    no_field = false;
                    break;
                }
                i += 1;
            }
            if (no_field) {
                return MecabError.MecabNotEnoughFields;
            }
            std.log.info("lemma & name {s} {s}", .{ lemma, name });
            if (std.mem.startsWith(u8, lemma, "*"))
                lemma = name;

            if (self.dicts.len > 0) {
                var dict_union = self.dicts[index];

                switch (dict_union) {
                    inline else => |*dict| {
                        const entry = try dict.getEntry(lemma, name);
                        try entries.append(QueryResult{ .entry = entry, .query_lemma = lemma, .query_name = name });
                    },
                }
            }
        }

        c.mecab_destroy(mecab);

        return entries;
    }
};

pub const EpwingError = error{
    InvalidPath,
};

pub const CsvDictionary = struct {
    path: []const u8,
    dict_hash_map: std.StringHashMap(usize),
    title: []const u8,
    pub fn init(path: []const u8) !CsvDictionary {
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
            .title = path,
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
        var names = std.ArrayList([]const u8).init(allocator);
        var entries = std.ArrayList([]const u8).init(allocator);
        try names.append(try toNullTerminated(name));
        if (dict_result) |offset| {
            std.log.info("Yes, at {}", .{offset});
            var description_slice = try self.getDescription(offset) orelse return Entry{ .names = names, .descriptions = entries };
            const num = std.mem.replace(u8, description_slice[1 .. description_slice.len - 1], "\\n", "\n", description_slice);
            description_slice.len -= num + 1;
            description_slice[description_slice.len - 1] = 0;

            var string_ptr = try toNullTerminated(description_slice);
            try entries.append(string_ptr);

            return Entry{ .names = names, .descriptions = entries };
        } else {
            // If not found, create an empty window with a greyed out label
            std.log.info("Nope, for {s}", .{lemma});
            return Entry{ .names = names, .descriptions = entries };
        }
    }
};

pub const EpwingDictionary = struct {
    path: []const u8,
    book: c.EB_Book,
    iconv_to: c.iconv_t,
    iconv_from: c.iconv_t,
    title: []const u8,

    /// caller owns memory
    fn iconvOwned(iconv: c.iconv_t, string: *[]const u8) ![]const u8 {
        var conversion_ptr = try allocator.alloc(u8, string.len * 4);
        for (conversion_ptr[0..]) |*b| b.* = 0;
        var converted_lemma = conversion_ptr;

        var target_string = string.*;

        var ibl: usize = string.len;
        var obl: usize = string.len * 4;
        var ret: usize = c.iconv(iconv, @ptrCast([*c][*c]u8, &target_string), &ibl, @ptrCast([*c][*c]u8, &conversion_ptr), &obl);
        _ = ret;
        var index = std.mem.indexOf(u8, converted_lemma, "\x00").?;
        var buff = try allocator.alloc(u8, index + 1);
        std.mem.copy(u8, buff, converted_lemma[0 .. index + 1]);
        allocator.free(converted_lemma);

        return buff;
    }

    pub fn init(path: []const u8) !EpwingDictionary {
        var book: c.EB_Book = undefined;
        var path_null = try toNullTerminated(path);
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
        std.log.info("{}", .{subbook_count});
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
        };
    }

    pub fn deinit(self: *EpwingDictionary) void {
        _ = self;
        //c.eb_d(&self.book);
    }

    /// caller owns memory
    pub fn getEntry(self: *EpwingDictionary, lemma: []const u8, name: []const u8) !Entry {
        var hits: [50]c.EB_Hit = undefined;
        var lemma_sentinel = try toNullTerminated(lemma);

        var entries = std.ArrayList([]const u8).init(allocator);
        var names = std.ArrayList([]const u8).init(allocator);

        var converted_lemma = try iconvOwned(self.iconv_to, &lemma_sentinel);

        if (c.eb_search_word(&self.book, @ptrCast([*c]const u8, converted_lemma)) == -1) {
            try names.append(try toNullTerminated(name));
            return Entry{ .names = names, .descriptions = entries };
        }

        var hitcount: i32 = 0;

        if (c.eb_hit_list(&self.book, hits.len, @ptrCast([*c]c.EB_Hit, hits[0..]), &hitcount) == -1) {
            try names.append(try toNullTerminated(name));
            return Entry{ .names = names, .descriptions = entries };
        }

        std.log.info("hit {}", .{hitcount});

        var i: u32 = 0;

        while (i < hitcount) : (i += 1) {
            if (c.eb_seek_text(&self.book, &hits[i].text) == -1) {
                try names.append(try toNullTerminated(name));
                return Entry{ .names = names, .descriptions = entries };
            }

            var buff = try allocator.alloc(u8, 32768);

            var result_len: isize = 0;

            if (c.eb_read_text(&self.book, null, null, null, buff.len, @ptrCast([*c]u8, buff), &result_len) == -1) {
                try names.append(try toNullTerminated(name));
                return Entry{ .names = names, .descriptions = entries };
            }

            if (c.eb_seek_text(&self.book, &hits[i].heading) == -1) {
                try names.append(try toNullTerminated(name));
                return Entry{ .names = names, .descriptions = entries };
            }

            var response = try iconvOwned(self.iconv_from, &buff);

            if (c.eb_read_heading(&self.book, null, null, null, buff.len, @ptrCast([*c]u8, buff), &result_len) == -1) {
                try names.append(try toNullTerminated(name));
                return Entry{ .names = names, .descriptions = entries };
            }

            var heading = try iconvOwned(self.iconv_from, &buff);

            allocator.free(buff);

            try names.append(heading[0..heading.len]);
            try entries.append(response[0..response.len]);
        }

        allocator.free(lemma_sentinel);
        allocator.free(converted_lemma);

        return Entry{ .names = names, .descriptions = entries };
    }
};

const StarDictLimits = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

pub const NgramIterator = struct {
    string: []const u8,
    n: i32,
    offset: i32,

    pub fn init(string: []const u8, n: i32) NgramIterator {
        if (n < 0)
            @panic("NgramIterator size is negative");
        return NgramIterator{
            .string = string,
            .n = n,
            .offset = -n + 1,
        };
    }

    /// caller owns memory
    pub fn next(self: *NgramIterator) !?[]const u8 {
        if (self.offset == self.string.len)
            return null;
        var nu: u32 = @intCast(u32, self.n);
        var buff = try allocator.alloc(u8, nu);
        var i: u32 = 0;
        while (i < nu) : (i += 1) {
            if (self.offset + @intCast(i32, i) > self.string.len - 1 or self.offset + @intCast(i32, i) < 0 or self.string.len == 0) {
                buff[i] = ' ';
            } else {
                var index: u32 = @intCast(u32, self.offset + @intCast(i32, i));
                buff[i] = self.string[index];
            }
        }
        self.offset += 1;

        return buff;
    }
};

const Replacement = struct {
    a: []const u8,
    b: []const u8,
};
const replacements = []Replacement{
    Replacement{ "á", "a" },
};

pub const StarDictDictionary = struct {
    path: []const u8,

    zip_buff: []const u8,
    is_zip: bool,

    dict_path: []const u8,
    index_path: []const u8,
    syn_path: []const u8,

    limits_list: std.ArrayList(StarDictLimits),

    title: []const u8,

    pub const StarDictError = error{
        NoDictFile,
        NoIndexFile,
    };

    fn getU32(comptime T: type, reader: T) !?u32 {
        var size: usize = 0;

        var buff: [4]u8 = undefined;

        size = try reader.read(&buff);
        if (size != 4)
            return null;

        std.mem.reverse(u8, buff[0..]);

        return std.mem.bytesAsSlice(u32, buff[0..])[0];
    }

    fn getString(comptime T: type, reader: T) !?[:0]u8 {
        var buff: [1024]u8 = undefined;

        var i: u32 = 0;
        while (true) {
            var char = reader.readByte() catch return null;
            if (i > buff.len - 1) {
                std.log.err("Dictionary name is larger than allowed! \"{s}\"", .{buff});
                return null;
            }
            buff[i] = char;
            if (char == 0) {
                var return_buff = try allocator.alloc(u8, i + 1);
                std.mem.copy(u8, return_buff, buff[0 .. i + 1]);

                return return_buff[0..i :0];
            }
            i += 1;
        }
    }

    pub fn init(path: []const u8) !StarDictDictionary {
        var limits_list = std.ArrayList(StarDictLimits).init(allocator);

        var dir = try std.fs.cwd().openIterableDir(path, .{});
        var dict_path: []const u8 = undefined;
        var index_path: []const u8 = undefined;
        var syn_path: []const u8 = undefined;

        var title: []const u8 = path;

        var has_syn = false;
        var is_zip = false;

        var has_no_dict = true;
        var has_no_index = true;

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |file_entry| {
            if (std.mem.endsWith(u8, file_entry.basename, ".dict.dz")) {
                is_zip = true;
                dict_path = try std.fs.path.join(allocator, &[_][]const u8{ path, file_entry.path });
                has_no_dict = false;
            } else if (std.mem.endsWith(u8, file_entry.basename, ".dict")) {
                is_zip = false;
                dict_path = try std.fs.path.join(allocator, &[_][]const u8{ path, file_entry.path });
                has_no_dict = false;
            } else if (std.mem.endsWith(u8, file_entry.basename, ".idx")) {
                index_path = try std.fs.path.join(allocator, &[_][]const u8{ path, file_entry.path });
                has_no_index = false;
            } else if (std.mem.endsWith(u8, file_entry.basename, ".syn")) {
                syn_path = try std.fs.path.join(allocator, &[_][]const u8{ path, file_entry.path });
                has_syn = true;
            } else if (std.mem.endsWith(u8, file_entry.basename, ".ifo")) {
                var ifo_path = try std.fs.path.join(allocator, &[_][]const u8{ path, file_entry.path });
                var file = try std.fs.cwd().openFile(ifo_path, .{});

                var buf_reader = std.io.bufferedReader(file.reader());
                var in_stream = buf_reader.reader();

                while (try in_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024)) |line| {
                    var iter = std.mem.split(u8, line, "=");
                    if (iter.next()) |field| {
                        if (std.mem.eql(u8, field, "bookname")) {
                            title = try allocator.dupeZ(u8, iter.next() orelse break);
                            allocator.free(line);
                        }
                    }
                }
            }
        }

        if (has_no_dict)
            return StarDictError.NoDictFile;

        if (has_no_index)
            return StarDictError.NoIndexFile;

        std.log.info("{s} and {s}", .{ index_path, dict_path });
        var index_file = try std.fs.cwd().openFile(index_path, .{});

        var buf_reader = std.io.bufferedReader(index_file.reader());
        var in_stream = buf_reader.reader();

        while (true) {
            var string = try getString(@TypeOf(in_stream), in_stream) orelse break;
            var start = try getU32(@TypeOf(in_stream), in_stream) orelse break;
            var end = try getU32(@TypeOf(in_stream), in_stream) orelse break;

            try limits_list.append(StarDictLimits{
                .name = try toNullTerminated(string),
                .start = start,
                .end = start + end,
            });
        }

        if (has_syn) {
            var syn_index_file = try std.fs.cwd().openFile(syn_path, .{});

            var syn_buf_reader = std.io.bufferedReader(syn_index_file.reader());
            var syn_stream = syn_buf_reader.reader();
            while (true) {
                var string = try getString(@TypeOf(syn_stream), syn_stream) orelse break;
                var index = try getU32(@TypeOf(syn_stream), syn_stream) orelse break;

                if (string.len == 0)
                    continue;

                var entry = limits_list.items[index];

                try limits_list.append(StarDictLimits{
                    .name = try toNullTerminated(string),
                    .start = entry.start,
                    .end = entry.end,
                });
            }
        }

        if (is_zip) {
            var file = try std.fs.cwd().openFile(dict_path, .{});
            defer file.close();

            var zip_reader = std.io.bufferedReader(file.reader());
            var file_in_stream = zip_reader.reader();

            var stream = try std.compress.gzip.gzipStream(allocator, file_in_stream);
            defer stream.deinit();

            var zip_stream = stream.reader();
            var zip_buff = try zip_stream.readAllAlloc(allocator, std.math.maxInt(usize));

            std.log.info("size: {}", .{zip_buff.len});
            return StarDictDictionary{
                .zip_buff = zip_buff,
                .is_zip = is_zip,

                .limits_list = limits_list,

                .path = path,
                .index_path = index_path,
                .syn_path = syn_path,
                .dict_path = dict_path,
                .title = title,
            };
        }

        return StarDictDictionary{
            .zip_buff = undefined,
            .is_zip = is_zip,

            .limits_list = limits_list,

            .path = path,
            .index_path = index_path,
            .syn_path = syn_path,
            .dict_path = dict_path,
            .title = title,
        };
    }

    pub fn deinit(self: *StarDictDictionary) void {
        self.dict_hash_map.deinit();
    }

    pub fn getEntry(self: *StarDictDictionary, lemma: []const u8, name: []const u8) !Entry {
        var dict_result: StarDictLimits = undefined;
        var found = false;

        var entries = std.ArrayList([]const u8).init(allocator);
        var names = std.ArrayList([]const u8).init(allocator);
        _ = name;

        for (self.limits_list.items) |entry| {
            if (std.mem.startsWith(u8, entry.name, lemma)) {
                std.log.info("{any}", .{entry.name});
                var is_dupe = false;
                for (names.items) |dupe_entry| {
                    if (std.mem.eql(u8, dupe_entry, entry.name)) {
                        is_dupe = true;
                        break;
                    }
                }
                if (is_dupe)
                    continue;
                found = true;
                dict_result = entry;

                if (self.is_zip) {
                    var description_slice = self.zip_buff[dict_result.start..dict_result.end];

                    var string_ptr = try toNullTerminated(description_slice);
                    try entries.append(string_ptr);
                    try names.append(entry.name);
                } else {
                    var file = try std.fs.cwd().openFile(self.dict_path, .{});
                    var buf_reader = std.io.bufferedReader(file.reader());
                    var file_in_stream = buf_reader.reader();

                    var in_stream = file_in_stream;
                    try in_stream.skipBytes(dict_result.start, .{});

                    var description_slice = try allocator.alloc(u8, dict_result.end - dict_result.start);
                    _ = try in_stream.readAll(description_slice);

                    var string_ptr = try toNullTerminated(description_slice);
                    allocator.free(description_slice);
                    try entries.append(string_ptr);
                    try names.append(entry.name);

                    file.close();
                }
            }
            if (entries.items.len > 10)
                break;
        }

        if (!found) {
            std.log.info("Nope, on star, for {s}", .{lemma});
            return Entry{ .names = names, .descriptions = entries };
        }

        return Entry{ .names = names, .descriptions = entries };
    }
};
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
