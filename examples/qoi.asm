_buffer:
    .allocz         0x4c4b400
_data:
    .embed          "/home/silk/Documents/test.qoi"

_pointers:
    .const_i64      ._data
    .const_i64      ._buffer

_qoi_magic:
    .const_i32      0x716F6966

# integers in qoi are big-endian :(
_qoi_read_32:
    ldp.u8      r2, r3, r8 + 2!
    ldp.u8      r4, r5, r8 + 2!

    orr.i32     r1, r5, r2 lsl 24
    orr.i32     r1, r1, r3 lsl 16
    orr.i32     r1, r1, r4 lsl 8

    jmp         zr, r0         # return to link

_fail:
    jmp         zr, ._fail

_start:
# load addressess & sizes
#   r8 - data ptr
#   r9 - buffer ptr
    aui.pc      r9, ._pointers
    ldr.i64     r8, r9 + 8!
    ldr.i64     r9, r9

    # check magic
    jmp         r0, ._qoi_read_32
    aui.pc      r0,  ._qoi_magic
    ldr.u32     r0,  r0             # read magic
    bra.ne      r1,  r0, ._fail

    # read w, h
    jmp         r0, ._qoi_read_32
    mov         r10,  r1
    jmp         r0, ._qoi_read_32

#   r10 - end ptr
    mul.i64     r10, r10, r1 lsl 0x2
    add.i64     r10, r10, r9

    # skip channels, colorspace...
    add.i64     r8, r8, 0x2

#   r11 - index table ptr
#   r12 - run
#   r13 - r
#   r14 - g
#   r15 - b
#   r16 - a
    sub.i64     sp, sp, 256 # allocate index table on stack
    mov         r11, sp
    mov         r12, 0x0    # seperate for performance
    mov         r13, 0x0
    mov         r14, 0x0
    mov         r15, 0x0
    mov         r16, 0xFF

    loop:
        # decrement run if > 0
        slt.u32         r0, zr, r12
        sub.i32         r12, r12, r0
        bra.ne          zr, r0, .loop_end_no_index

        # load op from data ptr, inc by 1 after
        ldr.u8          r0, r8 + 1!

        # QOI_OP_RGB
        mov             r1, 0xfe
        bra.eq          r0, r1, .qoi_op_rgb

        # QOI_OP_RGBA
        mov             r1, 0xff
        bra.eq          r0, r1, .qoi_op_rgba

        # apply QOI_MASK2, calculate addr
        aui.pc          r1, .qoi_op_index
        and.i32         r2, r0, 0xc0
        add.i32         r1, r1, r2
        jmp             zr, r1

    # load rgb
    qoi_op_rgb:
        ldp.u8          r13, r14, r8 + 2!
        ldr.u8          r15, r8 + 1!
        mov             r16, 0xFF       # opaque
        jmp             zr, .loop_end

    # load rgba
    qoi_op_rgba:
        ldp.u8          r13, r14, r8 + 2!
        ldp.u8          r15, r16, r8 + 2!
        jmp             zr, .loop_end

    # load from index table (on stack)
    qoi_op_index:
        add.i32         r0, r11, r0 lsl 0x2 # table ptr + index * 4
        ldp.u8          r13, r14, r0 + 2!
        ldp.u8          r15, r16, r0 + 2!
        jmp             zr, .loop_end_no_index
        .allocz         0x30                # 48 padding

    # diff
    qoi_op_diff:
        mov             r2, 0x03

        # calculate r
        and.i32         r1, r2, r0 lsr 4
        sub.i32         r1, r1, 0x2
        add.i32         r13, r13, r1

        # calculate g
        and.i32         r1, r2, r0 lsr 2
        sub.i32         r1, r1, 0x2
        add.i32         r14, r14, r1

        # calculate b
        and.i32         r1, r2, r0
        sub.i32         r1, r1, 0x2
        add.i32         r15, r15, r1

        jmp             zr, .loop_end
        .allocz         0x14            # 20 padding

    qoi_op_luma:
        and.i32         r0, r0, 0x3f
        sub.i32         r0, r0, 0x20
        add.i32         r14, r14, r0    # g += vg

        # in next calculations we use only vg - 8
        sub.i32         r0, r0, 0x8

        # load "b2"
        ldr.u8          r1, r8 + 1!
        lsr.u32         r2, r1, 0x4

        # calc both right away
        and.i32         r1, r1, 0x0f
        add.i32         r1, r1, r0
        add.i32         r2, r2, r0

        add.i32         r15, r15, r1
        add.i32         r13, r13, r2

        jmp             zr, .loop_end
        .allocz         0x10            # 16 padding

    qoi_op_run:
        and.i32         r12, r0, 0x3f
        jmp             zr, .loop_end_no_index
        .allocz         0x38            # 56 padding

    loop_end:
        # calculate hash
        mul.i32         r0, r13, 0x3    # C.rgba.r*3
        mul.i32         r1, r14, 0x5
        add.i32         r0, r0, r1      # C.rgba.r*3 + C.rgba.g*5
        mul.i32         r1, r15, 0x7
        add.i32         r0, r0, r1      # C.rgba.r*3 + C.rgba.g*5 + C.rgba.b*7
        mul.i32         r1, r16, 0xb
        add.i32         r0, r0, r1      # C.rgba.r*3 + C.rgba.g*5 + C.rgba.b*7 + C.rgba.a*11
        and.i32         r0, r0, 0x3f    # & (64 - 1)

        # store in index table
        add.i64         r0, r11, r0 lsl 0x2 #  (4 * hash_index) + ptr
        stp.i8          r13, r14, r0 + 2!
        stp.i8          r15, r16, r0 + 2!

loop_end_no_index:
        stp.i8          r13, r14, r9 + 2!
        stp.i8          r15, r16, r9 + 2!
        bra.ltu         r9, r10, .loop

        add.i64         sp, sp, 256

stall:
        jmp zr,         .pussy  # stall
