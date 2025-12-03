const std = @import("std");
const Memory = @import("Memory.zig");
const Assembler = @import("asm/Assembler.zig");
const Cpu = @import("cpu/Cpu.zig");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    const cwd = std.fs.cwd();
    const source = try cwd.readFileAlloc(allocator, "examples/test.asm", std.math.maxInt(usize));

    var as = try Assembler.create(allocator);
    try as.assemble(source);

    const start = as.labels.get("_start").?;
    std.debug.print("{X}\n", .{as.binary.items});

    var memory = try Memory.create(allocator, 2048);
    @memcpy(memory.raw[0..as.binary.items.len], as.binary.items);

    var cpu = Cpu.create(&memory, start);
    cpu.irq();

    while (true) {
        try cpu.clock();
    }

    std.debug.print("{any}\n", .{cpu.r});
}
