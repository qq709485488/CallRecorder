// fishhook - Facebook's library for dynamically rebinding symbols in Mach-O
// Copyright (c) 2013, Facebook, Inc. All rights reserved.
// https://github.com/facebook/fishhook

#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct rebinding_context {
    struct rebinding_context *next;
    struct rebinding *rebindings;
    size_t rebindings_nel;
    uintptr_t *sym_slide;
    const char **sym_name;
    const void **old_value;
    int applied;
};

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

int rebind_symbols_image(void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t rebindings_nel);

#ifdef __cplusplus
}
#endif

#endif
