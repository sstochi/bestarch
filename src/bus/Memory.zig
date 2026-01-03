const std = @import("std");

const Memory = @This();

raw: []u8,

pub fn create(allocator: std.mem.Allocator, size: usize) !Memory {
    return Memory{ .raw = try allocator.alloc(u8, size) };
}

pub fn load(
    self: *const Memory,
    addr: u64,
    comptime T: type,
) !T {
    std.debug.assert(self.raw.len >= @sizeOf(T));
    if (addr > self.raw.len - @sizeOf(T)) {
        return error.InvalidAccess;
    }

    return @as(*align(1) T, @ptrCast(&self.raw[addr])).*;
}

pub fn store(
    self: *Memory,
    addr: u64,
    comptime T: type,
    value: T,
) !void {
    std.debug.assert(self.raw.len >= @sizeOf(T));
    if (addr > self.raw.len - @sizeOf(T)) {
        return error.InvalidAccess;
    }

    @as(*align(1) T, @ptrCast(&self.raw[addr])).* = value;
}
