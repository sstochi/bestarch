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

    const start = as.labels.get("_start").?.?;
    std.debug.print("{X}\n", .{as.binary.items});

    var bus = Bus.create();
    var memory = try Memory.create(allocator, 2048);
    try bus.attach(&memory);

    var cpu = Cpu.create(start);
    cpu.set(.rSP, u64, memory.raw.len);
    try bus.attach(&cpu);

    @memcpy(memory.raw[0..as.binary.items.len], as.binary.items);

    var puis = std.time.milliTimestamp();
    while (true) {
        try cpu.clock();

        if ((std.time.milliTimestamp() - puis) > 1000) {
            try cpu.irq();
            puis = std.time.milliTimestamp();
        }
    }

    std.debug.print("{any}\n", .{cpu.r});
}
