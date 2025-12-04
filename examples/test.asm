v_blank:
    .i8	    0x00

_start:
    add.pc	r0, ._xhwi_handler
    ctl.w	xhwi, r0
    add.pc	r0, .v_blank

_wait_for_vblank:
    ldr.u8	r1, r0
    bra.eq	rZ, r1, ._wait_for_vblank

_xhwi_handler:
    # mov     r1, 1
    # add.pc	r0, .v_blank
    # str.i8	r1, r0
    irq.ret

# _xswi_handler:
#     irq.ret
