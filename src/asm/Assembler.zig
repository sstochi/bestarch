const std = @import("std");
const builtin = @import("builtin");
const target_endian = builtin.target.cpu.arch.endian();

const Token = @import("Token.zig");
const Parser = @import("Parser.zig");
const isa = @import("../cpu/isa.zig");
const Inst = isa.Inst;
const ProcessCode = isa.ProcessCode;
const MemorySize1 = isa.MemorySize1;
const MemorySize2 = isa.MemorySize2;
const ShiftType = isa.ShiftType;
const CompareFlags = isa.CmpFlags;
const Reg = isa.Reg;
const CtlReg = isa.CtlReg;
const CtlMode = isa.CtlMode;
const InstProcessImm = isa.InstProcessImm;

const Self = @This();

pub const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    ParseError,
};

allocator: std.mem.Allocator,
labels: std.StringHashMapUnmanaged(?usize) = .empty,
binary: std.ArrayList(u8) = .empty,

pub fn create(allocator: std.mem.Allocator) Error!Self {
    return Self{
        .allocator = allocator,
        .labels = .empty,
        .binary = try .initCapacity(allocator, 1024),
    };
}

pub fn destroy(self: *Self) void {
    self.labels.deinit(self.allocator);
    self.binary.deinit(self.allocator);
}

pub fn assemble(self: *Self, source: []const u8) Error!void {
    self.binary.clearRetainingCapacity();
    self.labels.clearRetainingCapacity();

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_count: usize = 0;

    // collect lables
    var binary_size: usize = 0;
    while (lines.next()) |line| : (line_count += 1) {
        var parser = Parser{ .buf = line };
        binary_size = self.parseLabel(&parser, binary_size) catch |err| {
            if (parser.err_msg) |msg| {
                std.debug.print("error: {s}\n", .{msg});
                std.debug.print("{} | {s}\n", .{ line_count + 1, line });
            }
            return err;
        };
    }

    // parse instructions
    try self.binary.ensureTotalCapacity(self.allocator, binary_size);
    lines = std.mem.splitScalar(u8, source, '\n');
    line_count = 0;

    while (lines.next()) |line| : (line_count += 1) {
        var parser = Parser{ .buf = line };
        self.parseInst(&parser) catch |err| {
            if (parser.err_msg) |msg| {
                std.debug.print("error: {s}\n", .{msg});
                std.debug.print("{} | {s}\n", .{ line_count + 1, line });
            }
            return err;
        };

        const last = try parser.token();
        if (last.data != .eof) {
            return error.ParseError;
        }
    }
}

fn parseLabel(self: *Self, parser: *Parser, binary_size: usize) Error!usize {
    var size = binary_size;
    var token = try parser.token();

    while (token.data != .eof) : (token = try parser.token()) {
        switch (token.data) {
            .eof => break,
            .ident => |name| {
                if (!std.mem.endsWith(u8, name, ":")) {
                    continue;
                }

                if (name.len <= 1) {
                    return parser.err("Label name is too short", .{});
                }

                if (self.labels.contains(name)) {
                    return parser.err("Label \"{s}\" already exists", .{name});
                }

                const key = name[0 .. name.len - 1];
                try self.labels.put(self.allocator, key, null);
            },

            .keyword => |keyword| {
                size = switch (keyword) {
                    .@".i8", .@".i16", .@".i32", .@".i64" => size,
                    else => (size + 3) & ~@as(usize, 0x3),
                };

                // store label(s) offsets
                var iter = self.labels.valueIterator();
                while (iter.next()) |value| {
                    if (value.* == null) {
                        value.* = size;
                    }
                }

                // increment by size
                size += switch (keyword) {
                    .@".i8" => @sizeOf(i8),
                    .@".i16" => @sizeOf(i16),
                    .@".i32" => @sizeOf(i32),
                    .@".i64" => @sizeOf(i64),
                    else => @sizeOf(Inst),
                };
            },
            else => {},
        }
    }

    return size;
}

