// fishhook - Facebook's library for dynamically rebinding symbols in Mach-O
// Copyright (c) 2013, Facebook, Inc. All rights reserved.
// https://github.com/facebook/fishhook

#include "fishhook.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST  "__DATA_CONST"
#endif

struct rebinding_context *_rebindings_head;

static int prepend_rebindings(struct rebinding_context **head,
                              struct rebinding rebindings[],
                              size_t nel) {
    struct rebinding_context *ctx = (struct rebinding_context *)malloc(sizeof(struct rebinding_context));
    if (!ctx) return -1;
    ctx->rebindings = (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
    if (!ctx->rebindings) {
        free(ctx);
        return -1;
    }
    memcpy(ctx->rebindings, rebindings, sizeof(struct rebinding) * nel);
    ctx->rebindings_nel = nel;
    ctx->sym_slide = (uintptr_t *)malloc(sizeof(uintptr_t) * nel);
    ctx->sym_name = (const char **)malloc(sizeof(const char *) * nel);
    ctx->old_value = (const void **)malloc(sizeof(const void *) * nel);
    if (!ctx->sym_slide || !ctx->sym_name || !ctx->old_value) {
        free(ctx->rebindings);
        free(ctx->sym_slide);
        free(ctx->sym_name);
        free(ctx->old_value);
        free(ctx);
        return -1;
    }
    ctx->applied = 0;
    ctx->next = *head;
    *head = ctx;
    return 0;
}

static int get_protection(void *addr) {
    vm_size_t vmsize = 0;
    mach_port_t task = mach_task_self();
    vm_region_basic_info_data_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT;
    memory_object_name_t object;
    
    kern_return_t kr = vm_region_64(task, (vm_address_t *)&addr,
                                     &vmsize, VM_REGION_BASIC_INFO,
                                     (vm_region_info_t)&info,
                                     &info_count, &object);
    if (kr != KERN_SUCCESS) return PROT_READ | PROT_WRITE;
    return info.protection;
}

static void perform_rebinding_with_section(struct rebinding_context *ctx,
                                           const struct section_64 *section,
                                           intptr_t slide) {
    if (!section || section->size == 0) return;

    const uint8_t *data = (const uint8_t *)(slide + section->offset);
    const uintptr_t *indirect_symtab = (const uintptr_t *)(slide + section->reserved1);

    for (size_t i = 0; i < ctx->rebindings_nel; i++) {
        ctx->sym_slide[i] = 0;
        ctx->sym_name[i] = NULL;
        ctx->old_value[i] = NULL;
    }

    int symtab_cmd_found = 0;
    uintptr_t symtab = 0, strtab = 0;
    const struct mach_header_64 *header = (const struct mach_header_64 *)(slide);
    const struct load_command *cmd = (const struct load_command *)(header + 1);
    
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB) {
            const struct symtab_command *symtab_cmd = (const struct symtab_command *)cmd;
            symtab = slide + symtab_cmd->symoff;
            strtab = slide + symtab_cmd->stroff;
            symtab_cmd_found = 1;
            break;
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }

    for (size_t i = 0; i < (section->size / sizeof(uintptr_t)); i++) {
        if (data[i * sizeof(uintptr_t)] == 0) continue;
        
        uint32_t symtab_index = (uint32_t)indirect_symtab[i];
        if (symtab_index == INDIRECT_SYMBOL_LOCAL || symtab_index == INDIRECT_SYMBOL_ABS) continue;
        
        const struct nlist_64 *sym = &((const struct nlist_64 *)symtab)[symtab_index];
        const char *sym_name = sym->n_un.n_strx ? (const char *)(strtab + sym->n_un.n_strx) : NULL;
        if (!sym_name) continue;

        for (size_t j = 0; j < ctx->rebindings_nel; j++) {
            if (ctx->sym_slide[j] != 0) continue;
            if (strcmp(sym_name, ctx->rebindings[j].name) == 0) {
                ctx->sym_slide[j] = (uintptr_t)((uintptr_t *)data + i);
                ctx->sym_name[j] = sym_name;
                ctx->old_value[j] = *(const void **)((uintptr_t *)data + i);
            }
        }
    }

    for (size_t j = 0; j < ctx->rebindings_nel; j++) {
        if (ctx->sym_slide[j] == 0) continue;
        
        void **slot = (void **)ctx->sym_slide[j];
        int prot = get_protection(slot);
        
        if (prot & PROT_WRITE) {
            *slot = ctx->rebindings[j].replacement;
        } else {
            vm_size_t page_size = getpagesize();
            void *page_start = (void *)((uintptr_t)slot & ~(page_size - 1));
            kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page_start,
                                          page_size, FALSE,
                                          PROT_READ | PROT_WRITE | PROT_EXEC);
            if (kr == KERN_SUCCESS) {
                *slot = ctx->rebindings[j].replacement;
                vm_protect(mach_task_self(), (vm_address_t)page_start,
                          page_size, FALSE, prot);
            }
        }
    }
}

static int rebind_symbols_for_image(struct rebinding_context *ctx,
                                    const struct mach_header_64 *header,
                                    intptr_t slide) {
    const struct segment_command_64 *linkedit = NULL;
    struct section_64 lazy_symbol, non_lazy_symbol;
    memset(&lazy_symbol, 0, sizeof(lazy_symbol));
    memset(&non_lazy_symbol, 0, sizeof(non_lazy_symbol));

    const struct load_command *cmd = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit = seg;
            }
            if (strcmp(seg->segname, SEG_DATA) == 0 ||
                strcmp(seg->segname, SEG_DATA_CONST) == 0) {
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sect[j].sectname, "__la_symbol_ptr") == 0) {
                        lazy_symbol = sect[j];
                    }
                    if (strcmp(sect[j].sectname, "__nl_symbol_ptr") == 0) {
                        non_lazy_symbol = sect[j];
                    }
                }
            }
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }

    if (!linkedit) return -1;

    uintptr_t linkedit_base = slide + linkedit->vmaddr - linkedit->fileoff;
    
    if (lazy_symbol.size > 0) {
        struct section_64 sect = lazy_symbol;
        sect.reserved1 += (uint32_t)(linkedit_base - slide);
        perform_rebinding_with_section(ctx, &sect, slide);
    }
    if (non_lazy_symbol.size > 0) {
        struct section_64 sect = non_lazy_symbol;
        sect.reserved1 += (uint32_t)(linkedit_base - slide);
        perform_rebinding_with_section(ctx, &sect, slide);
    }
    return 0;
}

int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel) {
    struct rebinding_context *ctx;
    int ret = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
    if (ret < 0) return ret;
    ctx = _rebindings_head;
    ret = rebind_symbols_for_image(ctx, (const struct mach_header_64 *)header, slide);
    if (ret == 0) ctx->applied = 1;
    return ret;
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
    int ret = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
    if (ret < 0) return ret;
    
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        ret = rebind_symbols_for_image(_rebindings_head,
                                       (const struct mach_header_64 *)_dyld_get_image_header(i),
                                       _dyld_get_image_vmaddr_slide(i));
    }
    _rebindings_head->applied = 1;
    return ret;
}
