// ============================================
// TrollRecorderBypass_v17.m
// Multi-layer bypass for TrollRecorder (Havoc license)
// v17: Network + Keychain + UserDefaults + CFNotification + NSURLProtocol
// ============================================

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - Compatibility Defines

#ifndef SEG_DATA
#define SEG_DATA "__DATA"
#endif
#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif
#ifndef INDIRECT_SYMBOL_LOCAL
#define INDIRECT_SYMBOL_LOCAL 0x80000000
#endif
#ifndef INDIRECT_SYMBOL_ABS
#define INDIRECT_SYMBOL_ABS 0x40000000
#endif
#ifndef REFERENCE_FLAG_UNDEFINED_NON_LAZY
#define REFERENCE_FLAG_UNDEFINED_NON_LAZY 0
#endif
#ifndef REFERENCE_FLAG_UNDEFINED_LAZY
#define REFERENCE_FLAG_UNDEFINED_LAZY 1
#endif
#ifndef REFERENCE_FLAG_DEFINED
#define REFERENCE_FLAG_DEFINED 2
#endif
#ifndef REFERENCE_FLAG_PRIVATE_DEFINED
#define REFERENCE_FLAG_PRIVATE_DEFINED 3
#endif
#ifndef REFERENCED_DYNAMICALLY
#define REFERENCED_DYNAMICALLY 0x0010
#endif
#ifndef S_LAZY_SYMBOL_POINTERS
#define S_LAZY_SYMBOL_POINTERS 0x7
#endif
#ifndef S_NON_LAZY_SYMBOL_POINTERS
#define S_NON_LAZY_SYMBOL_POINTERS 0x6
#endif
#ifndef SECTION_TYPE
#define SECTION_TYPE 0x000000ff
#endif

#define BYPASS_PAGE_SIZE 16384

#pragma mark - Fishhook (Embedded Implementation)

struct bypass_rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct bypass_rebindings_entry {
    struct bypass_rebinding *rebindings;
    size_t rebindings_nel;
    struct bypass_rebindings_entry *next;
};

static struct bypass_rebindings_entry *_rebindings_head;

static int bypass_prepend_rebindings(struct bypass_rebindings_entry **head,
                                      struct bypass_rebinding rebindings[],
                                      size_t nel) {
    struct bypass_rebindings_entry *new_entry = (struct bypass_rebindings_entry *)malloc(sizeof(struct bypass_rebindings_entry));
    if (!new_entry) return -1;
    new_entry->rebindings = rebindings;
    new_entry->rebindings_nel = nel;
    new_entry->next = *head;
    *head = new_entry;
    return 0;
}

static void bypass_perform_rebinding_with_section(
    struct bypass_rebindings_entry *rebindings,
    const struct section_64 *section,
    intptr_t slide,
    const struct nlist_64 *symtab,
    const char *strtab,
    uint32_t *indirect_symtab)
{
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
    
    for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_LOCAL || symtab_index == INDIRECT_SYMBOL_ABS) {
            continue;
        }
        
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = (char *)strtab + strtab_offset;
        
        int found_more_resolvable = 0;
        
        struct bypass_rebindings_entry *cur = rebindings;
        while (cur) {
            for (size_t j = 0; j < cur->rebindings_nel; j++) {
                if (strcmp(symbol_name, cur->rebindings[j].name) == 0) {
                    if (cur->rebindings[j].replaced != NULL &&
                        indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
                        *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
                    }
                    indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
                    goto symbol_loop;
                }
            }
            cur = cur->next;
        }
        
    symbol_loop:;
    }
}

