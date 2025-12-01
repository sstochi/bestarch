const std = @import("std");
const isa = @import("cpu/isa.zig");
const Memory = @import("Memory.zig");
const Cpu = @import("cpu/Cpu.zig");
const Instruction = isa.Instruction;

const allocator = std.heap.page_allocator;

pub fn main() !void {
    var memory = try Memory.create(allocator, 2048);
    var i: u64 = 0;
    var cpu = Cpu.create(&memory, 0);

    try memory.store(i, Instruction, Instruction{ .move = .{
        .dst = .r0,
        .mode = .imm,
        .src = .{ .imm = 0x10 },
    } });
    i += @sizeOf(Instruction);

    try memory.store(i, Instruction, Instruction{ .move = .{
        .dst = .r1,
        .mode = .imm,
        .src = .{ .imm = 0x20 },
    } });
    i += @sizeOf(Instruction);

    try memory.store(i, Instruction, Instruction{
        .branch = .{
            .lhs = .r1,
            .rhs = .r0,
            .offset = @sizeOf(Instruction) >> 2,
            .flags = .{
                .compare = true,
                .signed = false,
                .flip = false,
            },
        },
    });
    i += @sizeOf(Instruction);

    try memory.store(i, Instruction, Instruction{ .move = .{
        .dst = .r0,
        .mode = .imm,
        .src = .{ .imm = 0x40 },
    } });
    i += @sizeOf(Instruction);

    try memory.store(i, Instruction, Instruction{
        .jump_rel = .{
            .link = .rZ,
            .offset = @sizeOf(Instruction) >> 2,
        },
    });
    i += @sizeOf(Instruction);

    try memory.store(i, Instruction, Instruction{ .move = .{
        .dst = .r0,
        .mode = .imm,
        .src = .{ .imm = 0x69 },
    } });
    i += @sizeOf(Instruction);

    try cpu.eval(i);
    std.debug.print("{}\n", .{cpu.get(.r0, u64)});
}
