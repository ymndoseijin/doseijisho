const std = @import("std");
const builtin = @import("builtin");

const defs = @import("defs.zig");
const ini_config = @import("ini_config.zig");
const gtk = @import("gtk_gui.zig");

pub const log_level: std.log.Level = .info;

const allocator = defs.allocator;

const DictConfig = struct { dictionary: std.ArrayList([]const u8) };

const ArgState = enum {
    Arg,
    Epwing,
    Csv,
    StarDict,
    EntryNum,
};

const Configuration = defs.Configuration;

const stdout = defs.stdout;

fn printEntry(results: std.ArrayList(defs.QueryResult)) !void {
    for (results.items) |query| {
        var i: u32 = 0;
        for (query.entry.names.items) |name| {
            var desc = query.entry.descriptions.items[i];
            try stdout.print("{s}:\n{s}\n\n", .{ name, desc });
            i += 1;
        }
    }
}

pub fn main() !void {
    var config = Configuration{
        .list_titles = false,
        .dictionary = std.ArrayList([]const u8).init(allocator),
        .max_entries = 100,
        .gtk = true,
        .verbose = false,
    };

    defer {
        for (config.dictionary.items) |path| allocator.free(path);
        config.dictionary.deinit();
    }

    defer if (builtin.mode == .Debug) {
        _ = defs.gpa.deinit();
    };

    var dicts = std.ArrayList(defs.Dictionary).init(allocator);
    defer dicts.deinit();

    var config_path: []const u8 = undefined;
    defer allocator.free(config_path);

    // Flag for saving current configuration to ini_path, it's not in the main configuration struct because it shouldn't be saved for natural reasons
    var will_save = false;
    var read_config = true;

    // set ini_path
    if (std.os.getenv("XDG_CONFIG_HOME")) |v| {
        config_path = try std.fmt.allocPrint(allocator, "{s}/doseijisho", .{v});
    } else {
        if (std.os.getenv("HOME")) |home| {
            config_path = try std.fmt.allocPrint(allocator, "{s}/.config/doseijisho", .{home});
        } else {
            @panic("No $HOME env var");
        }
    }

    try std.fs.cwd().makePath(config_path);

    var ini_path = try std.mem.concat(allocator, u8, &[_][]const u8{ config_path, "/config.ini" });
    defer allocator.free(ini_path);

    // Args parsing

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
    defer search_query.deinit();

    while (arg_iterator.next()) |arg| {
        switch (state) {
            ArgState.Arg => {
                if (std.mem.eql(u8, arg, "-e") or
                    std.mem.eql(u8, arg, "--epwing"))
                {
                    state = ArgState.Epwing;
                } else if (std.mem.eql(u8, arg, "-t") or
                    std.mem.eql(u8, arg, "--tab"))
                {
                    state = ArgState.Csv;
                } else if (std.mem.eql(u8, arg, "-i") or
                    std.mem.eql(u8, arg, "--ignore-config"))
                {
                    read_config = false;
                } else if (std.mem.eql(u8, arg, "-l") or
                    std.mem.eql(u8, arg, "--list"))
                {
                    config.list_titles = true;
                } else if (std.mem.eql(u8, arg, "-v") or
                    std.mem.eql(u8, arg, "--verbose"))
                {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--will-save")) {
                    will_save = true;
                } else if (std.mem.eql(u8, arg, "-c") or
                    std.mem.eql(u8, arg, "--cli-only"))
                {
                    config.gtk = false;
                } else if (std.mem.eql(u8, arg, "-s") or
                    std.mem.eql(u8, arg, "--stardict"))
                {
                    state = ArgState.StarDict;
                } else if (std.mem.eql(u8, arg, "-h") or
                    std.mem.eql(u8, arg, "--help"))
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
                    } else {
                        try stdout.print("Invalid argument {s}\n", .{arg});
                        std.os.exit(255);
                    }
                }
            },
            ArgState.Epwing => {
                var dict = try defs.EpwingDictionary.init(arg, config);
                try dicts.append(defs.Dictionary{ .epwing = dict });
                state = ArgState.Arg;
            },
            ArgState.StarDict => {
                var dict = try defs.StarDictDictionary.init(arg, config);
                try dicts.append(defs.Dictionary{ .stardict = dict });
                state = ArgState.Arg;
            },
            ArgState.Csv => {
                var dict = try defs.CsvDictionary.init(arg, config);
                try dicts.append(defs.Dictionary{ .csv = dict });
                state = ArgState.Arg;
            },
            ArgState.EntryNum => {},
        }
    }

    // Configuration
    if (read_config) {
        try ini_config.loadConfigForSection(Configuration, &config, "main", ini_path);

        inline for (@typeInfo(defs.Dictionary).Union.fields) |tag| {
            var dict_config = DictConfig{ .dictionary = std.ArrayList([]const u8).init(allocator) };
            defer dict_config.dictionary.deinit();

            try ini_config.loadConfigForSection(DictConfig, &dict_config, tag.name, ini_path);

            for (dict_config.dictionary.items) |path| {
                var dict = try tag.type.init(path, config);
                try dicts.append(@unionInit(defs.Dictionary, tag.name, dict));
                allocator.free(path);
            }
        }
    }

    var library = defs.Library{ .config = config, .dicts = dicts.items };

    // Do stuff with it

    if (config.list_titles) {
        for (dicts.items) |dict_union| {
            switch (dict_union) {
                inline else => |*dict| try stdout.print("{s}\n", .{dict.title}),
            }
        }
    }

    var no_dict = true;
    if (free_arg_count >= 2) {
        defer allocator.free(dict_name);

        for (dicts.items) |dict_union| {
            const title = switch (dict_union) {
                inline else => |*dict| dict.title,
            };

            if (std.mem.eql(u8, title, dict_name)) {
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

                        try printEntry(results);

                        for (results.items) |lib_query| lib_query.deinit();
                        results.deinit();
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

    // At the end, save file if required

    if (will_save) {
        var file = try std.fs.cwd().createFile(ini_path, .{});
        defer file.close();

        try ini_config.writeSection(defs.Configuration, config, "main", file);

        inline for (@typeInfo(defs.Dictionary).Union.fields) |tag| {
            var tag_list = std.ArrayList([]const u8).init(allocator);
            defer tag_list.deinit();
            for (dicts.items) |dict_union| {
                switch (dict_union) {
                    inline else => |*dict| if (*const tag.type == @TypeOf(dict))
                        try tag_list.append(dict.path),
                }
            }

            if (tag_list.items.len > 0)
                try ini_config.writeSection(DictConfig, DictConfig{ .dictionary = tag_list }, tag.name, file);
        }
    }

    // And then, deinit all
    for (dicts.items) |*dict_union| {
        switch (dict_union.*) {
            inline else => |*dict| {
                //@compileError(@typeName(@TypeOf(dict)));
                dict.deinit();
            },
        }
    }
}
