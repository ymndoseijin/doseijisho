const defs = @import("defs.zig");
const allocator = defs.allocator;
const Configuration = defs.Configuration;
const stdout = defs.stdout;
const Entry = defs.Entry;

const std = @import("std");

const StarDictLimits = struct {
    name: [:0]const u8,
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

    limits_list: std.ArrayList(StarDictLimits),

    title: [:0]const u8,

    config: Configuration,

    pub fn deinit(self: *StarDictDictionary) void {
        if (self.is_zip) allocator.free(self.zip_buff);
        for (self.limits_list.items) |entry| allocator.free(entry.name);
        self.limits_list.deinit();

        allocator.free(self.index_path);
        allocator.free(self.dict_path);
        allocator.free(self.path);
        allocator.free(self.title);
    }

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

    pub fn init(path: []const u8, config: Configuration) !StarDictDictionary {
        var limits_list = std.ArrayList(StarDictLimits).init(allocator);

        var dir = try std.fs.cwd().openIterableDir(path, .{});
        var dict_path: []const u8 = undefined;
        var index_path: []const u8 = undefined;
        var syn_path: []const u8 = undefined;

        var title: [:0]const u8 = try allocator.dupeZ(u8, path);

        var has_syn = false;
        defer if (has_syn) allocator.free(syn_path);
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
                defer allocator.free(ifo_path);

                var file = try std.fs.cwd().openFile(ifo_path, .{});

                var buf_reader = std.io.bufferedReader(file.reader());
                var in_stream = buf_reader.reader();

                while (try in_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024)) |line| {
                    defer allocator.free(line);
                    var iter = std.mem.split(u8, line, "=");
                    if (iter.next()) |field| {
                        if (std.mem.eql(u8, field, "bookname")) {
                            allocator.free(title);
                            title = try allocator.dupeZ(u8, iter.next() orelse break);
                        }
                    }
                }
            }
        }

        if (has_no_dict)
            return StarDictError.NoDictFile;

        if (has_no_index)
            return StarDictError.NoIndexFile;

        if (config.verbose)
            try stdout.print("{s} and {s}\n", .{ index_path, dict_path });
        var index_file = try std.fs.cwd().openFile(index_path, .{});

        var buf_reader = std.io.bufferedReader(index_file.reader());
        var in_stream = buf_reader.reader();

        while (true) {
            var string = try getString(@TypeOf(in_stream), in_stream) orelse break;
            var start = try getU32(@TypeOf(in_stream), in_stream) orelse break;
            var end = try getU32(@TypeOf(in_stream), in_stream) orelse break;

            try limits_list.append(StarDictLimits{
                .name = string,
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
                    .name = string,
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

            var stream = try std.compress.gzip.decompress(allocator, file_in_stream);
            defer stream.deinit();

            var zip_stream = stream.reader();
            var zip_buff = try zip_stream.readAllAlloc(allocator, std.math.maxInt(usize));

            if (config.verbose)
                try stdout.print("size: {}\n", .{zip_buff.len});

            return StarDictDictionary{
                .zip_buff = zip_buff,
                .is_zip = is_zip,

                .limits_list = limits_list,

                .path = try allocator.dupeZ(u8, path),
                .index_path = index_path,
                .dict_path = dict_path,
                .title = title,
                .config = config,
            };
        }

        return StarDictDictionary{
            .zip_buff = undefined,
            .is_zip = is_zip,

            .limits_list = limits_list,

            .path = try allocator.dupeZ(u8, path),
            .index_path = index_path,
            .dict_path = dict_path,
            .title = title,
            .config = config,
        };
    }

    pub fn getEntry(self: *StarDictDictionary, lemma: []const u8, name: []const u8) !Entry {
        var dict_result: StarDictLimits = undefined;
        var found = false;

        var entries = std.ArrayList([:0]const u8).init(allocator);
        var names = std.ArrayList([:0]const u8).init(allocator);
        _ = name;

        for (self.limits_list.items) |entry| {
            if (std.mem.startsWith(u8, entry.name, lemma)) {
                if (self.config.verbose)
                    try stdout.print("{any}\n", .{entry.name});
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

                    var string_ptr = try allocator.dupeZ(u8, description_slice);
                    try entries.append(string_ptr);
                    try names.append(try allocator.dupeZ(u8, entry.name));
                } else {
                    var file = try std.fs.cwd().openFile(self.dict_path, .{});
                    var buf_reader = std.io.bufferedReader(file.reader());
                    var file_in_stream = buf_reader.reader();

                    var in_stream = file_in_stream;
                    try in_stream.skipBytes(dict_result.start, .{});

                    var description_slice = try allocator.alloc(u8, dict_result.end - dict_result.start);
                    _ = try in_stream.readAll(description_slice);

                    var string_ptr = try allocator.dupeZ(u8, description_slice);
                    allocator.free(description_slice);
                    try entries.append(string_ptr);
                    try names.append(try allocator.dupeZ(u8, entry.name));

                    file.close();
                }
            }

            if (entries.items.len >= self.config.max_entries)
                break;
        }

        if (!found) {
            if (self.config.verbose)
                try stdout.print("Nope, on star, for {s}\n", .{lemma});
            return Entry{ .names = names, .descriptions = entries };
        }

        return Entry{ .names = names, .descriptions = entries };
    }
};
