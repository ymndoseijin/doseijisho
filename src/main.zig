const std = @import("std");
const unicode = @import("std").unicode;
const builtin = @import("builtin");

const defs = @import("defs.zig");

pub const log_level: std.log.Level = .info;

const gtk = @import("gtk_gui.zig");

const allocator = defs.allocator;

const ArgState = enum {
    Arg,
    Epwing,
    Csv,
    StarDict,
};

const Configuration = defs.Configuration;

const stdout = defs.stdout;

fn printEntry(results: std.ArrayList(defs.QueryResult)) !void {
    for (results.items) |query| {
        var i: u32 = 0;
        for (query.entry.names.items) |name| {
            var desc = query.entry.descriptions.items[i];
            try stdout.print("{s}:\n{s}\n\n", .{ name[0 .. name.len - 1], desc[0 .. desc.len - 1] });
            i += 1;
        }

        query.entry.descriptions.deinit();
        query.entry.names.deinit();
    }
}

pub fn main() !void {
    var config = defs.config;

    var arg_iterator = switch (builtin.os.tag) {
        .windows => try std.process.ArgIterator.initWithAllocator(allocator),
        else => std.process.args(),
    };

    var state = ArgState.Arg;
    var command: ?[]const u8 = null;
    var index: u32 = 0;
    var free_arg_count: u32 = 0;

    var dict_name: []const u8 = undefined;
    var search_query = std.ArrayList([]const u8).init(allocator);

    var dicts = std.ArrayList(defs.Dictionary).init(allocator);
    defer dicts.deinit();

    while (arg_iterator.next()) |arg| {
        switch (state) {
            ArgState.Arg => {
                if (std.mem.startsWith(u8, arg, "-e") or
                    std.mem.startsWith(u8, arg, "--epwing"))
                {
                    state = ArgState.Epwing;
                } else if (std.mem.startsWith(u8, arg, "-t") or
                    std.mem.startsWith(u8, arg, "--tab"))
                {
                    state = ArgState.Csv;
                } else if (std.mem.startsWith(u8, arg, "-l") or
                    std.mem.startsWith(u8, arg, "--list"))
                {
                    config.list_titles = true;
                } else if (std.mem.startsWith(u8, arg, "-v") or
                    std.mem.startsWith(u8, arg, "--verbose"))
                {
                    config.verbose = true;
                } else if (std.mem.startsWith(u8, arg, "-c") or
                    std.mem.startsWith(u8, arg, "--cli-only"))
                {
                    config.gtk = false;
                } else if (std.mem.startsWith(u8, arg, "-s") or
                    std.mem.startsWith(u8, arg, "--stardict"))
                {
                    state = ArgState.StarDict;
                } else if (std.mem.startsWith(u8, arg, "-h") or
                    std.mem.startsWith(u8, arg, "--help"))
                {
                    try stdout.print(@embedFile("help.txt"), .{command.?});
                    std.os.exit(0);
                } else if (arg.len > 1) {
                    if (arg[0] != '-') {
                        if (free_arg_count == 0) {
                            command = arg;
                        } else if (free_arg_count == 1) {
                            dict_name = try allocator.dupe(u8, arg);
                        } else {
                            var query = try allocator.dupeZ(u8, arg);
                            try search_query.append(query);
                        }
                        free_arg_count += 1;
                    }
                }
            },
            ArgState.Epwing => {
                var dict = try defs.EpwingDictionary.init(arg);
                try dicts.append(defs.Dictionary{ .epwing = dict });
                state = ArgState.Arg;
            },
            ArgState.StarDict => {
                var dict = try defs.StarDictDictionary.init(arg);
                try dicts.append(defs.Dictionary{ .stardict = dict });
                state = ArgState.Arg;
            },
            ArgState.Csv => {
                var dict = try defs.CsvDictionary.init(arg);
                try dicts.append(defs.Dictionary{ .csv = dict });
                state = ArgState.Arg;
            },
        }
    }

    var library = defs.Library{ .dicts = dicts.items };

    if (config.list_titles) {
        for (dicts.items) |dict_union| {
            switch (dict_union) {
                inline else => |*dict| try stdout.print("{s}\n", .{dict.title}),
            }
        }
    }

    var no_dict = true;
    if (free_arg_count >= 2) {
        for (dicts.items) |dict_union| {
            const title = switch (dict_union) {
                inline else => |*dict| dict.title,
            };
            if (std.mem.eql(u8, title[0 .. title.len - 1], dict_name)) {
                if (free_arg_count == 2) {
                    var stdin = std.io.getStdIn().reader();
                    var buf_reader = std.io.bufferedReader(stdin);
                    var in_stream = buf_reader.reader();

                    while (try in_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 32768)) |line| {
                        var sentinel_query = try allocator.dupeZ(u8, line);
                        var results = try library.queryLibrary(@ptrCast([*c]const u8, sentinel_query), index);
                        try printEntry(results);

                        allocator.free(sentinel_query);
                        allocator.free(line);
                    }
                } else {
                    for (search_query.items) |query| {
                        var results = try library.queryLibrary(@ptrCast([*c]const u8, query), index);
                        defer results.deinit();
                        try printEntry(results);

                        allocator.free(query);
                    }
                }
                no_dict = false;
                break;
            }
            index += 1;
        }
        if (no_dict) {
            std.os.exit(255);
        }
    } else if (config.gtk) {
        gtk.gtkStart(library);
    }
}
