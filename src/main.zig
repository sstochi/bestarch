const std = @import("std");
const isa = @import("cpu/isa.zig");
const Memory = @import("Memory.zig");
const Cpu = @import("cpu/Cpu.zig");
const Inst = isa.Inst;

const allocator = std.heap.page_allocator;

pub fn main() !void {
    var memory = try Memory.create(allocator, 2048);
    var i: u64 = 0;
    var cpu = Cpu.create(&memory, 0);

    try memory.store(i, Inst, Inst{ .move_imm = .{
        .dst = .r0,
        .mode = .imm,
        .imm = 0x10,
    } });
    i += @sizeOf(Inst);

    try memory.store(i, Inst, Inst{ .move_imm = .{
        .dst = .r1,
        .mode = .imm,
        .imm = 0x20,
    } });
    i += @sizeOf(Inst);

    try memory.store(i, Inst, Inst{ .branch = .{
        .lhs = .r1,
        .rhs = .r0,
        .offset = @sizeOf(Inst) >> 2,
        .flags = .{
            .compare = true,
            .signed = false,
            .flip = false,
        },
    } });
    i += @sizeOf(Inst);

    try memory.store(i, Inst, Inst{ .move_imm = .{
        .dst = .r0,
        .mode = .imm,
        .imm = 0x40,
    } });
    i += @sizeOf(Inst);

    try memory.store(i, Inst, Inst{
        .jump_rel = .{
            .link = .rZ,
            .offset = @sizeOf(Inst) >> 2,
        },
    });
    i += @sizeOf(Inst);

    try memory.store(i, Inst, Inst{ .move_imm = .{
        .dst = .r0,
        .mode = .imm,
        .imm = 0x69,
    } });
    i += @sizeOf(Inst);

    try cpu.eval(i);
    std.debug.print("{}\n", .{cpu.get(.r0, u64)});
}
