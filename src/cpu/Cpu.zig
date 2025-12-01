const std = @import("std");
const isa = @import("isa.zig");
const Memory = @import("../Memory.zig");
const Instruction = isa.Instruction;
const Register = isa.Register;
const CtlRegister = isa.CtlRegister;
const Group = isa.Group;

const Self = @This();
const register_count = 1 << @bitSizeOf(Register);
const control_register_count = 1 << @bitSizeOf(CtlRegister);

mem: *Memory,
r: [register_count]u64 = .{0} ** register_count,
pc: u64,
crs: [control_register_count]u64 = .{0} ** control_register_count,
_pc: u64,

pub fn create(mem: *Memory, pc: u64) Self {
    return Self{
        .mem = mem,
        .pc = pc,
        ._pc = pc,
    };
}

pub fn eval(self: *Self, end: u64) !void {
    while (self.pc < self.mem.raw.len and self.pc < end) {
        const instr = try self.mem.load(self.pc, Instruction);
        self.pc += @sizeOf(Instruction);

        switch (instr.group.group) {
            .move => try self.group_move(&instr.move),
            .process => try self.group_process(&instr.process),
            .addpc => try self.group_addpc(&instr.addpc),
            .memory => try self.group_memory(&instr.memory),
            .branch => try self.group_branch(&instr.branch),
            .jump_rel => try self.group_jump_rel(&instr.jump_rel),
            .jump_reg => try self.group_jump_reg(&instr.jump_reg),
            .ctl => try self.group_ctl(&instr.ctl),
            .irq => try self.group_irq(&instr.irq),
        }
    }
}

pub inline fn set(self: *Self, r: Register, comptime T: type, value: T) void {
    if (r == .rZ) return;
    const I = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(T) } });
    self.r[@intFromEnum(r)] = @bitCast(@as(i64, @as(I, @bitCast(value))));
}

pub inline fn get(self: *const Self, r: Register, comptime T: type) T {
    if (r == .rZ) return 0;
    const I = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(T) } });
    return @bitCast(@as(I, @truncate(@as(i64, @bitCast(self.r[@intFromEnum(r)])))));
}

pub inline fn setCtl(self: *Self, r: CtlRegister, value: u64) void {
    self.crs[@intFromEnum(r)] = value;
}

pub inline fn getCtl(self: *const Self, r: CtlRegister) u64 {
    return self.crs[@intFromEnum(r)];
}

pub inline fn irq(self: *const Self) !void {
    self._pc = self.pc;
    self.pc = self.getCtl(.hwi);
}

inline fn group_move(self: *Self, data: *const Instruction.Move) !void {
    switch (data.mode) {
        .imm => self.set(data.dst, i64, data.src.imm),
        .imm_shift => self.set(data.dst, i64, @as(i64, data.src.imm_shift.value) << data.src.imm_shift.left_amount),

        .reg => self.set(
            data.dst,
            u64,
            if (data.src.reg.signed)
                @bitCast((self.get(data.src.reg.value, i64) << data.src.reg.left_amount) >> data.src.reg.right_amount)
            else
                (self.get(data.src.reg.value, u64) << data.src.reg.left_amount) >> data.src.reg.right_amount,
        ),

        .cvt => switch (data.src.cvt.code) {
            .fcvt_u32_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src.cvt.src, u32))),
            .fcvt_s32_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src.cvt.src, i32))),
            .fcvt_u64_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src.cvt.src, u64))),
            .fcvt_s64_f32 => self.set(data.dst, f32, @floatFromInt(self.get(data.src.cvt.src, i64))),
            .fcvt_u32_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src.cvt.src, u32))),
            .fcvt_s32_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src.cvt.src, i32))),
            .fcvt_u64_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src.cvt.src, u64))),
            .fcvt_s64_f64 => self.set(data.dst, f64, @floatFromInt(self.get(data.src.cvt.src, i64))),
            .fcvt_f32_u32 => self.set(data.dst, u32, @intFromFloat(self.get(data.src.cvt.src, f32))),
            .fcvt_f32_s32 => self.set(data.dst, i32, @intFromFloat(self.get(data.src.cvt.src, f32))),
            .fcvt_f32_u64 => self.set(data.dst, u64, @intFromFloat(self.get(data.src.cvt.src, f32))),
            .fcvt_f32_s64 => self.set(data.dst, i64, @intFromFloat(self.get(data.src.cvt.src, f32))),
            .fcvt_f64_u32 => self.set(data.dst, u32, @intFromFloat(self.get(data.src.cvt.src, f64))),
            .fcvt_f64_s32 => self.set(data.dst, i32, @intFromFloat(self.get(data.src.cvt.src, f64))),
            .fcvt_f64_u64 => self.set(data.dst, u64, @intFromFloat(self.get(data.src.cvt.src, f64))),
            .fcvt_f64_s64 => self.set(data.dst, i64, @intFromFloat(self.get(data.src.cvt.src, f64))),
            .fmov_f32_f64 => self.set(data.dst, f32, @floatCast(self.get(data.src.cvt.src, f64))),
            .fmov_f64_f32 => self.set(data.dst, f64, @floatCast(self.get(data.src.cvt.src, f32))),
        },
    }
}