fn parseInst(self: *Self, parser: *Parser) Error!void {
    const first = try parser.token();
    switch (first.data) {
        .ident => |ident| {
            if (std.mem.endsWith(u8, ident, ":")) {
                return;
            }

            return parser.err("Unexpected identifier {s}", .{ident});
        },
        .keyword => |keyword| {
            switch (keyword) {
                // constants
                .@".i8" => try parseConstant(self, parser, i8),
                .@".i16" => try parseConstant(self, parser, i16),
                .@".i32" => try parseConstant(self, parser, i32),
                .@".i64" => try parseConstant(self, parser, i64),

                // nop
                .nop => try self.inst(Inst{ .move_imm = .{
                    .dst = .rZ,
                    .mode = .imm,
                    .imm = 0,
                } }),

                // mov rd, i21
                .mov => try self.parseMovInstr(parser),
                .@"aui.pc" => try self.parseAddPCInstr(parser),

                // and.i32 rd, ra, i12
                // sub.i64, ra, rb
                .@"and.i32",
                .@"or.i32",
                .@"xor.i32",
                .@"shl.i32",
                .@"shr.u32",
                .@"shr.s32",
                .@"add.i32",
                .@"sub.i32",
                .@"mul.i32",
                .@"div.u32",
                .@"div.s32",
                .@"mod.u32",
                .@"mod.s32",
                .@"and.i64",
                .@"or.i64",
                .@"xor.i64",
                .@"shl.i64",
                .@"shr.u64",
                .@"shr.s64",
                .@"add.i64",
                .@"sub.i64",
                .@"mul.i64",
                .@"div.u64",
                .@"div.s64",
                .@"mod.u64",
                .@"mod.s64",
                => try self.parseProcessInstr(parser, keyword),

                // ldr.s32 rd, ra
                // ldr.u32 rd, ra + i14
                .@"ldr.u8",
                .@"ldr.s8",
                .@"ldr.u16",
                .@"ldr.s16",
                .@"ldr.u32",
                .@"ldr.s32",
                .@"ldr.i64",
                .@"str.i8",
                .@"str.i16",
                .@"str.i32",
                .@"str.i64",
                => try self.parseMemoryInstr(parser, keyword),

                // ldm r0, r1, r2, r3, r4
                .@"ldm.s8",
                .@"ldm.u8",
                .@"ldm.s16",
                .@"ldm.u16",
                .@"ldm.s32",
                .@"ldm.u32",
                .@"ldm.i64",
                .@"stm.i8",
                .@"stm.i16",
                .@"stm.i32",
                .@"stm.i64",
                => {
                    const base = try parser.register("base");
                    try parser.operator(.@",");
                    try self.parseMemoryMultiInstr(parser, base, keyword);
                },

                // psh r0, r2, r4, ...
                .psh, .pop => try self.parseMemoryMultiInstr(parser, .rSP, keyword),

                // bltu ra, rb, i13
                .@"bra.eq",
                .@"bra.ne",
                .@"bra.ltu",
                .@"bra.leu",
                .@"bra.gtu",
                .@"bra.geu",
                .@"bra.lts",
                .@"bra.les",
                .@"bra.gts",
                .@"bra.ges",
                => try self.parseBranchInstr(parser, keyword),

                // jmp offset
                // jmp rl, offset
                .jmp => try self.parseJumpInstr(parser),

                // ctl.w xhwi, 0
                .@"ctl.w", .@"ctl.r", .@"ctl.s", .@"ctl.u" => try self.parseCtlInstr(parser, keyword),

                // irq.sw 0x0
                .@"irq.sw", .@"irq.ret" => try self.parseIrqInstr(parser),
            }
        },

        .eof => {},
        else => return error.ParseError,
    }
}

