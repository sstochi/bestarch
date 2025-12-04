_start:
    mov	    r0, 0
    add.pc	r0, ._irq_handler
    ctl.w	xhwi, r0

_wait:
    nop
    jmp	rZ, ._wait

_irq_handler:
    mov	r0, 1
    str.i8	r0, rZ + 0x128
    irq.ret