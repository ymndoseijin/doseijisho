const std = @import("std");
const unicode = @import("std").unicode;

const defs = @import("defs.zig");

pub const log_level: std.log.Level = .info;

const gtk = @import("gtk_gui.zig");
var dictionaries = std.ArrayList(defs.Dictionary).init(allocator);

const allocator = std.heap.c_allocator;

const ArgState = enum {
    Arg,
    Epwing,
    Csv,
    StarDict,
};

pub fn main() !void {
    var arg_iterator = std.process.args();

    var state = ArgState.Arg;
    var command: ?[]const u8 = null;

    while (arg_iterator.next()) |arg| {
        if (command) |val| {
            _ = val;
        } else {
            command = arg;
        }
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
                } else if (std.mem.startsWith(u8, arg, "-s") or
                    std.mem.startsWith(u8, arg, "--stardict"))
                {
                    state = ArgState.StarDict;
                } else if (std.mem.startsWith(u8, arg, "-h") or
                    std.mem.startsWith(u8, arg, "--help"))
                {
                    std.log.info(@embedFile("help.txt"), .{command.?});
                    std.os.exit(0);
                }
            },
            ArgState.Epwing => {
                var dict = try defs.EpwingDictionary.init(arg);
                try dictionaries.append(defs.Dictionary{ .epwing = dict });
                state = ArgState.Arg;
            },
            ArgState.StarDict => {
                var dict = try defs.StarDictDictionary.init(arg);
                try dictionaries.append(defs.Dictionary{ .stardict = dict });
                state = ArgState.Arg;
            },
            ArgState.Csv => {
                var dict = try defs.CsvDictionary.init(arg);
                try dictionaries.append(defs.Dictionary{ .csv = dict });
                state = ArgState.Arg;
            },
        }
    }

    gtk.gtkStart(dictionaries.items);
}
