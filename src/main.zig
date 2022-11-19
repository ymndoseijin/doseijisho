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
    var search_query: []const u8 = undefined;

    var dicts = std.ArrayList(defs.Dictionary).init(allocator);

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
                } else if (std.mem.startsWith(u8, arg, "-n") or
                    std.mem.startsWith(u8, arg, "--no-gtk"))
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
                } else if (arg[0] != '-') {
                    if (free_arg_count == 0) {
                        command = arg;
                    } else if (free_arg_count == 1) {
                        dict_name = try allocator.dupe(u8, arg);
                    } else if (free_arg_count == 2) {
                        search_query = try allocator.dupe(u8, arg);
                    } else {
                        try stdout.print("Too many arguments {s} {}\n", .{ arg, free_arg_count });
                        std.os.exit(255);
                    }
                    free_arg_count += 1;
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
                inline else => |*dict| {
                    try stdout.print("{s}\n", .{dict.title});
                },
            }
        }
    }

    if (free_arg_count == 3) {
        for (dicts.items) |dict_union| {
            switch (dict_union) {
                inline else => |*dict| {
                    if (std.mem.eql(u8, dict.title, dict_name)) {
                        var results = try library.queryLibrary(@ptrCast([*c]const u8, try allocator.dupeZ(u8, search_query)), index);
                        for (results.items) |query| {
                            var i: u32 = 0;
                            for (query.entry.names.items) |name| {
                                var desc = query.entry.descriptions.items[i];
                                try stdout.print("{s}:\n{s}\n\n", .{ name, desc });
                                i += 1;
                            }

                            query.entry.descriptions.deinit();
                            query.entry.names.deinit();
                        }
                        break;
                    }
                    index += 1;
                },
            }
        }
    }

    if (config.gtk) {
        gtk.gtkStart(library);
    }
}