static void bypass_rebind_symbols_for_image(
    struct bypass_rebindings_entry *rebindings,
    const struct mach_header_64 *header,
    intptr_t slide)
{
    const struct segment_command_64 *linkedit_segment = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;
    
    uintptr_t cur = (uintptr_t)(header + 1);
    const struct segment_command_64 *cur_seg;
    
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg->cmdsize) {
        cur_seg = (const struct segment_command_64 *)cur;
        if (cur_seg->cmd == LC_SEGMENT_64) {
            if (strcmp(cur_seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cur_seg;
            }
        } else if (cur_seg->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)cur_seg;
        } else if (cur_seg->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)cur_seg;
        }
    }
    
    if (!linkedit_segment || !symtab_cmd || !dysymtab_cmd) return;
    
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);
    
    cur = (uintptr_t)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg->cmdsize) {
        cur_seg = (const struct segment_command_64 *)cur;
        if (cur_seg->cmd == LC_SEGMENT_64) {
            if (strcmp(cur_seg->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg->segname, SEG_DATA_CONST) != 0) {
                continue;
            }
            const struct section_64 *sect = (const struct section_64 *)(cur + sizeof(struct segment_command_64));
            for (uint32_t j = 0; j < cur_seg->nsects; j++) {
                if ((sect[j].flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS ||
                    (sect[j].flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
                    bypass_perform_rebinding_with_section(rebindings, &sect[j], slide, symtab, strtab, indirect_symtab);
                }
            }
        }
    }
}

static void bypass_rebind_symbols_for_image_callback(const struct mach_header_64 *header, intptr_t slide) {
    bypass_rebind_symbols_for_image(_rebindings_head, header, slide);
}

static void bypass_rebind_symbols(struct bypass_rebinding rebindings[], size_t rebindings_nel) {
    int retval = bypass_prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
    if (retval < 0) return;
    
    // Process already-loaded images
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        bypass_rebind_symbols_for_image(_rebindings_head, header, slide);
    }
    
    // Register for future images
    _dyld_register_func_for_add_image((void(*)(const struct mach_header *, intptr_t))bypass_rebind_symbols_for_image_callback);
}

#pragma mark - Method Swizzling Helpers

static void bypass_swizzleInstanceMethod(Class cls, SEL orig, SEL swiz) {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, swiz);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

static void bypass_swizzleClassMethod(Class cls, SEL orig, SEL swiz) {
    bypass_swizzleInstanceMethod(object_getClass(cls), orig, swiz);
}

#pragma mark - Section 1: Fake Havoc License Data

static CFDictionaryRef bypass_createFakeLicenseDict(void) {
    const void *keys[] = {
        CFSTR("package"), CFSTR("email"), CFSTR("license"),
        CFSTR("purchase_date"), CFSTR("activated"), CFSTR("device_id"),
        CFSTR("plan"), CFSTR("order_id"), CFSTR("status"), CFSTR("expires")
    };
    const void *vals[] = {
        CFSTR("wiki.qaq.trollrecorder"),
        CFSTR("licensed@havoc.app"),
        CFSTR("00000000-0000-0000-0000-000000000000"),
        CFSTR("2024-06-01T00:00:00Z"),
        kCFBooleanTrue,
        CFSTR("BYPASS-DEVICE-ID"),
        CFSTR("pro"),
        CFSTR("BYPASS-ORDER-ID"),
        CFSTR("active"),
        CFSTR("2099-12-31T23:59:59Z")
    };
    return CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 10,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static BOOL bypass_isHavocKeychainQuery(CFDictionaryRef query) {
    if (!query) return NO;
    CFStringRef svc = CFDictionaryGetValue(query, kSecAttrService);
    CFStringRef acc = CFDictionaryGetValue(query, kSecAttrAccount);
    CFStringRef lbl = CFDictionaryGetValue(query, kSecAttrLabel);
    
    NSArray *candidates = @[
        (__bridge id)(svc ?: @""), (__bridge id)(acc ?: @""), (__bridge id)(lbl ?: @"")
    ];
    for (NSString *s in candidates) {
        NSString *lower = [s lowercaseString];
        if ([lower containsString:@"havoc"] ||
            [lower containsString:@"trollrecorder"] ||
            [lower containsString:@"troll"] ||
            [lower containsString:@"license"] ||
            [lower containsString:@"purchase"] ||
            [lower containsString:@"qaq"]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Section 2: Keychain Hooks

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);

static OSStatus fake_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (bypass_isHavocKeychainQuery(query) && result) {
        CFDictionaryRef lic = bypass_createFakeLicenseDict();
        CFDataRef data = CFPropertyListCreateData(
            kCFAllocatorDefault, lic,
            kCFPropertyListBinaryFormat_v1_0, 0, NULL);
        if (data) {
            CFTypeRef expectedClass = CFDictionaryGetValue(query, kSecReturnData);
            if (expectedClass == kCFBooleanTrue) {
                *result = data;
            } else {
                *result = lic;
                CFRelease(data);
            }
            CFRelease(lic);
            return errSecSuccess;
        }
        CFRelease(lic);
    }
    if (orig_SecItemCopyMatching) return orig_SecItemCopyMatching(query, result);
    return errSecItemNotFound;
}

static OSStatus fake_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return errSecSuccess;
}

static OSStatus fake_SecItemDelete(CFDictionaryRef query) {
    return errSecSuccess;
}

static OSStatus fake_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    return errSecSuccess;
}