inline fn group_process(self: *Self, data: *const Instruction.Process) !void {
    const lhs_raw: u64 = self.get(data.lhs, u64);
    const rhs_raw: u64 = switch (data.rhs_mode) {
        .imm => @bitCast(@as(i64, data.rhs.imm)),
        .reg => if (data.rhs.reg.shift == .lsl)
            self.get(data.rhs.reg.value, u64) << data.rhs.reg.amount
        else
            self.get(data.rhs.reg.value, u64) >> data.rhs.reg.amount,
    };

    switch (data.mode) {
        .m32 => try self.group_process_impl(data, u32, @truncate(lhs_raw), @truncate(rhs_raw)),
        .m64 => try self.group_process_impl(data, u64, lhs_raw, rhs_raw),
    }
}

inline fn group_process_impl(self: *Self, data: *const Instruction.Process, comptime U: type, lhs: U, rhs: U) !void {
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

        else => @panic("balls"),
    };

    self.set(data.dst, u64, result);
}

inline fn group_addpc(self: *Self, data: *const Instruction.AddPC) !void {
    const offset = self.pc +% @as(u64, @bitCast(@as(i64, data.offset)));

    self.set(data.dst, u64, offset);
}

inline fn group_memory(self: *Self, data: *const Instruction.Memory) !void {
    const addr: u64 = @bitCast(self.get(data.base, i64) +% @as(i64, data.offset));
    if (data.store) {
        const value = self.get(data.value, u64);
        switch (data.mode) {
            .m8 => try self.mem.store(addr, u8, @truncate(value)),
            .m16 => try self.mem.store(addr, u16, @truncate(value)),
            .m32 => try self.mem.store(addr, u32, @truncate(value)),
            .m64 => try self.mem.store(addr, u64, @truncate(value)),
        }
    } else {
        if (data.signed) {
            self.set(data.value, i64, switch (data.mode) {
                .m8 => try self.mem.load(addr, i8),
                .m16 => try self.mem.load(addr, i16),
                .m32 => try self.mem.load(addr, i32),
                .m64 => try self.mem.load(addr, i64),
            });
        } else {
            self.set(data.value, u64, switch (data.mode) {
                .m8 => try self.mem.load(addr, u8),
                .m16 => try self.mem.load(addr, u16),
                .m32 => try self.mem.load(addr, u32),
                .m64 => try self.mem.load(addr, u64),
            });
        }
    }
}

inline fn group_branch(self: *Self, data: *const Instruction.Branch) !void {
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

inline fn group_jump_rel(self: *Self, data: *const Instruction.JumpRel) !void {
    self.set(data.link, u64, self.pc);
    self.pc +%= @bitCast(@as(i64, data.offset) << 2);
}

inline fn group_jump_reg(self: *Self, data: *const Instruction.JumpReg) !void {
    self.set(data.link, u64, self.pc);
    self.pc = self.get(data.base, u64) +% @as(u64, @bitCast(@as(i64, data.offset)));
}

inline fn group_irq(self: *Self, data: *const Instruction.Irq) !void {
    switch (data.mode) {
        .swi => {
            self._pc = self.pc;
            self.pc = self.getCtl(.swi);
            self.set(.r0, u64, data.value.code);
        },

        .ret => self.pc = self._pc,
    }
}

inline fn group_ctl(self: *Self, data: *const Instruction.Ctl) !void {
    switch (data.mode) {
        .write => self.setCtl(data.target, self.get(data.reg, u64)),
        .read => self.set(data.reg, u64, self.getCtl(data.target)),
        .set => self.setCtl(data.target, self.getCtl(data.target) | self.get(data.reg, u64)),
        .unset => self.setCtl(data.target, self.getCtl(data.target) & ~self.get(data.reg, u64)),
    }
}
