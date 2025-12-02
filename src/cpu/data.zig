const std = @import("std");
const isa = @import("isa.zig");
const fmt = std.fmt.comptimePrint;

fn typeName(comptime T: type) []const u8 {
    var parts = std.mem.splitBackwardsScalar(u8, @typeName(T), '.');
    return parts.first();
}

fn genJSON(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: []const u8 = fmt(
                "\"struct:{d}:{s}\": {{\n",
                .{ @typeInfo(info.backing_integer.?).int.bits, typeName(T) },
            );
            for (info.fields, 0..) |field, i| {
                if (i > 0) result = result ++ ",\n";
                result = result ++ "    ";

                if (field.default_value_ptr) |any_val| {
                    const val_fmt: *const field.type = @ptrCast(@alignCast(any_val));

                    const val_str = switch (@typeInfo(field.type)) {
                        .@"enum" => @tagName(val_fmt.*),
                        .int, .bool => fmt("{}", .{val_fmt.*}),
                        else => @compileError("unsupported"),
                    };

                    result = result ++ fmt(
                        "\"{s}:{s}\": \"{s}\"",
                        .{ field.name, typeName(field.type), val_str },
                    );
                } else {
                    result = result ++ fmt(
                        "\"{s}\": \"{s}\"",
                        .{ field.name, typeName(field.type) },
                    );
                }
            }
            return result ++ "\n  }";
        },
        .@"enum" => |info| {
            var result: []const u8 = fmt(
                "\"enum:{d}:{s}\": {{\n",
                .{ @typeInfo(info.tag_type).int.bits, typeName(T) },
            );
            for (info.fields, 0..) |field, i| {
                if (i > 0) result = result ++ ",\n";
                result = result ++ "    ";
                result = result ++ fmt(
                    "\"{s}\": \"{}\"",
                    .{ field.name, field.value },
                );
            }
            return result ++ "\n  }";
        },
        .@"union" => |info| {
            var result: []const u8 = fmt(
                "\"union:{s}\": {{\n",
                .{typeName(T)},
            );
            for (info.fields, 0..) |field, i| {
                if (i > 0) result = result ++ ",\n";
                result = result ++ "    ";
                result = result ++ fmt(
                    "\"{s}\": \"{s}\"",
                    .{ field.name, typeName(field.type) },
                );
            }
            return result ++ "\n  }";
        },
        else => @compileError("unsupported"),
    }
}

pub fn main() !void {
    @setEvalBranchQuota(1_000_000);

    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("{\n");
    inline for (@typeInfo(isa).@"struct".decls, 0..) |decl, i| {
        if (i > 0) try stdout.writeAll(",\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(comptime genJSON(@field(isa, decl.name)));
    }
    try stdout.writeAll("\n}");
    try stdout.flush();
}
