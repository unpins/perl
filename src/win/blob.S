/* Embed the VFS blob as a rodata symbol. On x86_64 mingw, C identifiers carry
 * no leading underscore, so the asm labels match `extern ... incblob_start[]`
 * in vfs.c directly. PE has no GNU-stack note concept (ELF-only), so the
 * stub is just the incbin between two global labels. */
    .section .rodata
    .global incblob_start
    .global incblob_end
incblob_start:
    .incbin "blob.bin"
incblob_end:
