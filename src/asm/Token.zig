const isa = @import("../cpu/isa.zig");
const Assembler = @import("Assembler.zig");
const Reg = isa.Reg;
const CtlReg = isa.CtlReg;

const Self = @This();

pub const Keyword = enum(u8) {
    @".i8",
    @".i16",
    @".i32",
    @".i64",
    @".allocz",
    @".embed",

    nop,
    mov,
    @"aui.pc",

    @"and.i32",
    @"or.i32",
    @"xor.i32",
    @"lsl.i32",
    @"lsr.u32",
    @"lsr.s32",
    @"add.i32",
    @"sub.i32",
    @"mul.i32",
    @"div.u32",
    @"div.s32",
    @"mod.u32",
    @"mod.s32",
    @"slt.u32",
    @"slt.s32",

    @"and.i64",
    @"or.i64",
    @"xor.i64",
    @"lsl.i64",
    @"lsr.u64",
    @"lsr.s64",
    @"add.i64",
    @"sub.i64",
    @"mul.i64",
    @"div.u64",
    @"div.s64",
    @"mod.u64",
    @"mod.s64",
    @"slt.u64",
    @"slt.s64",

    @"bra.eq",
    @"bra.ne",
    @"bra.ltu",
    @"bra.leu",
    @"bra.gtu",
    @"bra.geu",
    @"bra.lts",
    @"bra.les",
    @"bra.gts",
    @"bra.ges",
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

    @"ldp.u8",
    @"ldp.s8",
    @"ldp.u16",
    @"ldp.s16",
    @"ldp.u32",
    @"ldp.s32",
    @"ldp.i64",
    @"stp.i8",
    @"stp.i16",
    @"stp.i32",
    @"stp.i64",

    psh,
    pop,

    @"ctl.w",
    @"ctl.r",
    @"ctl.s",
    @"ctl.u",

    @"irq.sw",
    @"irq.ret",
};

pub const Shift = enum {
    lsl,
    lsr,
    asr,
};

pub const Data = union(enum) {
    // whitespace,
    ident: []const u8,
    literal: []const u8,
    integer: i64,

    @":",
    @".",
    @",",
    @"+",
    @"!",

    reg: Reg,
    ctl_reg: CtlReg,
    keyword: Keyword,
    shift: Shift,

    eof,
};
pub const Kind = @typeInfo(Data).@"union".tag_type.?;

data: Data,
source: []const u8,

pub fn unwrap(self: Self, comptime kind: Kind) Assembler.Error!@FieldType(Data, @tagName(kind)) {
    if (@as(Data, self.data) != kind) return error.ParseError;
    return @field(self.data, @tagName(kind));
}
