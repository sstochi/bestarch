const std = @import("std");
const builtin = @import("builtin");
const target_endian = builtin.target.cpu.arch.endian();

const Token = @import("Token.zig");
const Parser = @import("Parser.zig");
const isa = @import("../isa.zig");
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
    FileNotFound,
};

allocator: std.mem.Allocator,
labels: std.StringHashMapUnmanaged(usize) = .empty,
pending_labels: std.ArrayList([]const u8) = .empty,
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

pub fn resolveLabels(self: *Self, addr: usize) void {
    for (self.pending_labels.items) |label| {
        std.debug.print("label {s}: {}\n", .{ label, addr });
        self.labels.putAssumeCapacity(label, addr);
    }
    self.pending_labels.clearRetainingCapacity();
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

    self.resolveLabels(binary_size);

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

                const key = name[0 .. name.len - 1];
                const entry = try self.labels.getOrPut(self.allocator, key);
                if (entry.found_existing) {
                    return parser.err("Found existing label", .{});
                }

                try self.pending_labels.append(self.allocator, key);
            },

            .keyword => |keyword| {
                size = switch (keyword) {
                    .@".i8", .@".i16", .@".i32", .@".i64", .@".allocz", .@".embed" => size,
                    else => (size + 3) & ~@as(usize, 0x3),
                };

                self.resolveLabels(size);

                // increment by size
                size += switch (keyword) {
                    .@".i8" => @sizeOf(i8),
                    .@".i16" => @sizeOf(i16),
                    .@".i32" => @sizeOf(i32),
                    .@".i64" => @sizeOf(i64),
                    .@".allocz" => try parser.integer(u64),
                    .@".embed" => blk: {
                        const literal = try parser.literal();
                        const stat = std.fs.cwd().statFile(literal) catch return error.FileNotFound;
                        break :blk stat.size;
                    },
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

                .@".allocz" => try self.binary.appendNTimes(
                    self.allocator,
                    0,
                    try parser.integer(u64),
                ),

                .@".embed" => {
                    const literal = try parser.literal();
                    const cwd = std.fs.cwd();

                    const stat = cwd.statFile(literal) catch return error.FileNotFound;
                    const start = self.binary.items.len;

                    _ = try self.binary.addManyAsSlice(self.allocator, stat.size);
                    _ = cwd.readFile(literal, self.binary.items[start..]) catch return error.FileNotFound;
                },

                // nop
                .nop => try self.inst(Inst{
                    .move_imm = .{
                        .dst = .zr,
                        .mode = .imm,
                        .imm = 0,
                    },
                }),

                // mov rd, i21
                .mov => try self.parseMovInstr(parser),
                .@"aui.pc" => try self.parseAddPCInstr(parser),

                // and.i32 rd, ra, i12
                // sub.i64, ra, rb
                .@"and.i32",
                .@"orr.i32",
                .@"xor.i32",
                .@"lsl.i32",
                .@"lsr.u32",
                .@"lsr.s32",
                .@"add.i32",
                .@"sub.i32",
                .@"mul.i32",
                .@"div.u32",
                .@"div.s32",
                .@"mod.u32",
                .@"mod.s32",
                .@"slt.u32",
                .@"slt.s32",
                .@"and.i64",
                .@"orr.i64",
                .@"xor.i64",
                .@"lsl.i64",
                .@"lsr.u64",
                .@"lsr.s64",
                .@"add.i64",
                .@"sub.i64",
                .@"mul.i64",
                .@"div.u64",
                .@"div.s64",
                .@"mod.u64",
                .@"mod.s64",
                .@"slt.u64",
                .@"slt.s64",
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

                // ldm r0, r1, rb + i9
                .@"ldp.s8",
                .@"ldp.u8",
                .@"ldp.s16",
                .@"ldp.u16",
                .@"ldp.s32",
                .@"ldp.u32",
                .@"ldp.i64",
                .@"stp.i8",
                .@"stp.i16",
                .@"stp.i32",
                .@"stp.i64",
                => try self.parseMemoryPair(parser, keyword),

                // psh r0, r2, r4, ...
                .psh, .pop => try self.parsePushPop(parser, keyword),

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

    const tok = try parser.token();
    switch (tok.data) {
        .integer => |value_imm| {
            const value = try parser.intCast(i21, value_imm);
            const op_tok = try parser.peek();

            switch (op_tok.data) {
                .shift => |t| {
                    switch (t) {
                        .lsl => {
                            parser.skip(); // consume token

                            const amount = try parser.integer(u6);
                            try self.inst(Inst{
                                .move_imm_shift = .{
                                    .dst = dst_reg,
                                    .value = try parser.intCast(i15, value),
                                    .left_amount = amount,
                                },
                            });
                        },

                        else => return parser.err("Move immediate only supports logical shift left operation.", .{}),
                    }
                },

                .eof => {
                    try self.inst(Inst{
                        .move_imm = .{
                            .dst = dst_reg,
                            .imm = value,
                        },
                    });
                },

                else => return parser.err("Expected lsl, found {t}", .{tok.data}),
            }
        },
        .reg => |rhs_reg| {
            var left_amount: u6 = 0;
            var right_amount: u6 = 0;
            var signed: bool = false;

            if (try parser.expect(.shift)) |t| {
                left_amount = try parser.integer(u6);

                switch (t) {
                    .lsr, .asr => {
                        parser.skip(); // consume token

                        signed = t == .asr;
                        right_amount = try parser.integer(u6);
                    },
                    else => return parser.err("Expected logical shift left or arithmetic shift right, found {t}", .{tok.data}),
                }
            }

            try self.inst(Inst{
                .move_reg = .{
                    .dst = dst_reg,
                    .value = rhs_reg,
                    .left_amount = left_amount,
                    .signed = signed,
                    .right_amount = right_amount,
                },
            });
        },
        else => return parser.err("Unexpected {t}", .{tok.data}),
    }
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

    try self.inst(Inst{
        .addpc = .{
            .dst = dst_reg,
            .offset = offset,
        },
    });
}

fn parseProcessInstr(self: *Self, parser: *Parser, keyword: Token.Keyword) Error!void {
    const dst_reg = try parser.register("dst");
    try parser.operator(.@",");
    const lhs_reg = try parser.register("lhs");
    try parser.operator(.@",");

    const code: ProcessCode = switch (keyword) {
        .@"and.i32", .@"and.i64" => .@"and",
        .@"orr.i32", .@"orr.i64" => .@"or",
        .@"xor.i32", .@"xor.i64" => .xor,
        .@"lsl.i32", .@"lsl.i64" => .shl,
        .@"lsr.u32", .@"lsr.u64" => .shr,
        .@"lsr.s32", .@"lsr.s64" => .asr,
        .@"add.i32", .@"add.i64" => .add,
        .@"sub.i32", .@"sub.i64" => .sub,
        .@"mul.i32", .@"mul.i64" => .mul,
        .@"div.u32", .@"div.u64" => .divu,
        .@"div.s32", .@"div.s64" => .divs,
        .@"mod.u32", .@"mod.u64" => .modu,
        .@"mod.s32", .@"mod.s64" => .mods,
        .@"slt.u32", .@"slt.u64" => .sltu,
        .@"slt.s32", .@"slt.s64" => .slts,
        else => unreachable,
    };

    const mode: MemorySize1 = switch (keyword) {
        .@"and.i32",
        .@"orr.i32",
        .@"xor.i32",
        .@"lsl.i32",
        .@"lsr.u32",
        .@"lsr.s32",
        .@"add.i32",
        .@"sub.i32",
        .@"mul.i32",
        .@"div.u32",
        .@"div.s32",
        .@"mod.u32",
        .@"mod.s32",
        .@"slt.u32",
        .@"slt.s32",
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

            if (try parser.expect(.shift)) |t| {
                shift = switch (t) {
                    .lsl => .lsl,
                    .lsr => .lsr,
                    else => return parser.err("Process instruction group doesn't support arithmetic shift right operation.", .{}),
                };

                amount = try parser.integer(u6);
            }

            try self.inst(Inst{
                .process_reg = .{
                    .code = code,
                    .size = mode,
                    .dst = dst_reg,
                    .lhs = lhs_reg,
                    .value = rhs_reg,
                    .shift = shift,
                    .amount = amount,
                },
            });
        },
        else => return parser.err("Unexpected {t}", .{tok.data}),
    }
}

