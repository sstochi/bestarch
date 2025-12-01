const std = @import("std");
const builtin = @import("builtin");
const target_endian = builtin.target.cpu.arch.endian();

const isa = @import("cpu/isa.zig");
const Instruction = isa.Instruction;
const ProcessCode = isa.ProcessCode;
const ProcessMode1 = isa.ProcessMode1;
const ProcessMode2 = isa.ProcessMode2;
const ShiftType = isa.ShiftType;
const CompareFlags = isa.CompareFlags;
const Register = isa.Register;
const CtlRegister = isa.CtlRegister;
const CtlMode = isa.CtlMode;

const allocator = std.heap.page_allocator;
const error_immediate_too_big = "Immediate value {} doesn't fit into an integer of type {s}";

const Error = error{
    OutOfMemory,
    NoSpaceLeft,
    ParseError,
};

const InstKind = enum(u8) {
    @".i8",
    @".i16",
    @".i32",
    @".i64",

    nop,
    mov,
    @"add.pc",

    @"and.i32",
    @"or.i32",
    @"xor.i32",
    @"shl.i32",
    @"shr.u32",
    @"shr.s32",
    @"add.i32",
    @"sub.i32",
    @"mul.i32",
    @"div.u32",
    @"div.s32",
    @"mod.u32",
    @"mod.s32",

    @"and.i64",
    @"or.i64",
    @"xor.i64",
    @"shl.i64",
    @"shr.u64",
    @"shr.s64",
    @"add.i64",
    @"sub.i64",
    @"mul.i64",
    @"div.u64",
    @"div.s64",
    @"mod.u64",
    @"mod.s64",

    @"b.eq",
    @"b.ne",
    @"b.ltu",
    @"b.leu",
    @"b.gtu",
    @"b.geu",
    @"b.lts",
    @"b.les",
    @"b.gts",
    @"b.ges",
    jmp,

    @"ldr.u8",
    @"ldr.s8",
    @"ldr.u16",
    @"ldr.s16",
    @"ldr.u32",
    @"ldr.s32",
    @"ldr.i64",

    @"str.i8",
    @"str.i16",
    @"str.i32",
    @"str.i64",

    @"ctl.w",
    @"ctl.r",
    @"ctl.s",
    @"ctl.u",

    @"irq.sw",
    @"irq.ret",
};

const TokenData = union(enum) {
    // whitespace,
    ident: []const u8,
    integer: i64,

    @":",
    @".",
    @",",
    @"+",
    @"<<",
    @">>",

    reg: Register,
    inst: InstKind,

    eof,
};

const TokenKind = @typeInfo(TokenData).@"union".tag_type.?;

const Token = struct {
    data: TokenData,
    source: []const u8,

    fn unwrap(self: Token, comptime kind: TokenKind) Error!@FieldType(TokenData, @tagName(kind)) {
        if (@as(TokenData, self.data) != kind) return error.ParseError;
        return @field(self.data, @tagName(kind));
    }
};

const Parser = struct {
    buf: []const u8,
    idx: usize = 0,
    next_token: ?Token = null,

    err_msg: ?[]u8 = null,
    err_buf: [512]u8 = undefined,

    fn skipByte(self: *Parser) void {
        std.debug.assert(self.idx < self.buf.len);
        self.idx += 1;
    }

    fn nextByte(self: *Parser) u8 {
        if (self.idx >= self.buf.len) return '\x00';
        self.skipByte();
        return self.buf[self.idx - 1];
    }

    fn peekByte(self: *Parser) u8 {
        if (self.idx >= self.buf.len) return '\x00';
        return self.buf[self.idx];
    }

    fn takeByte(self: *Parser, byte: u8) bool {
        if (self.peekByte() != byte) return false;
        self.skipByte();
        return true;
    }

    fn token(self: *Parser) Error!Token {
        while (true) {
            if (self.next_token) |next| {
                self.next_token = null;
                return next;
            }

            const start = self.idx;
            const c = self.nextByte();

            const kind: TokenData = b: switch (c) {
                ' ', '\t'...'\r' => {
                    while (true) {
                        const n = self.peekByte();
                        switch (n) {
                            ' ', '\t'...'\r' => self.skipByte(),
                            else => break,
                        }
                    }
                    continue;
                },
                '#' => {
                    while (true) {
                        switch (self.nextByte()) {
                            '\x00', '\n' => break,
                            else => {},
                        }
                    }
                    continue;
                },
                '_', '.', ':', 'a'...'z', 'A'...'Z' => {
                    while (true) {
                        const n = self.peekByte();
                        switch (n) {
                            '_', '.', ':', 'a'...'z', 'A'...'Z', '0'...'9' => self.skipByte(),
                            else => break,
                        }
                    }
                    const source = self.buf[start..self.idx];
                    if (std.meta.stringToEnum(Register, source)) |reg| break :b TokenData{ .reg = reg };
                    if (std.meta.stringToEnum(InstKind, source)) |inst| break :b TokenData{ .inst = inst };
                    break :b TokenData{ .ident = source };
                },
                '-', '0'...'9' => {
                    const neg = c == '-';

                    var consumed: usize = 0;
                    var value: i64 = 0;
                    var base: u8 = 10;

                    if (!neg) self.idx = start;

                    const s = self.idx;

                    if (self.takeByte('0')) {
                        if (self.takeByte('b')) {
                            base = 2;
                        } else if (self.takeByte('x')) {
                            base = 16;
                        } else {
                            self.idx = s;
                        }
                    }

                    while (true) : (consumed += 1) {
                        const n = self.peekByte();
                        switch (n) {
                            '0'...'9', 'A'...'Z', 'a'...'z' => self.skipByte(),
                            else => break,
                        }
                        value *%= base;
                        value += std.fmt.charToDigit(n, base) catch return error.ParseError;
                    }

                    if (consumed < 1) return error.ParseError;

                    if (neg) {
                        value = -%value;
                    }

                    break :b TokenData{ .integer = value };
                },
                ',' => .@",",
                '+' => .@"+",
                '<' => if (self.takeByte('<')) .@"<<" else return error.ParseError,
                '>' => if (self.takeByte('>')) .@">>" else return error.ParseError,
                '\x00' => .eof,
                else => return self.err("Unexpected token: {c}", .{c}),
            };
            const source = self.buf[start..self.idx];
            return Token{ .data = kind, .source = source };
        }
    }

    fn peek(self: *Parser) Error!Token {
        const t = try self.token();
        self.next_token = t;
        return t;
    }

    fn skip(self: *Parser) void {
        std.debug.assert(self.next_token != null);
        self.next_token = null;
    }

    fn expect(self: *Parser, comptime kind: TokenKind) Error!?@FieldType(TokenData, @tagName(kind)) {
        const t = try self.peek();
        if (@as(TokenKind, t.data) != kind) return null;
        self.skip();
        return @field(t.data, @tagName(kind));
    }

    fn err(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.err_msg = try std.fmt.bufPrint(&self.err_buf, fmt, args);
        return error.ParseError;
    }

    fn intCast(self: *Parser, comptime T: type, value: i64) Error!T {
        return std.math.cast(T, value) orelse {
            return self.err("Immediate value {} doesn't fit into an integer of type {s}", .{ value, @typeName(T) });
        };
    }

    fn integer(self: *Parser, comptime T: type) Error!T {
        const value = try self.expect(.integer) orelse {
            return self.err("Expected an immediate of type {s}", .{@typeName(T)});
        };
        return try self.intCast(T, value);
    }

    fn register(self: *Parser, name: []const u8) Error!Register {
        return try self.expect(.reg) orelse {
            return self.err("Expected {s} register", .{name});
        };
    }

    fn operator(self: *Parser, comptime kind: TokenKind) Error!void {
        return try self.expect(kind) orelse {
            return self.err("Expected {t}", .{kind});
        };
    }

    fn checkLabel(self: *Parser, name: []const u8) Error![]const u8 {
        if (!std.mem.startsWith(u8, name, ".")) {
            return self.err("Expected a . before label name", .{});
        }
        if (name.len <= 1) {
            return self.err("Empty label", .{});
        }
        return name[1..];
    }
};

const ForwardLabel = struct {
    const Kind = enum {
        addpc,
        branch,
        jump,
    };

    name: []const u8,
    source: usize,
    kind: Kind,
};