#pragma mark - Section 3: NSURLProtocol for Havoc API

@interface TrollBypassURLProtocol : NSURLProtocol
@end

@implementation TrollBypassURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host.lowercaseString;
    if ([host containsString:@"havoc.app"]) return YES;
    NSString *path = request.URL.path.lowercaseString;
    if ([path containsString:@"sileo"] || [path containsString:@"license"] || [path containsString:@"verify"]) {
        return [host containsString:@"havoc"] || [host containsString:@"qaq"];
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (void)startLoading {
    NSDictionary *responseBody = @{
        @"success": @YES,
        @"status": @"active",
        @"license": @{
            @"activated": @YES,
            @"plan": @"pro",
            @"expires": @"2099-12-31T23:59:59Z"
        },
        @"purchase": @{
            @"status": @"valid",
            @"date": @"2024-06-01"
        }
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
    
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:@{
            @"Content-Type": @"application/json; charset=utf-8",
            @"Cache-Control": @"no-cache"
        }];
    
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:jsonData];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

#pragma mark - Section 4: CFNotificationCenter Block

static void (*orig_CFNotificationCenterPostNotification)(
    CFNotificationCenterRef center, CFNotificationName name,
    const void *object, CFDictionaryRef userInfo, Boolean deliverImmediately);

static void fake_CFNotificationCenterPostNotification(
    CFNotificationCenterRef center, CFNotificationName name,
    const void *object, CFDictionaryRef userInfo, Boolean deliverImmediately)
{
    if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
        NSString *n = (__bridge NSString *)name;
        NSString *lower = n.lowercaseString;
        if ([lower containsString:@"purchase"] ||
            [lower containsString:@"license"] ||
            [lower containsString:@"hint"] ||
            [n isEqualToString:@"wiki.qaq.trapp.purchase-required"] ||
            [n isEqualToString:@"wiki.qaq.trapp.hint.purchase-intro"] ||
            [n isEqualToString:@"wiki.qaq.trapp.hint.login-intro"]) {
            NSLog(@"[TRBypass] Blocked notification: %@", n);
            return;
        }
    }
    if (orig_CFNotificationCenterPostNotification) {
        orig_CFNotificationCenterPostNotification(center, name, object, userInfo, deliverImmediately);
    }
}

#pragma mark - Section 5: Protocol Classes Injection

static NSArray<Class> *(*orig_NSURLSessionConfiguration_protocolClasses)(id self, SEL _cmd);

