const std = @import("std");

var allocator = @import("defs.zig").allocator;

pub fn writeSection(comptime T: type, configuration: T, section: []const u8, file: std.fs.File) !void {
    _ = try file.write("[");
    _ = try file.write(section);
    _ = try file.write("]\n");

    inline for (@typeInfo(T).Struct.fields) |f, i| {
        _ = i;

        switch (f.type) {
            bool => {
                _ = try file.write(f.name);
                _ = try file.write(" = ");
                if (@field(configuration, f.name)) {
                    _ = try file.write("true");
                } else {
                    _ = try file.write("false");
                }
                _ = try file.write("\n");
            },
            []const u8, []u8 => {
                _ = try file.write(f.name);
                _ = try file.write(" = ");
                _ = try file.write(@field(configuration, f.name));
                _ = try file.write("\n");
            },
            std.ArrayList([]const u8) => {
                for (@field(configuration, f.name).items) |string| {
                    _ = try file.write(f.name);
                    _ = try file.write(" = ");
                    _ = try file.write(string);
                    _ = try file.write("\n");
                }
            },
            else => @panic("Unknown type"),
        }
    }
    _ = try file.write("\n");
}

fn assignFromString(comptime T: type, value: *T, string: []const u8) !void {
    switch (T) {
        bool => {
            if (std.mem.eql(u8, string, "true")) {
                value.* = true;
            } else if (std.mem.eql(u8, string, "false")) {
                value.* = false;
            } else {
                @panic("Invalid in Bool");
            }
        },
        []const u8, []u8 => value = try allocator.dupe(u8, string),
        std.ArrayList([]const u8) => {
            try value.append(try allocator.dupe(u8, string));
        },
        else => @panic("Unknown type"),
    }
}

pub fn loadConfigForSection(comptime T: type, configuration: *T, section: []const u8, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();
    var buf: [2048]u8 = undefined;

    var current_section: [2048]u8 = undefined;
    var section_len: usize = 0;

    while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (line.len == 0)
            continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']')
                @panic("Unclosed section");
            std.mem.copy(u8, &current_section, line[1 .. line.len - 1]);
            section_len = line.len - 1;
            continue;
        }

        if (!std.mem.eql(u8, section, current_section[0 .. section_len - 1]))
            continue;

        var iter = std.mem.split(u8, line, "=");
        var i: u32 = 0;
        var field_name: []const u8 = undefined;

        while (iter.next()) |in_field| {
            var field = std.mem.trim(u8, in_field, " ");
            if (i == 0) {
                field_name = field;
            } else if (i == 1) {
                inline for (@typeInfo(T).Struct.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        try assignFromString(f.type, &@field(configuration, f.name), field);
                    }
                }
            } else {
                @panic("Too many arguments");
            }
            i += 1;
        }
    }
}