const Assembler = struct {
    binary: std.ArrayList(u8) = .empty,
    labels: std.StringHashMapUnmanaged(usize) = .empty,
    forward_labels: std.ArrayList(ForwardLabel) = .empty,

    fn write(self: *Assembler, values: []const u8) Error!void {
        try self.binary.appendSlice(allocator, values);
    }

    fn int(self: *Assembler, comptime T: type, value: T) Error!void {
        try self.write(@ptrCast(&if (target_endian == .little) value else @byteSwap(value)));
    }

    fn inst(self: *Assembler, instr: Instruction) Error!void {
        const offset = self.binary.items.len % 4;
        if (offset != 0) try self.binary.appendNTimes(allocator, 0, 4 - offset);
        try self.int(u32, @bitCast(instr));
    }

    fn parseInst(self: *Assembler, parser: *Parser) Error!void {
        const first = try parser.token();

        if (first.data == .eof) return;
        // if (tokens.len == 0) return;

        switch (first.data) {
            .ident => |name| {
                if (!std.mem.endsWith(u8, name, ":")) {
                    return parser.err("Unexpected identifier", .{});
                }
                if (name.len <= 1) {
                    return parser.err("Empty label", .{});
                }
                const label_name = name[0 .. name.len - 1];
                const entry = try self.labels.getOrPut(allocator, label_name);
                if (entry.found_existing) {
                    return parser.err("Label \"{s}\" alrady exists", .{label_name});
                }
                entry.value_ptr.* = self.binary.items.len;
            },

            .inst => |kind| {
                switch (kind) {
                    // constants
                    .@".i8" => try parseConstant(self, parser, i8),
                    .@".i16" => try parseConstant(self, parser, i16),
                    .@".i32" => try parseConstant(self, parser, i32),
                    .@".i64" => try parseConstant(self, parser, i64),

                    .nop => try self.inst(Instruction{
                        .move = .{
                            .dst = .rZ,
                            .mode = .imm,
                            .src = .{ .imm = 0 },
                        },
                    }),

                    // mov rd, i21
                    .mov => {
                        const dst_reg = try parser.register("dst");
                        try parser.operator(.@",");
                        try self.inst(Instruction{
                            .move = .{
                                .dst = dst_reg,
                                .mode = .imm,
                                .src = .{ .imm = try parser.integer(i21) },
                            },
                        });
                    },

                    .@"add.pc" => try self.parseAddPC(parser),

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
                    => try self.parseProcessInstr(parser, kind),

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
                    => try self.parseMemoryInstr(parser, kind),

                    // bltu ra, rb, i13
                    .@"b.eq",
                    .@"b.ne",
                    .@"b.ltu",
                    .@"b.leu",
                    .@"b.gtu",
                    .@"b.geu",
                    .@"b.lts",
                    .@"b.les",
                    .@"b.gts",
                    .@"b.ges",
                    => try self.parseBranchInstr(parser, kind),
                    .jmp => try self.parseJumpInstr(parser),

                    .@"ctl.w", .@"ctl.r", .@"ctl.s", .@"ctl.u" => try self.parseCtlInstr(parser, kind),
                    .@"irq.sw", .@"irq.ret" => try self.parseIrqInstr(parser),
                }
            },
            else => return error.ParseError,
        }
    }

    inline fn parseConstant(self: *Assembler, parser: *Parser, comptime I: type) Error!void {
        try self.int(I, @truncate(try parser.integer(I)));
    }

    inline fn parseAddPC(self: *Assembler, parser: *Parser) Error!void {
        const dst_reg = try parser.register("dst");
        try parser.operator(.@",");

        const tok = try parser.token();
        switch (tok.data) {
            .ident => |name| {
                try self.forward_labels.append(allocator, ForwardLabel{
                    .name = try parser.checkLabel(name),
                    .source = self.binary.items.len,
                    .kind = .addpc,
                });

                try self.inst(Instruction{ .addpc = .{
                    .dst = dst_reg,
                    .offset = undefined,
                } });
            },

            .integer => |val| {
                try self.inst(Instruction{ .addpc = .{
                    .dst = dst_reg,
                    .offset = @truncate(val),
                } });
            },

            else => return parser.err("Unexpected {t}", .{tok.data}),
        }
    }

    inline fn parseProcessInstr(self: *Assembler, parser: *Parser, kind: InstKind) Error!void {
        const dst_reg = try parser.register("dst");
        try parser.operator(.@",");
        const lhs_reg = try parser.register("lhs");
        try parser.operator(.@",");

        const code: ProcessCode = switch (kind) {
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

        const mode: ProcessMode1 = switch (kind) {
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

        const lhs_tok = try parser.token();
        switch (lhs_tok.data) {
            .integer => |value_imm| {
                const value = std.math.cast(i12, value_imm) orelse
                    return parser.err(error_immediate_too_big, .{ value_imm, @typeName(i12) });

                try self.inst(Instruction{ .process = .{
                    .code = code,
                    .mode = mode,
                    .dst = dst_reg,
                    .lhs = lhs_reg,
                    .rhs_mode = .imm,
                    .rhs = .{ .imm = value },
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

                try self.inst(Instruction{ .process = .{
                    .code = code,
                    .mode = mode,
                    .dst = dst_reg,
                    .lhs = lhs_reg,
                    .rhs_mode = .reg,
                    .rhs = .{ .reg = .{
                        .value = rhs_reg,
                        .shift = shift,
                        .amount = amount,
                    } },
                } });
            },
            else => {
                const Rhs = @FieldType(Instruction.Process, "rhs");
                return parser.err("Instruction takes either a shifted register or a {}-bit immediate offset!", .{
                    @bitSizeOf(@FieldType(Rhs, "imm")),
                });
            },
        }
    }

    inline fn parseMemoryInstr(self: *Assembler, parser: *Parser, kind: InstKind) Error!void {
        const value_reg = try parser.register("value");
        try parser.operator(.@",");
        const base_reg = try parser.register("base");

        var offset: i14 = 0;
        if (try parser.expect(.@"+")) |_| {
            offset = try parser.integer(i14);
        }

        const mode: ProcessMode2 = switch (kind) {
            .@"ldr.u8", .@"ldr.s8", .@"str.i8" => .m8,
            .@"ldr.u16", .@"ldr.s16", .@"str.i16" => .m16,
            .@"ldr.u32", .@"ldr.s32", .@"str.i32" => .m32,
            .@"ldr.i64", .@"str.i64" => .m64,
            else => unreachable,
        };

        const signed = switch (kind) {
            .@"ldr.s8", .@"ldr.s16", .@"ldr.s32" => true,
            else => false,
        };

        const store = switch (kind) {
            .@"str.i8", .@"str.i16", .@"str.i32", .@"str.i64" => true,
            else => false,
        };

        try self.inst(Instruction{ .memory = .{
            .mode = mode,
            .signed = signed,
            .store = store,

            .value = value_reg,
            .base = base_reg,
            .offset = offset,
        } });
    }

    inline fn parseBranchInstr(self: *Assembler, parser: *Parser, kind: InstKind) Error!void {
        var lhs_reg = try parser.register("lhs");
        try parser.operator(.@",");
        var rhs_reg = try parser.register("rhs");
        try parser.operator(.@",");

        const flags: CompareFlags = switch (kind) {
            .@"b.eq" => CompareFlags{ .compare = false, .flip = false, .signed = false },
            .@"b.ne" => CompareFlags{ .compare = false, .flip = true, .signed = false },
            .@"b.ltu", .@"b.gtu" => CompareFlags{ .compare = true, .flip = false, .signed = false },
            .@"b.geu", .@"b.leu" => CompareFlags{ .compare = true, .flip = true, .signed = false },
            .@"b.lts", .@"b.gts" => CompareFlags{ .compare = true, .flip = false, .signed = true },
            .@"b.ges", .@"b.les" => CompareFlags{ .compare = true, .flip = true, .signed = true },
            else => unreachable,
        };

        switch (kind) {
            .@"b.gtu", .@"b.leu", .@"b.gts", .@"b.les" => std.mem.swap(Register, &lhs_reg, &rhs_reg),
            else => {},
        }

        const tok = try parser.token();
        var offset: i15 = 0;

        switch (tok.data) {
            .ident => |name| {
                try self.forward_labels.append(allocator, ForwardLabel{
                    .name = try parser.checkLabel(name),
                    .source = self.binary.items.len,
                    .kind = .branch,
                });
            },
            .integer => |val| offset = try parser.intCast(i15, val),
            else => return parser.err("Unexpected {t}", .{tok.data}),
        }

        try self.inst(Instruction{ .branch = .{
            .lhs = lhs_reg,
            .rhs = rhs_reg,
            .flags = flags,
            .offset = offset,
        } });
    }

    inline fn parseJumpInstr(self: *Assembler, parser: *Parser) Error!void {
        const link_reg = try parser.register("link");
        try parser.operator(.@",");

        const tok = try parser.token();
        switch (tok.data) {
            .ident => |name| {
                try self.forward_labels.append(allocator, ForwardLabel{
                    .name = try parser.checkLabel(name),
                    .source = self.binary.items.len,
                    .kind = .jump,
                });

                try self.inst(Instruction{ .jump_rel = .{
                    .link = link_reg,
                    .offset = 0,
                } });
            },

            .integer => |val| {
                try self.inst(Instruction{ .jump_rel = .{
                    .link = link_reg,
                    .offset = @truncate(val),
                } });
            },

            .reg => |base| {
                try self.inst(Instruction{ .jump_reg = .{
                    .link = link_reg,
                    .base = base,
                    .offset = try parser.integer(i18),
                } });
            },

            else => return parser.err("Unexpected {t}", .{tok.data}),
        }
    }

    inline fn parseIrqInstr(self: *Assembler, parser: *Parser) Error!void {
        if (try parser.expect(.integer)) |val| {
            try self.inst(Instruction{ .irq = .{
                .mode = .swi,
                .value = .{
                    .code = @truncate(@as(u64, @bitCast(val))),
                },
            } });
        } else {
            try self.inst(Instruction{ .irq = .{
                .mode = .ret,
                .value = .{ .ret = .{} },
            } });
        }
    }

    inline fn parseCtlInstr(self: *Assembler, parser: *Parser, kind: InstKind) Error!void {
        const name = try parser.expect(.ident) orelse {
            return parser.err("Expected a control register", .{});
        };
        const ctl_reg = std.meta.stringToEnum(CtlRegister, name) orelse {
            return parser.err("Invalid control register", .{});
        };

        try parser.operator(.@",");
        const val_reg = try parser.register("value");

        const mode: CtlMode = switch (kind) {
            .@"ctl.w" => .write,
            .@"ctl.r" => .read,
            .@"ctl.s" => .set,
            .@"ctl.u" => .unset,
            else => unreachable,
        };

        try self.inst(Instruction{ .ctl = .{
            .mode = mode,
            .target = ctl_reg,
            .reg = val_reg,
        } });
    }
};

// const std = @import("std");
// const isa = @import("cpu/isa.zig");
const Memory = @import("Memory.zig");
const Cpu = @import("cpu/Cpu.zig");
// const Instruction = isa.Instruction;

pub fn main() !void {
    const cwd = std.fs.cwd();
    const code = try cwd.readFileAlloc(allocator, "examples/test.asm", std.math.maxInt(usize));
    const binary, const labels = try assemble(code);
    const start = labels.get("_start").?;

    std.debug.print("{X}\n", .{binary});

    var memory = try Memory.create(allocator, 2048);
    @memcpy(memory.raw[0..binary.len], binary);

    var cpu = Cpu.create(&memory, start);
    try cpu.eval(binary.len);

    std.debug.print("{any}\n", .{cpu.r});
}

fn assemble(source: []const u8) Error!struct { []u8, std.StringHashMapUnmanaged(usize) } {
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var assembler = Assembler{};

    var tokens_buf: [8]Token = undefined;
    var tokens: std.ArrayList(Token) = .fromOwnedSlice(&tokens_buf);

    while (lines.next()) |line| : (line_count += 1) {
        tokens.clearRetainingCapacity();

        var parser = Parser{ .buf = line };

        assembler.parseInst(&parser) catch |err| {
            if (parser.err_msg) |msg| {
                std.debug.print("error: {s}\n", .{msg});
                std.debug.print("{} | {s}\n", .{ line_count + 1, line });
            }
            return err;
        };

        const last = try parser.token();
        if (last.data != .eof) {
            std.debug.print("Unexpected tokens after an operation or what\n", .{});
            return error.ParseError;
        }
    }

    for (assembler.forward_labels.items) |label| {
        const label_loc = assembler.labels.get(label.name) orelse {
            std.debug.print("Lable not found: {s}\n", .{label.name});
            return error.ParseError;
        };
        const inst_ref: *align(1) Instruction = @ptrCast(&assembler.binary.items[label.source]);

        var offset: i64 = @intCast(label_loc);
        offset -= @intCast(label.source + @sizeOf(Instruction));

        switch (label.kind) {
            .branch => {
                offset = @divTrunc(offset, @sizeOf(Instruction));
                inst_ref.branch.offset = std.math.cast(i15, offset) orelse {
                    std.debug.print(error_immediate_too_big, .{ offset, @typeName(i15) });
                    return error.ParseError;
                };
            },

            .jump => {
                offset = @divTrunc(offset, @sizeOf(Instruction));
                inst_ref.jump_rel.offset = std.math.cast(i23, offset) orelse {
                    std.debug.print(error_immediate_too_big, .{ offset, @typeName(i23) });
                    return error.ParseError;
                };
            },

            .addpc => {
                inst_ref.addpc.offset = std.math.cast(i23, offset) orelse {
                    std.debug.print(error_immediate_too_big, .{ offset, @typeName(i23) });
                    return error.ParseError;
                };
            },
        }
    }

    return .{ try assembler.binary.toOwnedSlice(allocator), assembler.labels };
}