fn parseConstant(self: *Self, parser: *Parser, comptime I: type) Error!void {
    const token = try parser.token();
    const value = switch (token.data) {
        .ident => |ident| @as(i64, @bitCast(@as(u64, try self.findLabelAbsolute(parser, ident)))),
        .integer => |val| val,

        else => return parser.err("Value must be a known comptime-time constant", .{}),
    };

    try self.int(I, @truncate(value));
}

fn parseMovInstr(self: *Self, parser: *Parser) Error!void {
    const dst_reg = try parser.register("dst");
    try parser.operator(.@",");

    try self.inst(Inst{ .move_imm = .{
        .dst = dst_reg,
        .mode = .imm,
        .imm = try parser.integer(i21),
    } });
}

fn parseAddPCInstr(self: *Self, parser: *Parser) Error!void {
    const dst_reg = try parser.register("dst");
    try parser.operator(.@",");

    const tok = try parser.token();
    var offset: i23 = 0;

    switch (tok.data) {
        .ident => |name| offset = try self.findLabelRelative(parser, name, i23),
        .integer => |val| offset = @truncate(val),
        else => return parser.err("Unexpected {t}", .{tok.data}),
    }

    try self.inst(Inst{ .addpc = .{
        .dst = dst_reg,
        .offset = offset,
    } });
}

fn parseProcessInstr(self: *Self, parser: *Parser, keyword: Token.Keyword) Error!void {
    const dst_reg = try parser.register("dst");
    try parser.operator(.@",");
    const lhs_reg = try parser.register("lhs");
    try parser.operator(.@",");

    const code: ProcessCode = switch (keyword) {
        .@"and.i32", .@"and.i64" => .@"and",
        .@"or.i32", .@"or.i64" => .@"or",
        .@"xor.i32", .@"xor.i64" => .xor,
        .@"shl.i32", .@"shl.i64" => .lsl,
        .@"shr.u32", .@"shr.u64" => .lsr,
        .@"shr.s32", .@"shr.s64" => .asr,
        .@"add.i32", .@"add.i64" => .add,
        .@"sub.i32", .@"sub.i64" => .sub,
        .@"mul.i32", .@"mul.i64" => .mul,
        .@"div.u32", .@"div.u64" => .divu,
        .@"div.s32", .@"div.s64" => .divs,
        .@"mod.u32", .@"mod.u64" => .modu,
        .@"mod.s32", .@"mod.s64" => .mods,
        else => unreachable,
    };

    const mode: MemorySize1 = switch (keyword) {
        .@"and.i32",
        .@"or.i32",
        .@"xor.i32",
        .@"shl.i32",
        .@"shr.u32",
        .@"shr.s32",
        .@"add.i32",
        .@"sub.i32",
        .@"mul.i32",
        .@"div.u32",
        .@"div.s32",
        .@"mod.u32",
        .@"mod.s32",
        => .m32,
        else => .m64,
    };

    const tok = try parser.token();
    switch (tok.data) {
        .integer => |value_imm| {
            const value = try parser.intCast(i12, value_imm);

            try self.inst(Inst{ .process_imm = .{
                .code = code,
                .size = mode,
                .dst = dst_reg,
                .lhs = lhs_reg,
                .imm = value,
            } });
        },
        .reg => |rhs_reg| {
            var amount: u6 = 0;
            var shift: ShiftType = .lsl;

            const op_tok = try parser.peek();
            switch (op_tok.data) {
                .@"<<", .@">>" => {
                    parser.skip(); // consume token

                    shift = switch (op_tok.data) {
                        .@"<<" => .lsl,
                        .@">>" => .lsr,
                        else => unreachable,
                    };

                    amount = try parser.integer(u6);
                },
                else => {},
            }

            try self.inst(Inst{ .process_reg = .{
                .code = code,
                .size = mode,
                .dst = dst_reg,
                .lhs = lhs_reg,
                .value = rhs_reg,
                .shift = shift,
                .amount = amount,
            } });
        },
        else => return parser.err("Unexpected {t}", .{tok.data}),
    }
}

