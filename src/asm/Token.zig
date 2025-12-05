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

    nop,
    mov,
    @"aui.pc",

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

    @"ldm.u8",
    @"ldm.s8",
    @"ldm.u16",
    @"ldm.s16",
    @"ldm.u32",
    @"ldm.s32",
    @"ldm.i64",
    @"stm.i8",
    @"stm.i16",
    @"stm.i32",
    @"stm.i64",
    psh,
    pop,

    @"ctl.w",
    @"ctl.r",
    @"ctl.s",
    @"ctl.u",

    @"irq.sw",
    @"irq.ret",
};

pub const Data = union(enum) {
    // whitespace,
    ident: []const u8,
    integer: i64,

    @":",
    @".",
    @",",
    @"+",
    @"<<",
    @">>",

    reg: Reg,
    ctl_reg: CtlReg,
    keyword: Keyword,

    eof,
};
pub const Kind = @typeInfo(Data).@"union".tag_type.?;

data: Data,
source: []const u8,

pub fn unwrap(self: Self, comptime kind: Kind) Assembler.Error!@FieldType(Data, @tagName(kind)) {
    if (@as(Data, self.data) != kind) return error.ParseError;
    return @field(self.data, @tagName(kind));
}
