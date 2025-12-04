pub const Reg = enum(u5) {
    r0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,
    r16,
    r17,
    r18,
    r19,
    r20,
    r21,
    r22,
    r23,
    r24,
    r25,
    r26,
    r27,
    r28,
    r29,
    r30,
    rZ,
};

pub const CtlReg = enum(u3) {
    xctl,
    xhwi, // hw interrupt
    xtmi, // sw interrupt
    xswi, // timer interrupt
};

pub const Group = enum(u4) {
    move,
    process,
    memory,
    branch,
    jump_rel,
    jump_reg,
    addpc,
    ctl,
    irq,
    stack,
};

pub const ProcessCode = enum(u4) {
    @"and",
    @"or",
    xor,

    lsl,
    lsr,
    asr,

    add,
    sub,
    mul,
    divu,
    divs,
    modu,
    mods,
    _,
};

pub const MemorySize1 = enum(u1) {
    m32,
    m64,
};

pub const MemorySize2 = enum(u2) {
    m8,
    m16,
    m32,
    m64,
};

pub const ShiftType = enum(u1) {
    lsl,
    lsr,
};

pub const CmpFlags = packed struct(u3) {
    compare: bool,
    flip: bool,
    signed: bool,
};

pub const CtlMode = enum(u2) {
    write,
    read,
    set,
    unset,
};

pub const MoveMode = enum(u2) {
    imm,
    imm_shift,
    reg,
    cvt,
};

pub const InstMoveImm = packed struct(u32) {
    group: Group = .move,

    mode: MoveMode = .imm,

    dst: Reg,
    imm: i21,
};

pub const InstMoveImmShift = packed struct(u32) {
    group: Group = .move,

    mode: MoveMode = .imm_shift,

    dst: Reg,
    value: i15,
    left_amount: u6,
};

pub const InstMoveReg = packed struct(u32) {
    group: Group = .move,

    mode: MoveMode = .reg,

    dst: Reg,
    value: Reg,
    left_amount: u6,
    signed: bool,
    right_amount: u6,
    reserved: u3 = 0,
};

const MoveCvtCode = enum(u5) {
    fcvt_u32_f32,
    fcvt_s32_f32,
    fcvt_u64_f32,
    fcvt_s64_f32,
    fcvt_u32_f64,
    fcvt_s32_f64,
    fcvt_u64_f64,
    fcvt_s64_f64,
    fcvt_f32_u32,
    fcvt_f32_s32,
    fcvt_f32_u64,
    fcvt_f32_s64,
    fcvt_f64_u32,
    fcvt_f64_s32,
    fcvt_f64_u64,
    fcvt_f64_s64,
    fmov_f32_f64,
    fmov_f64_f32,
};

pub const InstMoveCvt = packed struct(u32) {
    group: Group = .move,

    mode: MoveMode = .cvt,

    dst: Reg,
    code: MoveCvtCode,
    src: Reg,
    reserved: u11 = 0,
};

pub const InstMove = packed struct(u32) {
    group: Group = .move,

    mode: MoveMode,

    dst: Reg,
    reserved: u21,
};

pub const InstAddPC = packed struct(u32) {
    group: Group = .addpc,
    dst: Reg,
    offset: i23,
};

pub const ProcessMode = enum(u1) { imm, reg };

pub const InstProcessImm = packed struct(u32) {
    group: Group = .process,
    code: ProcessCode,
    size: MemorySize1,

    dst: Reg,
    lhs: Reg,
    rhs_mode: ProcessMode = .imm,
    imm: i12,
};

pub const InstProcessReg = packed struct(u32) {
    group: Group = .process,
    code: ProcessCode,
    size: MemorySize1,

    dst: Reg,
    lhs: Reg,
    rhs_mode: ProcessMode = .reg,
    value: Reg,
    shift: ShiftType,
    amount: u6,
};

pub const InstProcess = packed struct(u32) {
    group: Group = .process,
    code: ProcessCode,
    size: MemorySize1,

    dst: Reg,
    lhs: Reg,
    rhs_mode: ProcessMode,
    reserved: u12,
};

pub const InstMemory = packed struct(u32) {
    group: Group = .memory,
    mode: MemorySize2,
    signed: bool,
    store: bool,

    value: Reg,
    base: Reg,
    offset: i14,
};

pub const InstBranch = packed struct(u32) {
    group: Group = .branch,
    lhs: Reg,
    rhs: Reg,
    flags: CmpFlags,
    offset: i15,
};

pub const InstJumpRel = packed struct(u32) {
    group: Group = .jump_rel,
    link: Reg,
    offset: i23,
};

pub const InstJumpReg = packed struct(u32) {
    group: Group = .jump_reg,
    link: Reg,
    base: Reg,
    offset: i18,
};

pub const InstCtl = packed struct(u32) {
    group: Group = .ctl,
    mode: CtlMode,
    target: CtlReg,
    reg: Reg,
    reserved: u18 = 0,
};

const IrqMode = enum(u1) { swi, ret };

pub const InstIrq = packed struct(u32) {
    group: Group = .irq,
    mode: IrqMode,
    code: u27 = 0,
};

pub const InstStack = packed struct(u32) {
    group: Group = .stack,
    size: MemorySize1,
    push: bool,
    bitmask: u26,
};

pub const UnknownInst = packed struct(u32) {
    group: Group,
    reserved: u28,
};

pub const Inst = packed union {
    unknown: UnknownInst,
    move: InstMove,
    move_imm: InstMoveImm,
    move_imm_shift: InstMoveImmShift,
    move_reg: InstMoveReg,
    move_cvt: InstMoveCvt,
    process: InstProcess,
    process_imm: InstProcessImm,
    process_reg: InstProcessReg,
    addpc: InstAddPC,
    memory: InstMemory,
    branch: InstBranch,
    jump_rel: InstJumpRel,
    jump_reg: InstJumpReg,
    ctl: InstCtl,
    irq: InstIrq,
    stack: InstStack,
};