fn parseMemoryInstr(self: *Self, parser: *Parser, Keyword: Token.Keyword) Error!void {
    const value_reg = try parser.register("value");
    try parser.operator(.@",");
    const base_reg = try parser.register("base");

    var offset: i14 = 0;
    if (try parser.expect(.@"+")) |_| {
        offset = try parser.integer(i14);
    }

    const mode: MemorySize2 = switch (Keyword) {
        .@"ldr.u8", .@"ldr.s8", .@"str.i8" => .m8,
        .@"ldr.u16", .@"ldr.s16", .@"str.i16" => .m16,
        .@"ldr.u32", .@"ldr.s32", .@"str.i32" => .m32,
        .@"ldr.i64", .@"str.i64" => .m64,
        else => unreachable,
    };

    const signed = switch (Keyword) {
        .@"ldr.s8", .@"ldr.s16", .@"ldr.s32" => true,
        else => false,
    };

    const store = switch (Keyword) {
        .@"str.i8", .@"str.i16", .@"str.i32", .@"str.i64" => true,
        else => false,
    };

    try self.inst(Inst{ .memory = .{
        .mode = mode,
        .signed = signed,
        .store = store,

        .value = value_reg,
        .base = base_reg,
        .offset = offset,
    } });
}

fn parseMemoryMultiInstr(self: *Self, parser: *Parser, base: Reg, keyword: Token.Keyword) Error!void {
    var reg = try parser.register("reg");
    var bitmask: u18 = @as(u18, 1) << @intFromEnum(reg);

    for (0..@bitSizeOf(@TypeOf(bitmask)) - 1) |_| {
        try parser.expect(.@",") orelse break;
        reg = try parser.register("reg");

        if ((bitmask & (@as(@TypeOf(bitmask), 1) << @intFromEnum(reg))) != 0) {
            return parser.err("Register {t} is already present in the list", .{reg});
        }

        bitmask |= (@as(@TypeOf(bitmask), 1) << @intFromEnum(reg));
    }

    const size: MemorySize2 = switch (keyword) {
        .@"ldm.s8", .@"ldm.u8", .@"stm.i8" => .m8,
        .@"ldm.s16", .@"ldm.u16", .@"stm.i16" => .m16,
        .@"ldm.s32", .@"ldm.u32", .@"stm.i32" => .m32,
        else => .m64,
    };

    const store = switch (keyword) {
        .@"stm.i8",
        .@"stm.i16",
        .@"stm.i32",
        .@"stm.i64",
        .psh,
        => true,
        else => false,
    };

    try self.inst(Inst{ .memory_multi = .{
        .size = size,
        .base = base,
        .signed = false,
        .store = store,
        .lifo = true,
        .bitmask = bitmask,
    } });
}

fn parseBranchInstr(self: *Self, parser: *Parser, keyword: Token.Keyword) Error!void {
    var lhs_reg = try parser.register("lhs");
    try parser.operator(.@",");
    var rhs_reg = try parser.register("rhs");
    try parser.operator(.@",");

    const flags: CompareFlags = switch (keyword) {
        .@"bra.eq" => CompareFlags{ .compare = false, .flip = false, .signed = false },
        .@"bra.ne" => CompareFlags{ .compare = false, .flip = true, .signed = false },
        .@"bra.ltu", .@"bra.gtu" => CompareFlags{ .compare = true, .flip = false, .signed = false },
        .@"bra.geu", .@"bra.leu" => CompareFlags{ .compare = true, .flip = true, .signed = false },
        .@"bra.lts", .@"bra.gts" => CompareFlags{ .compare = true, .flip = false, .signed = true },
        .@"bra.ges", .@"bra.les" => CompareFlags{ .compare = true, .flip = true, .signed = true },
        else => unreachable,
    };

    switch (keyword) {
        .@"bra.gtu", .@"bra.leu", .@"bra.gts", .@"bra.les" => std.mem.swap(Reg, &lhs_reg, &rhs_reg),
        else => {},
    }

    const tok = try parser.token();
    var offset: i15 = 0;

    switch (tok.data) {
        .ident => |name| offset = try self.findLabelRelative(parser, name, i15) >> 2,
        .integer => |val| offset = try parser.intCast(i15, val),
        else => return parser.err("Unexpected {t}", .{tok.data}),
    }

    try self.inst(Inst{ .branch = .{
        .lhs = lhs_reg,
        .rhs = rhs_reg,
        .flags = flags,
        .offset = offset,
    } });
}

