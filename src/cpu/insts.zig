const isa = @import("isa.zig");
const Instruction = isa.Instruction;
const ProcessCode = isa.ProcessCode;
const ProcessMode1 = isa.ProcessMode1;
const ProcessMode2 = isa.ProcessMode2;
const CompareFlags = isa.CompareFlags;
const Register = isa.Register;

fn Inst(comptime layout: type, comptime base: anytype) void {
    _ = layout;
    // _ = base;
    @compileLog(base);
}

const instructions = struct {
    pub const @"and.i64" = Inst(
        struct {
            dst_reg: Register,
            lhs_reg: Register,
            imm12: i12,
        },
        .{ .process = .{
            .dst = "dst_reg",
            .lhs = "lhs_reg",
            .code = .add,
            .mode = .m64,
            .rhs_mode = .imm,
            .rhs = .{ .imm = "imm12" },
        } },
    );
    // "group.src.cvt.src"
};
