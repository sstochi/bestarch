const std = @import("std");
const isa = @import("isa.zig");
const Bus = @import("../Bus.zig");
const Inst = isa.Inst;
const Reg = isa.Reg;
const CtlReg = isa.CtlReg;
const Group = isa.Group;
const InstMove = isa.InstMove;
const InstMoveImm = isa.InstMoveImm;
const InstMoveImmShift = isa.InstMoveImmShift;
const InstMoveReg = isa.InstMoveReg;
const InstMoveCvt = isa.InstMoveCvt;
const InstProcess = isa.InstProcess;
const InstAuiPC = isa.InstAuiPC;
const InstMemory = isa.InstMemory;
const InstMemoryPair = isa.InstMemoryPair;
const InstBranch = isa.InstBranch;
const InstJumpRel = isa.InstJumpRel;
const InstJumpReg = isa.InstJumpReg;
const InstCtl = isa.InstCtl;
const InstIrq = isa.InstIrq;

const Self = @This();
const register_count = 1 << @bitSizeOf(Reg);
const control_register_count = 1 << @bitSizeOf(CtlReg);

bus: *Bus,
r: [register_count]u64 = .{0} ** register_count,
crs: [control_register_count]u64 = .{0} ** control_register_count,
pc: u64,

pub fn create(pc: u64) Self {
    return Self{
        .bus = undefined,
        .pc = pc,
    };
}

pub fn clock(self: *Self) !void {
    const instr = try self.bus.load(self.pc, Inst);
    self.pc += @sizeOf(Inst);

    switch (instr.unknown.group) {
        .move => try self.groupMove(&instr),
        .process => try self.groupProcess(&instr),
        .auipc => try self.groupAuiPC(&instr.addpc),
        .memory => try self.groupMemory(&instr.memory),
        .memory_pair => try self.groupMemoryPair(&instr.memory_pair),
        // .memory_multi => try self.groupMemoryMulti(&instr.memory_multi),
        .branch => try self.groupBranch(&instr.branch),
        .jump_rel => try self.groupJumpRel(&instr.jump_rel),
        .jump_reg => try self.groupJumpReg(&instr.jump_reg),
        .ctl => try self.groupCtl(&instr.ctl),
        .irq => try self.groupIrq(&instr.irq),
    }
}

pub fn irq(self: *Self) !void {
    try self.pushState();
    self.pc = self.getCtl(.xhwi);
}

pub fn push(self: *Self, comptime I: type, value: I) !void {
    const sp = self.get(.rsp, u64) -% @sizeOf(I);
    try self.bus.store(sp, I, value);
    self.set(.rsp, u64, sp);
}

pub fn pop(self: *Self, comptime I: type) !I {
    const sp = self.get(.rsp, u64);
    const value = try self.bus.load(sp, I);
    self.set(.rsp, u64, sp +% @sizeOf(I));
    return value;
}

pub fn set(self: *Self, r: Reg, comptime T: type, value: T) void {
    if (r == .rz) return;
    const I = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(T) } });
    self.r[@intFromEnum(r)] = @bitCast(@as(i64, @as(I, @bitCast(value))));
}

pub fn get(self: *const Self, r: Reg, comptime T: type) T {
    if (r == .rz) return 0;
    const I = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(T) } });
    return @bitCast(@as(I, @truncate(@as(i64, @bitCast(self.r[@intFromEnum(r)])))));
}

pub fn setCtl(self: *Self, r: CtlReg, value: u64) void {
    self.crs[@intFromEnum(r)] = value;
}

pub fn getCtl(self: *const Self, r: CtlReg) u64 {
    return self.crs[@intFromEnum(r)];
}

fn pushState(self: *Self) !void {
    try self.push(u64, self.pc);
    for (0..register_count) |i| {
        try self.push(u64, self.r[i]);
    }
}

fn popState(self: *Self) !void {
    for (0..register_count) |i| {
        self.r[register_count - i - 1] = try self.pop(u64);
    }
    self.pc = try self.pop(u64);
}

fn groupMove(self: *Self, data: *const Inst) !void {
    return switch (data.move.mode) {
        .imm => self.groupMoveImm(&data.move_imm),
        .imm_shift => self.groupMoveImmShift(&data.move_imm_shift),
        .reg => self.groupMoveReg(&data.move_reg),
        .cvt => self.groupMoveCvt(&data.move_cvt),
    };
}

fn groupMoveImm(self: *Self, data: *const InstMoveImm) !void {
    self.set(data.dst, i64, data.imm);
}

fn groupMoveImmShift(self: *Self, data: *const InstMoveImmShift) !void {
    self.set(data.dst, i64, @as(i64, data.value) << data.left_amount);
}

fn groupMoveReg(self: *Self, data: *const InstMoveReg) !void {
    const value = self.get(data.value, u64);
    const sar: u64 = @bitCast(@as(i64, @bitCast(value)) << data.left_amount);
    const slr: u64 = value << data.left_amount;
    self.set(data.dst, u64, if (data.signed) slr else sar);
}