fn parseJumpInstr(self: *Self, parser: *Parser) Error!void {
    const link_reg = try parser.register("link");
    try parser.operator(.@",");

    const tok = try parser.token();
    switch (tok.data) {
        .ident => |name| {
            try self.inst(Inst{ .jump_rel = .{
                .link = link_reg,
                .offset = try self.findLabelRelative(parser, name, i23) >> 2,
            } });
        },

        .integer => |val| {
            try self.inst(Inst{ .jump_rel = .{
                .link = link_reg,
                .offset = @truncate(val),
            } });
        },

        .reg => |base| {
            try self.inst(Inst{ .jump_reg = .{
                .link = link_reg,
                .base = base,
                .offset = try parser.integer(i18),
            } });
        },

        else => return parser.err("Unexpected {t}", .{tok.data}),
    }
}

fn parseIrqInstr(self: *Self, parser: *Parser) Error!void {
    if (try parser.expect(.integer)) |val| {
        try self.inst(Inst{ .irq = .{
            .mode = .swi,
            .code = @truncate(@as(u64, @bitCast(val))),
        } });
    } else {
        try self.inst(Inst{ .irq = .{
            .mode = .ret,
        } });
    }
}

fn parseCtlInstr(self: *Self, parser: *Parser, keyword: Token.Keyword) Error!void {
    const ctl_reg = try parser.ctlRegister("control register");

    try parser.operator(.@",");
    const val_reg = try parser.register("value");

    const mode: CtlMode = switch (keyword) {
        .@"ctl.w" => .write,
        .@"ctl.r" => .read,
        .@"ctl.s" => .set,
        .@"ctl.u" => .unset,
        else => unreachable,
    };

    try self.inst(Inst{ .ctl = .{
        .mode = mode,
        .target = ctl_reg,
        .reg = val_reg,
    } });
}

fn findLabelAbsolute(self: *Self, parser: *Parser, name: []const u8) Error!usize {
    if (!std.mem.startsWith(u8, name, ".")) {
        return parser.err("Unexpected {s}", .{name});
    }

    const key = name[1..];
    if (!self.labels.contains(key)) {
        return parser.err("Label \"{s}\" does not exist", .{key});
    }

    return self.labels.get(key).? orelse {
        return parser.err("Label \"{s}\" exists, but has no defined address", .{key});
    };
}

fn findLabelRelative(self: *Self, parser: *Parser, name: []const u8, comptime I: type) Error!I {
    const addr = try findLabelAbsolute(self, parser, name);
    const pc = (self.binary.items.len + @sizeOf(Inst) + 3) & ~@as(usize, 0x3);
    return try parser.intCast(I, @as(i64, @bitCast(@as(u64, addr -% pc))));
}

fn write(self: *Self, values: []const u8) Error!void {
    try self.binary.appendSlice(self.allocator, values);
}

fn inst(self: *Self, instr: Inst) Error!void {
    const offset = self.binary.items.len % @sizeOf(Inst);
    if (offset != 0) {
        try self.binary.appendNTimes(self.allocator, 0, @sizeOf(Inst) - offset);
    }
    try self.int(u32, @bitCast(instr));
}

fn int(self: *Self, comptime T: type, value: T) Error!void {
    try self.write(@ptrCast(&if (target_endian == .little) value else @byteSwap(value)));
}
