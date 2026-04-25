const std = @import("std");
const Assembler = @import("asm/Assembler.zig");

const Cpu = @import("bus/cpu.zig").Cpu(.fast);
const Bus = @import("bus/bus.zig").Bus(Cpu);
const Memory = @import("bus/Memory.zig");

const c = @cImport(@cInclude("webp/encode.h"));

const allocator = std.heap.page_allocator;

pub fn main() !void {
    const cwd = std.fs.cwd();
    const source = try cwd.readFileAlloc(allocator, "examples/qoi.asm", std.math.maxInt(usize));

    var as = try Assembler.create(allocator);
    defer as.destroy();

    try as.assemble(source);

    const start = as.labels.get("_start").?;
    // std.debug.print("{X}\n", .{as.binary.items});

    var bus = Bus.create();
    var memory = try Memory.create(allocator, as.binary.items.len + 2048);
    try bus.attach(&memory);

    var cpu = Cpu.create(start);
    cpu.set(.sp, u64, memory.raw.len);
    try bus.attach(&cpu);

    @memcpy(memory.raw[0..as.binary.items.len], as.binary.items);

    const stall = as.labels.get("stall").?;

    while (true) {
        try cpu.clock();

        if (cpu.pc == stall) {
            var ptr: [*c]u8 = undefined;
            const size = c.WebPEncodeLosslessRGBA(
                memory.raw.ptr,
                1505,
                2175,
                1505 * 4,
                &ptr,
            );
            try std.fs.cwd().writeFile(.{
                .data = ptr[0..size],
                .sub_path = "test.webp",
            });
            std.debug.print("done!\n", .{});
            return;
        }
    }
}