fn groupMoveCvt(self: *Self, data: *const InstMoveCvt) !void {
    switch (data.code) {
        .fcvt_u32_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src, u32))),
        .fcvt_s32_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src, i32))),
        .fcvt_u64_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src, u64))),
        .fcvt_s64_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src, i64))),
        .fcvt_u32_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src, u32))),
        .fcvt_s32_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src, i32))),
        .fcvt_u64_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src, u64))),
        .fcvt_s64_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src, i64))),
        .fcvt_f32_u32 => self.set(data.dst, u32, @intFromFloat(self.get(data.src, f32))),
        .fcvt_f32_s32 => self.set(data.dst, i32, @intFromFloat(self.get(data.src, f32))),
        .fcvt_f32_u64 => self.set(data.dst, u64, @intFromFloat(self.get(data.src, f32))),
        .fcvt_f32_s64 => self.set(data.dst, i64, @intFromFloat(self.get(data.src, f32))),
        .fcvt_f64_u32 => self.set(data.dst, u32, @intFromFloat(self.get(data.src, f64))),
        .fcvt_f64_s32 => self.set(data.dst, i32, @intFromFloat(self.get(data.src, f64))),
        .fcvt_f64_u64 => self.set(data.dst, u64, @intFromFloat(self.get(data.src, f64))),
        .fcvt_f64_s64 => self.set(data.dst, i64, @intFromFloat(self.get(data.src, f64))),
        .fmov_f32_f64 => self.set(data.dst, f32, @floatCast(self.get(data.src, f64))),
        .fmov_f64_f32 => self.set(data.dst, f64, @floatCast(self.get(data.src, f32))),
    }
}

fn groupProcess(self: *Self, inst: *const Inst) !void {
    const lhs_raw: u64 = self.get(inst.process.lhs, u64);
    const rhs_raw: u64 = switch (inst.process.rhs_mode) {
        .imm => @bitCast(@as(i64, inst.process_imm.imm)),
        .reg => if (inst.process_reg.shift == .lsl)
            self.get(inst.process_reg.value, u64) << inst.process_reg.amount
        else
            self.get(inst.process_reg.value, u64) >> inst.process_reg.amount,
    };

    switch (inst.process.size) {
        .m32 => try self.groupProcessImpl(&inst.process, u32, @truncate(lhs_raw), @truncate(rhs_raw)),
        .m64 => try self.groupProcessImpl(&inst.process, u64, lhs_raw, rhs_raw),
    }
}

fn groupProcessImpl(self: *Self, data: *const InstProcess, comptime U: type, lhs: U, rhs: U) !void {
    const I = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(U) } });

    const result: U = switch (data.code) {
        .@"and" => lhs & rhs,
        .@"or" => lhs | rhs,
        .xor => lhs ^ rhs,

        .lsl => lhs << @intCast(rhs),
        .lsr => lhs >> @intCast(rhs),
        .asr => @bitCast(@as(I, @bitCast(lhs)) >> @intCast(@as(I, @bitCast(rhs)))),

        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .divu => @divTrunc(lhs, rhs),
        .divs => @bitCast(@divTrunc(@as(I, @bitCast(lhs)), @as(I, @bitCast(rhs)))),
        .modu => @rem(lhs, rhs),
        .mods => @bitCast(@rem(@as(I, @bitCast(lhs)), @as(I, @bitCast(rhs)))),
        else => @panic("Invalid code"),
    };

    self.set(data.dst, u64, result);
}

fn groupAuiPC(self: *Self, data: *const InstAuiPC) !void {
    const offset = self.pc +% @as(u64, @bitCast(@as(i64, data.offset)));
    self.set(data.dst, u64, offset);
}

fn groupMemory(self: *Self, data: *const InstMemory) !void {
    var addr: u64 = @bitCast(self.get(data.base, i64) +% @as(i64, data.offset));

    const offset = @as(u64, @bitCast(@as(i64, data.offset)));
    if (!data.post_inc) {
        addr +%= offset;
    }

    if (data.store) {
        const value = self.get(data.value, u64);
        switch (data.mode) {
            .m8 => try self.bus.store(addr, u8, @truncate(value)),
            .m16 => try self.bus.store(addr, u16, @truncate(value)),
            .m32 => try self.bus.store(addr, u32, @truncate(value)),
            .m64 => try self.bus.store(addr, u64, @truncate(value)),
        }
    } else {
        if (data.signed) {
            self.set(data.value, i64, switch (data.mode) {
                .m8 => try self.bus.load(addr, i8),
                .m16 => try self.bus.load(addr, i16),
                .m32 => try self.bus.load(addr, i32),
                .m64 => try self.bus.load(addr, i64),
            });
        } else {
            self.set(data.value, u64, switch (data.mode) {
                .m8 => try self.bus.load(addr, u8),
                .m16 => try self.bus.load(addr, u16),
                .m32 => try self.bus.load(addr, u32),
                .m64 => try self.bus.load(addr, u64),
            });
        }
    }

    if (data.post_inc) addr +%= offset;
}

