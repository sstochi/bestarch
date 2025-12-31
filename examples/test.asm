data:
    .embed      "/home/silk/Pictures/pussy.qoi"
buffer:
    .allocz     0x4c4b400

qoi_data:
    .i64    .data
    .i64    50338461
qoi_buffer:
    .i64    .buffer
    .i64    0x4c4b400

qoi_magic:
    .i32    0x716F6966

_qoi_read_32:
# prepare mask & load u32
    ldr.u32     r0, r8 + 4!         # load + post inc (wb)
    mov         r1, 0xFF lsl 24     # 0xFF000000
    mov         r2, 0x0

    and.i64     r3, r0, r1          # 0xFF000000
    lsr.u64     r3, r3, 24
    or.i64      r2, r2, r3
    
    and.i64     r3, r0, r1 lsr 8    # 0x00FF0000
    lsr.u64     r3, r3, 8
    or.i64      r2, r2, r3

    and.i64     r3, r0, r1 lsr 16   # 0x0000FF00
    lsl.i64     r3, r3, 8
    or.i64      r2, r2, r3

    and.i64     r3, r0, r1 lsr 24   # 0x000000FF
    lsl.i64     r3, r3, 24
    or.i64      r3, r2, r3

    jmp         zr, r4         # return to link

_fail:
    jmp         zr, ._fail

_start:
# load addressess & sizes
#   r8 - data ptr
#   r9 - data size
    aui.pc      r9, .qoi_data
    ldr.i64     r8, r9      # ldr/str auto-inc with offt
    ldr.i64     r9, r9 + 8

#   r10 - buffer ptr
#   r11 - buffer size
    aui.pc      r11, .qoi_buffer
    ldr.i64     r10, r11
    ldr.i64     r11, r11 + 8

# check magic
    jmp         r4, ._qoi_read_32
    aui.pc      r0,  .qoi_magic
    ldr.u32     r0,  r0             # read magic
    bra.ne      r3,  r0, ._fail

# read width height
#   r12 - width
#   r13 - height
    jmp         r4, ._qoi_read_32
    mov         r12,  r3
    jmp         r4, ._qoi_read_32
    mov         r13,  r3
    add.i64     r8, r8, 0x1 # skip channels


