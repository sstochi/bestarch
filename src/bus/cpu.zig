const std = @import("std");
const isa = @import("../isa.zig");
const bus = @import("bus.zig");
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

pub const register_count = 1 << @bitSizeOf(Reg);
pub const control_register_count = 1 << @bitSizeOf(CtlReg);

pub fn Cpu(comptime mode: enum { accurate, fast }) type {
    return struct {
        const Self = @This();
        const Bus = bus.Bus(Self);

        bus: *Bus = undefined,
        pc: u64,
        inst: Inst = @bitCast(@as(u32, 0)),
        r: [register_count]u64 = .{0} ** register_count,
        crs: [control_register_count]u64 = .{0} ** control_register_count,

        cycle: u16 = 0,
        last_mem_access: i64 = 0,

        pub fn create(pc: u64) Self {
            return Self{
                .pc = pc,
            };
        }

        pub fn clock(self: *Self) !void {
            if (mode == .fast or self.cycle == 0) {
                self.inst = try self.bus.load(self.pc, Inst);
                self.pc += @sizeOf(Inst);
            }

            if (mode == .fast or self.cycle >= 2) {
                switch (self.inst.unknown.group) {
                    .move => try self.groupMove(&self.inst),
                    .process => try self.groupProcess(&self.inst),
                    .auipc => try self.groupAuiPC(&self.inst.addpc),
                    .memory => try self.groupMemory(&self.inst.memory),
                    .memory_pair => try self.groupMemoryPair(&self.inst.memory_pair),
                    .branch => try self.groupBranch(&self.inst.branch),
                    .jump_rel => try self.groupJumpRel(&self.inst.jump_rel),
                    .jump_reg => try self.groupJumpReg(&self.inst.jump_reg),
                    .ctl => try self.groupCtl(&self.inst.ctl),
                    .irq => try self.groupIrq(&self.inst.irq),
                }
            }

            if (mode == .accurate) {
                self.cycle +%= 1;
            }
        }

        pub fn irq(self: *Self) !void {
            try self.pushState();
            self.pc = self.getCtl(.xhwi);
            self.cycle = 0;
        }

        pub fn push(self: *Self, comptime I: type, value: I) !void {
            const sp = self.get(.sp, u64) -% @sizeOf(I);
            try self.bus.store(sp, I, value);
            self.set(.sp, u64, sp);
        }

        pub fn pop(self: *Self, comptime I: type) !I {
            const sp = self.get(.sp, u64);
            const value = try self.bus.load(sp, I);
            self.set(.sp, u64, sp +% @sizeOf(I));

            return value;
        }

        pub fn set(self: *Self, r: Reg, comptime T: type, value: T) void {
            if (r == .zr) return;
            const I = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(T) } });
            self.r[@intFromEnum(r)] = @bitCast(@as(i64, @as(I, @bitCast(value))));
        }

        pub fn get(self: *const Self, r: Reg, comptime T: type) T {
            if (r == .zr) return 0;
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

        fn stallForBudget(self: *Self, budget: u16) bool {
            if (mode == .fast) {
                return false;
            }

            if (self.cycle < budget + 1) {
                return true;
            }

            self.cycle = std.math.maxInt(u16);
            return false;
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
            if (self.stallForBudget(1)) {
                return;
            }
            self.set(data.dst, i64, data.imm);
        }

        fn groupMoveImmShift(self: *Self, data: *const InstMoveImmShift) !void {
            if (self.stallForBudget(1)) {
                return;
            }
            self.set(data.dst, i64, @as(i64, data.value) << data.left_amount);
        }

        fn groupMoveReg(self: *Self, data: *const InstMoveReg) !void {
            if (self.stallForBudget(1)) {
                return;
            }

            const value = self.get(data.value, u64);
            self.set(data.dst, u64, if (data.signed)
                value << data.left_amount
            else
                @bitCast(@as(i64, @bitCast(value)) << data.left_amount));
        }

        fn groupMoveCvt(self: *Self, data: *const InstMoveCvt) !void {
            const stall = switch (data.code) {
                .fmov_f32_f64, .fmov_f64_f32 => self.stallForBudget(2),
                else => self.stallForBudget(4),
            };

            if (stall) {
                return;
            }

            switch (data.code) {
                .fmov_f32_f64 => self.set(data.dst, f32, @floatCast(self.get(data.src, f64))),
                .fmov_f64_f32 => self.set(data.dst, f64, @floatCast(self.get(data.src, f32))),

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
            }
        }

        fn groupProcess(self: *Self, inst: *const Inst) !void {
            const stall = switch (inst.process.code) {
                .mul => self.stallForBudget(4), // on modern cpus ~4 cycles
                .divs, .divu, .mods, .modu => self.stallForBudget(if (inst.process.size == .m64) 32 else 16), // on modern cpus 8-16 avg
                else => self.stallForBudget(1),
            };

            if (stall) {
                return;
            }

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

                .shl => lhs << @intCast(rhs),
                .shr => lhs >> @intCast(rhs),
                .asr => @bitCast(@as(I, @bitCast(lhs)) >> @intCast(@as(I, @bitCast(rhs)))),

                .add => lhs +% rhs,
                .sub => lhs -% rhs,
                .mul => lhs *% rhs,
                .divu => @divTrunc(lhs, rhs),
                .divs => @bitCast(@divTrunc(@as(I, @bitCast(lhs)), @as(I, @bitCast(rhs)))),
                .modu => @rem(lhs, rhs),
                .mods => @bitCast(@rem(@as(I, @bitCast(lhs)), @as(I, @bitCast(rhs)))),

                .sltu => @intFromBool(lhs < rhs),
                .slts => @intFromBool(@as(I, @bitCast(lhs)) < @as(I, @bitCast(rhs))),

                else => @panic("Invalid code"),
            };

            self.set(data.dst, u64, result);
        }

        fn groupAuiPC(self: *Self, data: *const InstAuiPC) !void {
            if (self.stallForBudget(1)) {
                return;
            }
            const offset = self.pc +% @as(u64, @bitCast(@as(i64, data.offset)));
            self.set(data.dst, u64, offset);
        }

        fn groupMemory(self: *Self, data: *const InstMemory) !void {
            var addr: u64 = @bitCast(self.get(data.base, i64));

            const offset = @as(u64, @bitCast(@as(i64, data.offset)));
            if (!data.post_inc) {
                addr +%= offset;
            }

            if (self.stallForBudget(2)) {
                return;
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

            if (data.post_inc) {
                addr +%= offset;
            }

            // wb
            if (data.value != data.base) {
                self.set(data.base, u64, addr);
            }
        }

        fn groupMemoryPair(self: *Self, data: *const InstMemoryPair) !void {
            var addr = self.get(data.base, u64);
            const offset = @as(u64, @bitCast(@as(i64, data.offset)));

            if (!data.post_inc) {
                addr +%= offset;
            }

            if (self.stallForBudget(4)) {
                return;
            }

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
                            const a, const b = try self.bus.load(addr, [2]u8);
                            value_a, value_b = .{ a, b };
                        },
                        .m16 => {
                            const a, const b = try self.bus.load(addr, [2]u16);
                            value_a, value_b = .{ a, b };
                        },
                        .m32 => {
                            const a, const b = try self.bus.load(addr, [2]u32);
                            value_a, value_b = .{ a, b };
                        },
                        .m64 => {
                            const a, const b = try self.bus.load(addr, [2]u64);
                            value_a, value_b = .{ a, b };
                        },
                    }
                }

                self.set(data.value_a, u64, value_a);
                self.set(data.value_b, u64, value_b);
            }

            if (data.post_inc) {
                addr +%= offset;
            }

            // wb
            if (data.value_a != data.base and data.value_b != data.base) {
                self.set(data.base, u64, addr);
            }
        }

        fn groupBranch(self: *Self, data: *const InstBranch) !void {
            if (self.stallForBudget(2)) {
                return;
            }

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
            if (self.stallForBudget(1)) {
                return;
            }

            self.set(data.link, u64, self.pc);
            self.pc +%= @bitCast(@as(i64, data.offset) << 2);
        }

        fn groupJumpReg(self: *Self, data: *const InstJumpReg) !void {
            if (self.stallForBudget(1)) {
                return;
            }

            self.set(data.link, u64, self.pc);
            self.pc = self.get(data.base, u64) +% @as(u64, @bitCast(@as(i64, data.offset)));
        }

        fn groupIrq(self: *Self, data: *const InstIrq) !void {
            // memory read (2 cycles) * register count + pc read
            switch (data.mode) {
                .swi => {
                    if (self.stallForBudget(register_count * 2 + 1)) {
                        return;
                    }

                    try self.pushState();
                    self.pc = self.getCtl(.xswi);
                    self.set(.r0, u64, data.code);
                },

                .ret => {
                    if (self.stallForBudget(register_count * 2)) {
                        return;
                    }

                    try self.popState();
                },
            }
        }

        fn groupCtl(self: *Self, data: *const InstCtl) !void {
            if (self.stallForBudget(1)) {
                return;
            }

            switch (data.mode) {
                .write => self.setCtl(data.target, self.get(data.reg, u64)),
                .read => self.set(data.reg, u64, self.getCtl(data.target)),
                .set => self.setCtl(data.target, self.getCtl(data.target) | self.get(data.reg, u64)),
                .unset => self.setCtl(data.target, self.getCtl(data.target) & ~self.get(data.reg, u64)),
            }
        }
    };
}