fn groupMemoryPair(self: *Self, data: *const InstMemoryPair) !void {
    var addr = self.get(data.base, u64);
    const offset = @as(u64, @bitCast(@as(i64, data.offset)));
    if (!data.post_inc) addr +%= offset;

    if (data.store) {
        const value_a = self.get(data.value_a, u64);
        const value_b = self.get(data.value_b, u64);
        switch (data.mode) {
            .m8 => try self.bus.store(addr, [2]u8, .{ @truncate(value_a), @truncate(value_b) }),
            .m16 => try self.bus.store(addr, [2]u16, .{ @truncate(value_a), @truncate(value_b) }),
            .m32 => try self.bus.store(addr, [2]u32, .{ @truncate(value_a), @truncate(value_b) }),
            .m64 => try self.bus.store(addr, [2]u64, .{ value_a, value_b }),
        }
    } else {
        var value_a: u64 = undefined;
        var value_b: u64 = undefined;
        if (data.signed) {
            switch (data.mode) {
                .m8 => {
                    const a, const b = try self.bus.load(addr, [2]i8);
                    value_a, value_b = .{ @bitCast(@as(i64, a)), @bitCast(@as(i64, b)) };
                },
                .m16 => {
                    const a, const b = try self.bus.load(addr, [2]i16);
                    value_a, value_b = .{ @bitCast(@as(i64, a)), @bitCast(@as(i64, b)) };
                },
                .m32 => {
                    const a, const b = try self.bus.load(addr, [2]i32);
                    value_a, value_b = .{ @bitCast(@as(i64, a)), @bitCast(@as(i64, b)) };
                },
                .m64 => {
                    const a, const b = try self.bus.load(addr, [2]i64);
                    value_a, value_b = .{ @bitCast(a), @bitCast(b) };
                },
            }
        } else {
            switch (data.mode) {
                .m8 => {
                    value_a = try self.bus.load(addr, u8);
                    value_b = try self.bus.load(addr + @sizeOf(u8), u8);
                    addr +%= 2 * @sizeOf(u8);
                },
                .m16 => {
                    value_a = try self.bus.load(addr, u16);
                    value_b = try self.bus.load(addr + @sizeOf(u8), u16);
                },
                .m32 => {
                    value_a = try self.bus.load(addr, u32);
                    value_b = try self.bus.load(addr + @sizeOf(u8), u32);
                },
                .m64 => {
                    value_a = try self.bus.load(addr, u64);
                    value_b = try self.bus.load(addr + @sizeOf(u8), u64);
                },
            }
        }
        self.set(data.value_a, u64, value_a);
        self.set(data.value_b, u64, value_b);
    }

    if (data.post_inc) {
        addr +%= offset;
    }

    // write back
    self.set(data.base, u64, addr);
}

fn groupBranch(self: *Self, data: *const InstBranch) !void {
    var lhs = self.get(data.lhs, u64);
    var rhs = self.get(data.rhs, u64);

    const flip_mask = @as(u64, @intFromBool(data.flags.signed)) << 63;
    lhs ^= flip_mask;
    rhs ^= flip_mask;

    const lt = lhs < rhs;
    const eq = lhs == rhs;
    const result = if (data.flags.compare) lt else eq;
    if (result != data.flags.flip) {
        self.pc +%= @bitCast(@as(i64, data.offset) << 2);
    }
}

fn groupJumpRel(self: *Self, data: *const InstJumpRel) !void {
    self.set(data.link, u64, self.pc);
    self.pc +%= @bitCast(@as(i64, data.offset) << 2);
}

fn groupJumpReg(self: *Self, data: *const InstJumpReg) !void {
    self.set(data.link, u64, self.pc);
    self.pc = self.get(data.base, u64) +% @as(u64, @bitCast(@as(i64, data.offset)));
}

fn groupIrq(self: *Self, data: *const InstIrq) !void {
    switch (data.mode) {
        .swi => {
            try self.pushState();
            self.pc = self.getCtl(.xswi);
            self.set(.r0, u64, data.code);
        },

        .ret => try self.popState(),
    }
}

fn groupCtl(self: *Self, data: *const InstCtl) !void {
    switch (data.mode) {
        .write => self.setCtl(data.target, self.get(data.reg, u64)),
        .read => self.set(data.reg, u64, self.getCtl(data.target)),
        .set => self.setCtl(data.target, self.getCtl(data.target) | self.get(data.reg, u64)),
        .unset => self.setCtl(data.target, self.getCtl(data.target) & ~self.get(data.reg, u64)),
    }
}
