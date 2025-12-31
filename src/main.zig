const std = @import("std");
const Bus = @import("Bus.zig");
const Memory = @import("Memory.zig");
const Assembler = @import("asm/Assembler.zig");
const Cpu = @import("cpu/Cpu.zig");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    const cwd = std.fs.cwd();
    const source = try cwd.readFileAlloc(allocator, "examples/test.asm", std.math.maxInt(usize));

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

    while (true) {
        try cpu.clock();
        if (cpu.pc == as.labels.get("_fail").?) {
            std.debug.print("decoded: {x}\n", .{cpu.get(.r3, u32)});
        }
    }
}
