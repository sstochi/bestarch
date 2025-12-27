v_blank:
    .i8	    0x00
    .i64    0x696969
    .i64    0x323232
    .i64    0x161616
    .i64    0x080808
    .zalloc  48

_start:
    aui.pc	    r0, ._xhwi_handler
    ctl.w	    xhwi, r0

_loop:
    aui.pc	    r0, .v_blank
_wait_for_vblank:
    ldr.u8	    r1, r0
    bra.eq	    rz, r1, ._wait_for_vblank # .v_blank != 0 to continue
    str.i8      rz, r0

    jmp         ._loop

_xhwi_handler:
    aui.pc	    r0, .v_blank
    mov         r1, 1
    str.i8	    r1, r0

    irq.ret
