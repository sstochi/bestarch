.i64            .loop

_start:
    mov         r0, 0x69
    jmp         rZ, .loop

loop:
    sub.i64     r0, r0, 1
    b.ne        rZ, r0, .loop