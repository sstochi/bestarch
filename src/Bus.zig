const std = @import("std");
const Cpu = @import("cpu/Cpu.zig");
const Memory = @import("Memory.zig");

const Self = @This();

cpu: *Cpu,
mem: *Memory,

pub fn create() Self {
    return Self{
        .mem = undefined,
        .cpu = undefined,
    };
}

pub fn attach(self: *Self, dev: anytype) !void {
    const type_info = @typeInfo(@TypeOf(dev));
    if (type_info != .pointer) return error.InvalidType;

    switch (type_info.pointer.child) {
        Cpu => {
            self.cpu = dev;
            self.cpu.bus = self;
        },

        Memory => {
            self.mem = dev;
        },

        else => return error.InvalidType,
    }
}

pub fn load(
    self: *const Self,
    addr: u64,
    comptime T: type,
) !T {
    return try self.mem.load(addr, T);
}

pub fn store(
    self: *Self,
    addr: u64,
    comptime T: type,
    value: T,
) !void {
    return try self.mem.store(addr, T, value);
}
