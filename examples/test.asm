_irq_handler:
    irq.ret

_start:
    mov	    r0, 0
    add.pc	r0, ._irq_handler
    ctl.w	xhwi