static NSArray<Class> *fake_NSURLSessionConfiguration_protocolClasses(id self, SEL _cmd) {
    NSArray *orig = orig_NSURLSessionConfiguration_protocolClasses
        ? orig_NSURLSessionConfiguration_protocolClasses(self, _cmd) : @[];
    NSMutableArray *classes = [orig mutableCopy];
    if (![classes containsObject:[TrollBypassURLProtocol class]]) {
        [classes insertObject:[TrollBypassURLProtocol class] atIndex:0];
    }
    return classes;
}

static void bypass_injectNSURLProtocol(void) {
    Class configClass = NSClassFromString(@"NSURLSessionConfiguration");
    if (!configClass) return;
    
    SEL sel = NSSelectorFromString(@"protocolClasses");
    Method m = class_getInstanceMethod(configClass, sel);
    if (m) {
        orig_NSURLSessionConfiguration_protocolClasses = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)fake_NSURLSessionConfiguration_protocolClasses);
        NSLog(@"[TRBypass] NSURLProtocol injected into NSURLSessionConfiguration");
    }
    
    // Also register globally for NSURLConnection-based requests
    [NSURLProtocol registerClass:[TrollBypassURLProtocol class]];
}

#pragma mark - Section 6: UserDefaults Injection

static void bypass_injectUserDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    
    // ---- License status flags ----
    [ud setBool:NO forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
    [ud setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
    [ud setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
    [ud setBool:NO forKey:@"_shouldPromptLicense"];
    [ud setBool:NO forKey:@"_previousShouldPromptLicense"];
    [ud setBool:YES forKey:@"ApplicationLicenseActivated"];
    [ud setObject:@"pro" forKey:@"ApplicationLicensePlan"];
    [ud setObject:@"2099-12-31T23:59:59Z" forKey:@"ApplicationLicenseExpiry"];
    
    // ---- Pro feature flags ----
    [ud setBool:YES forKey:@"ApplicationShouldRecommendWeChatAssistant"];
    [ud setBool:YES forKey:@"ApplicationUseSmartCloudArchive"];
    [ud setBool:YES forKey:@"ApplicationUseWebDAVServer"];
    [ud setBool:YES forKey:@"ApplicationBiometricAuthentication"];
    [ud setBool:YES forKey:@"_shouldEnhanceRecording"];
    [ud setBool:YES forKey:@"_shouldRecordWithLocation"];
    [ud setBool:YES forKey:@"ApplicationTranscriptEnabled"];
    
    // ---- Suppress upgrade alerts ----
    [ud setObject:[NSDate distantFuture] forKey:@"ApplicationBlockUpgradeAlertUntil"];
    
    [ud synchronize];
    NSLog(@"[TRBypass] UserDefaults injected");
}

#pragma mark - Section 7: Fishhook Setup

static void bypass_installFishhookHooks(void) {
    struct bypass_rebinding rebindings[] = {
        {"SecItemCopyMatching", fake_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
        {"SecItemAdd",          fake_SecItemAdd,          (void **)&orig_SecItemAdd},
        {"SecItemDelete",       fake_SecItemDelete,       (void **)&orig_SecItemDelete},
        {"SecItemUpdate",       fake_SecItemUpdate,       (void **)&orig_SecItemUpdate},
        {"CFNotificationCenterPostNotification",
         fake_CFNotificationCenterPostNotification,
         (void **)&orig_CFNotificationCenterPostNotification},
    };
    bypass_rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    NSLog(@"[TRBypass] Fishhook hooks installed (5 symbols)");
}

#pragma mark - Constructor

__attribute__((constructor))
static void bypass_init(void) {
    NSLog(@"[TRBypass v17] === Initializing multi-layer bypass ===");
    
    // Layer 1: UserDefaults (earliest, before any app logic reads them)
    bypass_injectUserDefaults();
    
    // Layer 2: Fishhook for C-level functions (Keychain, CFNotificationCenter)
    bypass_installFishhookHooks();
    
    // Layer 3: NSURLProtocol for Havoc API interception
    bypass_injectNSURLProtocol();
    
    NSLog(@"[TRBypass v17] === All layers active ===");
}
