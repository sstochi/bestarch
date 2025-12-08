v_blank:
    .i8	    0x00
    .i64    0x696969
    .i64    0x323232
    .i64    0x161616
    .i64    0x080808
    .alloc  48

_start:
    # ldp.i64     r1, r2, r4 < -16
    # ldp.i64     r1, r2, r4 < -16

    aui.pc	    r0, ._xhwi_handler
    ctl.w	    xhwi, r0
    aui.pc	    r0, ._xswi_handler
    ctl.w	    xswi, r0

_loop:
    # game logic here

_wait_for_vblank:
    aui.pc	    r0, .v_blank
    ldr.u8	    r1, r0
    bra.eq	    rZ, r1, ._wait_for_vblank

    jmp         rZ, ._loop

_xhwi_handler:
    mov         r1, 1
    aui.pc	    r0, .v_blank
    str.i8	    r1, r0
    irq.ret

_xswi_handler:
    irq.ret
