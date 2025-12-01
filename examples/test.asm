    add.pc      r0, .hwint
    ctl.w       hwi, r0
    jmp rZ,     ._start

hwint:
    irq.ret

# r0 now holds syscall code
_swi_handler:
    irq.ret

_start:
    add.pc      r0, ._irq
    ctl.w       swi, r0
    irq.sw      0x1