fn parseMemoryInstr(self: *Self, parser: *Parser, Keyword: Token.Keyword) Error!void {
    const value_reg = try parser.register("value");
    try parser.operator(.@",");
    const base_reg = try parser.register("base");

    var offset: i13 = 0;
    var post_inc: bool = false;

    if (try parser.expect(.@"+")) |_| {
        offset = try parser.integer(i13);
        if (try parser.expect(.@"!")) |_| {
            post_inc = true;
        }
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

    try self.inst(Inst{
        .memory = .{
            .mode = mode,
            .signed = signed,
            .store = store,
            .post_inc = post_inc,

            .value = value_reg,
            .base = base_reg,
            .offset = offset,
        },
    });
}

fn parsePushPop(self: *Self, parser: *Parser, keyword: Token.Keyword) Error!void {
    const value = try parser.register("value");

    const store = switch (keyword) {
        .psh => true,
        .pop => false,
        else => unreachable,
    };

    const offset: i13 = switch (keyword) {
        .psh => -@sizeOf(u64),
        .pop => @sizeOf(u64),
        else => unreachable,
    };

    try self.inst(Inst{
        .memory = .{
            .mode = .m64,
            .signed = false,
            .store = store,
            .post_inc = store,
            .value = value,
            .base = .sp,
            .offset = offset,
        },
    });
}

fn parseMemoryPair(self: *Self, parser: *Parser, keyword: Token.Keyword) Error!void {
    const value_a = try parser.register("value A");
    try parser.operator(.@",");
    const value_b = try parser.register("value B");
    try parser.operator(.@",");

    const base = try parser.register("base");

    var offset: i8 = 0;
    var post_inc: bool = false;

    if (try parser.expect(.@"+")) |_| {
        offset = try parser.integer(i8);
        if (try parser.expect(.@"!")) |_| {
            post_inc = true;
        }
    }

    const mode: MemorySize2 = switch (keyword) {
        .@"ldp.s8", .@"ldp.u8", .@"stp.i8" => .m8,
        .@"ldp.s16", .@"ldp.u16", .@"stp.i16" => .m16,
        .@"ldp.s32", .@"ldp.u32", .@"stp.i32" => .m32,
        else => .m64,
    };

    const signed = switch (keyword) {
        .@"ldp.s8", .@"ldp.s16", .@"ldp.s32" => true,
        else => false,
    };

    const store = switch (keyword) {
        .@"stp.i8",
        .@"stp.i16",
        .@"stp.i32",
        .@"stp.i64",
        => true,
        else => false,
    };

    try self.inst(Inst{
        .memory_pair = .{
            .mode = mode,
            .signed = signed,
            .store = store,
            .post_inc = post_inc,
            .value_a = value_a,
            .value_b = value_b,
            .base = base,
            .offset = offset,
        },
    });
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

    try self.inst(Inst{
        .branch = .{
            .lhs = lhs_reg,
            .rhs = rhs_reg,
            .flags = flags,
            .offset = offset,
        },
    });
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
            var offset: i18 = 0;
            if (try parser.expect(.@"+")) |_| {
                offset = try parser.integer(i18);
            }

            try self.inst(Inst{
                .jump_reg = .{
                    .link = link_reg,
                    .base = base,
                    .offset = offset,
                },
            });
        },

        else => return parser.err("Unexpected {t}", .{tok.data}),
    }
}

fn parseIrqInstr(self: *Self, parser: *Parser) Error!void {
    if (try parser.expect(.integer)) |val| {
        try self.inst(Inst{
            .irq = .{
                .mode = .swi,
                .code = @truncate(@as(u64, @bitCast(val))),
            },
        });
    } else {
        try self.inst(Inst{
            .irq = .{
                .mode = .ret,
            },
        });
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

    try self.inst(Inst{
        .ctl = .{
            .mode = mode,
            .target = ctl_reg,
            .reg = val_reg,
        },
    });
}

fn findLabelAbsolute(self: *Self, parser: *Parser, name: []const u8) Error!usize {
    if (!std.mem.startsWith(u8, name, ".")) {
        return parser.err("Unexpected {s}", .{name});
    }

    const key = name[1..];
    return self.labels.get(key) orelse {
        return parser.err("Label \"{s}\" does not exist", .{key});
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
