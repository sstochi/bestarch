pub const Register = enum(u5) {
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

pub const CtlRegister = enum(u3) {
    control,
    hwi, // hw interrupt
    tmi, // sw interrupt
    swi, // timer interrupt
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

pub const ProcessMode1 = enum(u1) {
    m32,
    m64,
};

pub const ProcessMode2 = enum(u2) {
    m8,
    m16,
    m32,
    m64,
};

pub const ShiftType = enum(u1) {
    lsl,
    lsr,
};

pub const CompareFlags = packed struct(u3) {
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

pub const Instruction = packed union {
    pub const Move = packed struct(u32) {
        group: Group = .move,

        mode: enum(u2) {
            imm,
            imm_shift,
            reg,
            cvt,
        },

        dst: Register,
        src: packed union {
            imm: i21,

            imm_shift: packed struct(u21) {
                value: i15,
                left_amount: u6,
            },

            reg: packed struct(u21) {
                value: Register,
                left_amount: u6,
                signed: bool,
                right_amount: u6,
                reserved: u3 = 0,
            },

            cvt: packed struct(u21) {
                code: enum(u5) {
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
                },
                src: Register,
                reserved: u11 = 0,
            },
        },
    };

    pub const AddPC = packed struct(u32) {
        group: Group = .addpc,
        dst: Register,
        offset: i23,
    };

    pub const Process = packed struct(u32) {
        group: Group = .process,
        code: ProcessCode,
        mode: ProcessMode1,

        dst: Register,
        lhs: Register,
        rhs_mode: enum(u1) { imm, reg },
        rhs: packed union {
            imm: i12,

            reg: packed struct(u12) {
                value: Register,
                shift: ShiftType,
                amount: u6,
            },
        },
    };

    pub const Memory = packed struct(u32) {
        group: Group = .memory,
        mode: ProcessMode2,
        signed: bool,
        store: bool,

        value: Register,
        base: Register,
        offset: i14,
    };

    pub const Branch = packed struct(u32) {
        group: Group = .branch,
        lhs: Register,
        rhs: Register,
        flags: CompareFlags,
        offset: i15,
    };

    pub const JumpRel = packed struct(u32) {
        group: Group = .jump_rel,
        link: Register,
        offset: i23,
    };

    pub const JumpReg = packed struct(u32) {
        group: Group = .jump_reg,
        link: Register,
        base: Register,
        offset: i18,
    };

    pub const Ctl = packed struct(u32) {
        group: Group = .ctl,
        mode: CtlMode,
        target: CtlRegister,
        reg: Register,
        reserved: u18 = 0,
    };

    pub const Irq = packed struct(u32) {
        group: Group = .irq,
        mode: enum(u1) { swi, ret },

        value: packed union {
            code: u27,
            ret: packed struct(u27) { reserved: u27 = 0 },
        },
    };

    group: packed struct(u32) { group: Group, reserved: u28 },
    move: Move,
    process: Process,
    addpc: AddPC,
    memory: Memory,
    branch: Branch,
    jump_rel: JumpRel,
    jump_reg: JumpReg,
    ctl: Ctl,
    irq: Irq,
};
