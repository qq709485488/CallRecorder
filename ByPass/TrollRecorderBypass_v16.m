// TrollRecorderBypass_v16.m
// Fishhook-based bypass for TrollRecorder (TrollStore, non-jailbreak)
//
// Strategy:
//   Layer 1: NSUserDefaults pre-population (carry-over from v15)
//   Layer 2: CFNotificationCenter purchase notification interception (carry-over)
//   Layer 3: SecItemCopyMatching/Add/Delete fishhook → Keychain license spoofing
//   Layer 4: NSURLSession swizzle → Havoc API response faking (fallback)
//   Layer 5: objc_getClassList swizzle → verification method replacement (carry-over, best-effort)

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <mach-o/nlist.h>
#import <sys/mman.h>
#import <string.h>
#import <stdlib.h>

// ============================================================================
#pragma mark - Embedded Fishhook (adapted for iOS arm64, with mprotect fallback)
// ============================================================================

struct _rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct _rebindings_entry {
    struct _rebinding *rebindings;
    size_t rebindings_nel;
    struct _rebindings_entry *next;
};

static struct _rebindings_entry *_rebindings_head = NULL;

static int _prepend_rebindings(struct _rebindings_entry **head,
                                struct _rebinding rebindings[],
                                size_t nel) {
    struct _rebindings_entry *entry = malloc(sizeof(struct _rebindings_entry));
    if (!entry) return -1;
    entry->rebindings = malloc(nel * sizeof(struct _rebinding));
    if (!entry->rebindings) { free(entry); return -1; }
    memcpy(entry->rebindings, rebindings, nel * sizeof(struct _rebinding));
    entry->rebindings_nel = nel;
    entry->next = *head;
    *head = entry;
    return 0;
}

static void _perform_rebinding_with_section(struct _rebindings_entry *entry,
                                             intptr_t slide,
                                             struct mach_header_64 *header,
                                             intptr_t symtab_cmd, intptr_t dysymtab_cmd,
                                             const struct section_64 *section) {
    if (!section || section->size == 0) return;

    uint32_t *indirect_symtab = (uint32_t *)((intptr_t)header + section->reserved1);
    void **indirect_symbol_bindings = (void **)((intptr_t)header + section->addr - slide);

    struct nlist_64 *symtab = NULL;
    uint32_t nsyms = 0;
    const char *strtab = NULL;

    struct symtab_command *sym = (struct symtab_command *)((intptr_t)header + symtab_cmd);
    if (sym->nsyms > 0) {
        symtab = (struct nlist_64 *)((intptr_t)header + sym->symoff - slide);
        nsyms = sym->nsyms;
        strtab = (const char *)((intptr_t)header + sym->stroff - slide);
    }

    for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symtab[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL)
            continue;
        if (symtab_index >= nsyms) continue;

        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        const char *symbol_name = strtab + strtab_offset;

        for (size_t j = 0; j < entry->rebindings_nel; j++) {
            if (strcmp(symbol_name, entry->rebindings[j].name) == 0) {
                if (entry->rebindings[j].replaced) {
                    *(entry->rebindings[j].replaced) = indirect_symbol_bindings[i];
                }
                indirect_symbol_bindings[i] = entry->rebindings[j].replacement;
                break;
            }
        }
    }
}

// Check if section is in a const segment, try mprotect if needed
static int _ensure_writable(void *addr, size_t len) {
    // Round down to page boundary
    uintptr_t page = (uintptr_t)addr & ~(PAGE_SIZE - 1);
    size_t page_len = ((uintptr_t)addr + len - page + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    return mprotect((void *)page, page_len, PROT_READ | PROT_WRITE);
}

static void _perform_rebindings_with_header(struct _rebindings_entry *entry,
                                             struct mach_header_64 *header,
                                             intptr_t slide) {
    intptr_t symtab_cmd = 0, dysymtab_cmd = 0;
    const struct section_64 *la_section = NULL;
    const struct section_64 *nl_section = NULL;

    struct load_command *cmd = (struct load_command *)((intptr_t)header + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (intptr_t)cmd;
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (intptr_t)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__DATA") == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0) {
                struct section_64 *sect = (struct section_64 *)((intptr_t)seg + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sect[j].sectname, SECT_LA_SYMBOL_PTR) == 0) {
                        la_section = &sect[j];
                    } else if (strcmp(sect[j].sectname, SECT_NL_SYMBOL_PTR) == 0) {
                        nl_section = &sect[j];
                    }
                }
            }
        }
        cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize);
    }

    if (!symtab_cmd || !dysymtab_cmd) return;

    // Try to make __DATA_CONST writable if needed
    void *la_addr = NULL;
    size_t la_size = 0;
    if (la_section && la_section->size > 0) {
        la_addr = (void *)((intptr_t)header + la_section->addr - slide);
        la_size = la_section->size;
    }
    void *nl_addr = NULL;
    size_t nl_size = 0;
    if (nl_section && nl_section->size > 0) {
        nl_addr = (void *)((intptr_t)header + nl_section->addr - slide);
        nl_size = nl_section->size;
    }

    // Check if sections are in DATA_CONST (they won't be writable by default)
    int need_restore_la = 0, need_restore_nl = 0;
    if (la_addr && _ensure_writable(la_addr, la_size) == 0) {
        need_restore_la = 1;
    }
    if (nl_addr && nl_addr != la_addr && _ensure_writable(nl_addr, nl_size) == 0) {
        need_restore_nl = 1;
    }

    _perform_rebinding_with_section(entry, slide, header, symtab_cmd, dysymtab_cmd, la_section);
    _perform_rebinding_with_section(entry, slide, header, symtab_cmd, dysymtab_cmd, nl_section);

    // Restore original protection if we changed it
    if (need_restore_la) {
        mprotect((void *)((uintptr_t)la_addr & ~(PAGE_SIZE - 1)),
                 la_size + ((uintptr_t)la_addr & (PAGE_SIZE - 1)),
                 PROT_READ);
    }
    if (need_restore_nl) {
        mprotect((void *)((uintptr_t)nl_addr & ~(PAGE_SIZE - 1)),
                 nl_size + ((uintptr_t)nl_addr & (PAGE_SIZE - 1)),
                 PROT_READ);
    }
}

static void _rebind_symbols_for_image(const struct mach_header *mh, intptr_t slide) {
    struct mach_header_64 *header = (struct mach_header_64 *)mh;
    if (header->magic != MH_MAGIC_64) return;

    struct _rebindings_entry *cur = _rebindings_head;
    while (cur) {
        _perform_rebindings_with_header(cur, header, slide);
        cur = cur->next;
    }
}

static void _rebind_symbols(struct _rebinding rebindings[], size_t rebindings_nel) {
    int ret = _prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
    if (ret < 0) {
        NSLog(@"[TRBypass v16] fishhook: failed to prepend rebindings");
        return;
    }
    // Apply to already loaded images
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        _rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
    // Future images will be handled by dyld callback
}

static void _rebind_symbols_image(void *header, intptr_t slide,
                                   struct _rebinding rebindings[], size_t rebindings_nel) {
    struct _rebindings_entry *entry = malloc(sizeof(struct _rebindings_entry));
    if (!entry) return;
    entry->rebindings = malloc(rebindings_nel * sizeof(struct _rebinding));
    if (!entry->rebindings) { free(entry); return; }
    memcpy(entry->rebindings, rebindings, rebindings_nel * sizeof(struct _rebinding));
    entry->rebindings_nel = rebindings_nel;
    entry->next = NULL;
    _perform_rebindings_with_header(entry, (struct mach_header_64 *)header, slide);
    free(entry->rebindings);
    free(entry);
}

// ============================================================================
#pragma mark - Original Function Pointers (SecItem family)
// ============================================================================

static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = NULL;
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = NULL;
static OSStatus (*original_SecItemDelete)(CFDictionaryRef query) = NULL;

// ============================================================================
#pragma mark - Havoc Keychain License Data
// ============================================================================

// Keychain access group for TrollStore apps is typically unset or the app's team ID.
// Havoc uses bundle-id based service names.

// Possible Havoc/TrollRecorder service names to match:
static CFStringRef _havocServiceNames[] = {
    NULL, // will be set to bundle ID at runtime
};
static const size_t _havocServiceCount = sizeof(_havocServiceNames) / sizeof(_havocServiceNames[0]);

// Fake Havoc license plist data (binary plist containing license info)
// This is a minimal plist that Havoc might use. The exact format is reverse-engineered.
static NSData *_createFakeLicensePlist(void) {
    // Havoc typically stores a JSON or plist with:
    // - license_key
    // - device_id (or udid)
    // - activation_date
    // - expiry (far future)
    // - signature (SHA256 or RSA)

    NSDictionary *license = @{
        @"license_key": @"TRBYASS-V16-0000-0000-0000-000000000000",
        @"device_id": @"00000000-0000-0000-0000-000000000000",
        @"email": @"bypass@v16.local",
        @"activation_date": @"2025-01-01T00:00:00Z",
        @"expiry_date": @"2099-12-31T23:59:59Z",
        @"purchase_date": @"2025-01-01T00:00:00Z",
        @"tier": @"pro",
        @"features": @[@"auto_record", @"biometric_lock", @"advanced_metadata", @"post_processing"],
        @"max_devices": @99,
        @"signature": @"BYPASS_V16_FAKE_SIGNATURE_PLACEHOLDER"
    };

    NSError *error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:license
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0
                                                                     error:&error];
    if (error) {
        NSLog(@"[TRBypass v16] Failed to serialize license plist: %@", error);
        // Fallback: JSON
        return [NSJSONSerialization dataWithJSONObject:license options:0 error:nil];
    }
    return plistData;
}

static CFDataRef _getFakeLicenseData(void) {
    static CFDataRef cached = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSData *data = _createFakeLicensePlist();
        cached = CFBridgingRetain(data);
    });
    return cached;
}

// Check if a Keychain query targets Havoc/TrollRecorder license data
static BOOL _isHavocLicenseQuery(CFDictionaryRef query) {
    if (!query) return NO;
    CFTypeRef classVal = CFDictionaryGetValue(query, kSecClass);
    if (!classVal) return NO;
    if (!CFEqual(classVal, kSecClassGenericPassword)) return NO;

    // Check kSecAttrService - match known patterns
    CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
    if (service && CFGetTypeID(service) == CFStringGetTypeID()) {
        CFStringRef svc = (CFStringRef)service;
        CFStringRef lowered = (__bridge CFStringRef)[(__bridge NSString *)svc lowercaseString];

        // Match patterns: bundle ID, "havoc", "trollrecorder", "recorder"
        if (CFStringFind(lowered, CFSTR("havoc"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("trollrecorder"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("recorder"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("82flex"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("callrecorder"), 0).location != kCFNotFound) return YES;
    }

    // Check kSecAttrAccount - license-related accounts
    CFTypeRef account = CFDictionaryGetValue(query, kSecAttrAccount);
    if (account && CFGetTypeID(account) == CFStringGetTypeID()) {
        CFStringRef acc = (CFStringRef)account;
        CFStringRef lowered = (__bridge CFStringRef)[(__bridge NSString *)acc lowercaseString];
        if (CFStringFind(lowered, CFSTR("license"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("havoc"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("activation"), 0).location != kCFNotFound) return YES;
    }

    // Check kSecAttrGeneric label
    CFTypeRef label = CFDictionaryGetValue(query, kSecAttrGeneric);
    if (label && CFGetTypeID(label) == CFStringGetTypeID()) {
        CFStringRef lbl = (CFStringRef)label;
        CFStringRef lowered = (__bridge CFStringRef)[(__bridge NSString *)lbl lowercaseString];
        if (CFStringFind(lowered, CFSTR("havoc"), 0).location != kCFNotFound) return YES;
        if (CFStringFind(lowered, CFSTR("trollrecorder"), 0).location != kCFNotFound) return YES;
    }

    return NO;
}

// ============================================================================
#pragma mark - Hooked SecItem Functions
// ============================================================================

static OSStatus _hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    // First try the original function
    OSStatus status = original_SecItemCopyMatching(query, result);

    // If found normally, return as-is
    if (status == errSecSuccess) {
        return status;
    }

    // If not found, check if this is a Havoc license query
    if (_isHavocLicenseQuery(query)) {
        NSLog(@"[TRBypass v16] SecItemCopyMatching: Havoc license query detected, returning fake data (original status: %d)", (int)status);

        // Build a fake Keychain result dictionary
        CFMutableDictionaryRef fakeItem = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);

        // Copy query attributes to result
        CFTypeRef cls = CFDictionaryGetValue(query, kSecClass);
        if (cls) CFDictionarySetValue(fakeItem, kSecClass, cls);
        CFTypeRef svc = CFDictionaryGetValue(query, kSecAttrService);
        if (svc) CFDictionarySetValue(fakeItem, kSecAttrService, svc);
        CFTypeRef acc = CFDictionaryGetValue(query, kSecAttrAccount);
        if (acc) CFDictionarySetValue(fakeItem, kSecAttrAccount, acc);

        // Inject fake license data
        CFDataRef fakeData = _getFakeLicenseData();
        CFDictionarySetValue(fakeItem, kSecValueData, fakeData);

        // Set creation/modification dates
        CFDateRef now = CFDateCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent());
        CFDictionarySetValue(fakeItem, kSecAttrCreationDate, now);
        CFDictionarySetValue(fakeItem, kSecAttrModificationDate, now);
        CFRelease(now);

        if (result) {
            *result = fakeItem;
        } else {
            CFRelease(fakeItem);
        }

        return errSecSuccess;
    }

    return status;
}

static OSStatus _hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (_isHavocLicenseQuery(attributes)) {
        NSLog(@"[TRBypass v16] SecItemAdd: Havoc license add intercepted, faking success");
        return errSecSuccess;
    }
    return original_SecItemAdd(attributes, result);
}

static OSStatus _hooked_SecItemDelete(CFDictionaryRef query) {
    if (_isHavocLicenseQuery(query)) {
        NSLog(@"[TRBypass v16] SecItemDelete: Havoc license delete intercepted, faking success (data preserved)");
        return errSecSuccess;
    }
    return original_SecItemDelete(query);
}

// ============================================================================
#pragma mark - NSURLSession Swizzle (Havoc API interception fallback)
// ============================================================================

static IMP _original_dataTaskWithRequest_imp = NULL;

static NSURLSessionDataTask *_hooked_dataTaskWithRequest(id self, SEL _cmd,
    NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {

    NSString *urlString = request.URL.absoluteString.lowercaseString;

    // Check for Havoc API endpoints
    BOOL isHavocAPI = [urlString containsString:@"havoc.app"] ||
                      [urlString containsString:@"api.havoc"] ||
                      [urlString containsString:@"havoc-api"];

    if (isHavocAPI) {
        NSLog(@"[TRBypass v16] NSURLSession: Intercepted Havoc API request → %@", request.URL.absoluteString);

        // Create fake successful HTTP response
        NSHTTPURLResponse *fakeResponse = [[NSHTTPURLResponse alloc]
            initWithURL:request.URL
            statusCode:200
            HTTPVersion:@"HTTP/1.1"
            headerFields:@{
                @"Content-Type": @"application/json; charset=utf-8",
                @"Server": @"nginx",
                @"Date": @"Mon, 01 Jan 2025 00:00:00 GMT"
            }];

        // Fake Havoc API response body
        NSDictionary *fakeBody = @{
            @"success": @YES,
            @"code": @200,
            @"message": @"License validated successfully",
            @"data": @{
                @"id": @"bypass_v16",
                @"license_key": @"TRBYASS-V16-FAKE-LICENSE",
                @"email": @"bypass@v16.local",
                @"device_id": @"00000000-0000-0000-0000-000000000000",
                @"purchased_at": @"2025-01-01T00:00:00Z",
                @"updates_available_until": @"2099-12-31T23:59:59Z",
                @"next_charge_at": @9999999999,
                @"day_before_expiration": @99999,
                @"need_to_update": @NO,
                @"activated": @YES,
                @"tier": @"pro",
                @"max_devices": @99,
                @"signature": @"BYPASS_V16_FAKE_SIGNATURE"
            }
        };
        NSData *fakeData = [NSJSONSerialization dataWithJSONObject:fakeBody options:0 error:nil];

        // Call completion handler on next runloop iteration (async, like real network)
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(fakeData, fakeResponse, nil);
            });
        }

        // Return the original task (it will fire its own completion but that's harmless since we already handled it)
        // The fake completion runs first on main queue, setting app state to "activated"
        // Any subsequent real completion is a no-op because app is already activated
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void(^)(NSData *, NSURLResponse *, NSError *)))_original_dataTaskWithRequest_imp)(self, _cmd, request, completionHandler);
    }

    // Not Havoc API → pass through
    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void(^)(NSData *, NSURLResponse *, NSError *)))_original_dataTaskWithRequest_imp)(self, _cmd, request, completionHandler);
}

static void _installNSURLSessionHook(void) {
    // NSURLSession might be loaded lazily, wait a bit
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class sessionClass = NSClassFromString(@"NSURLSession");
        if (!sessionClass) {
            NSLog(@"[TRBypass v16] NSURLSession class not found, skipping hook");
            return;
        }

        SEL sel = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
        Method method = class_getInstanceMethod(sessionClass, sel);
        if (!method) {
            NSLog(@"[TRBypass v16] NSURLSession dataTaskWithRequest:completionHandler: not found");
            return;
        }

        _original_dataTaskWithRequest_imp = method_getImplementation(method);
        method_setImplementation(method, (IMP)_hooked_dataTaskWithRequest);

        NSLog(@"[TRBypass v16] NSURLSession hook installed successfully");
    });
}

// ============================================================================
#pragma mark - NSUserDefaults Pre-population (Layer 1)
// ============================================================================

static void _presetUserDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Havoc-related keys (trial/common patterns)
    NSDictionary *presets = @{
        @"havoc_license_activated": @YES,
        @"havoc_license_valid": @YES,
        @"havoc_trial_used": @NO,
        @"havoc_activation_date": @"2025-01-01T00:00:00Z",
        @"havoc_expiry_date": @"2099-12-31T23:59:59Z",
        @"license_activated": @YES,
        @"is_pro": @YES,
        @"is_premium": @YES,
        @"has_valid_license": @YES,
        @"purchase_verified": @YES,
        @"trial_started": @NO,
        @"trial_ended": @NO,
        @"pro_features_enabled": @YES,
        @"auto_record_enabled": @YES,
        @"biometric_lock_enabled": @YES,
        @"advanced_metadata_enabled": @YES,
        @"post_processing_enabled": @YES,
        @"watermark_removed": @YES,
        @"has_lifetime_license": @YES,
        @"TRHasProLicense": @YES,
        @"TRLicenseValid": @YES,
        @"TRActivationComplete": @YES,
    };

    for (NSString *key in presets) {
        if ([defaults objectForKey:key] == nil) {
            [defaults setObject:presets[key] forKey:key];
        }
    }

    [defaults synchronize];
    NSLog(@"[TRBypass v16] NSUserDefaults pre-populated with %lu keys", (unsigned long)presets.count);
}

// ============================================================================
#pragma mark - CFNotificationCenter Interception (Layer 2)
// ============================================================================

static void _notificationCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    NSString *noteName = (__bridge NSString *)name;
    NSLog(@"[TRBypass v16] Notification intercepted: %@", noteName);
    // Silently consume purchase-related notifications to prevent
    // the app from re-checking license status on notification triggers
}

static void _installNotificationInterceptor(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();

    // Purchase and license-related notification names (Havoc common patterns)
    NSArray *noteNames = @[
        @"com.havoc.purchaseCompleted",
        @"com.havoc.licenseUpdated",
        @"com.havoc.restoreCompleted",
        @"HavocPurchaseNotification",
        @"HavocLicenseChanged",
        @"UIApplicationDidBecomeActiveNotification",
        @"TRPurchaseStatusChanged",
        @"TRLicenseVerified",
    ];

    for (NSString *name in noteNames) {
        CFNotificationCenterAddObserver(
            center, NULL, _notificationCallback,
            (__bridge CFStringRef)name, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }

    NSLog(@"[TRBypass v16] Notification interceptor installed for %lu patterns", (unsigned long)noteNames.count);
}

// ============================================================================
#pragma mark - ObjC Method Swizzle (Layer 5, best-effort from v15)
// ============================================================================

// Verification method names to swizzle (ObjC-only subset)
static NSArray<NSString *> *_verificationSelectors(void) {
    return @[
        @"isActivated",
        @"hasValidLicense",
        @"isLicenseExpired",
        @"validateLicense",
        @"checkLicense",
        @"verifyPurchase",
        @"checkPurchaseStatus",
        @"isTrialExpired",
        @"isPro",
        @"isPremium",
        @"isPaidUser",
        @"hasFeature:",
        @"canAccessFeature:",
        @"shouldShowWatermark",
        @"needsActivation",
        @"isFeatureUnlocked:",
    ];
}

typedef BOOL (*BoolMethod)(id, SEL);
typedef id (*IdMethod)(id, SEL);

static BOOL _ret_YES(id self, SEL _cmd) { return YES; }
static BOOL _ret_NO(id self, SEL _cmd) { return NO; }
static id _ret_activated(id self, SEL _cmd) { return @"activated"; }
static id _ret_pro(id self, SEL _cmd) { return @"pro"; }

static void _swizzleVerificationMethods(void) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount == 0) return;

    Class *classes = (Class *)malloc(classCount * sizeof(Class));
    classCount = objc_getClassList(classes, classCount);

    NSArray *selectors = _verificationSelectors();
    int swizzled = 0;

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        // Only process TrollRecorder classes (heuristic: class name contains relevant keywords)
        NSString *className = NSStringFromClass(cls);
        NSString *lower = [className lowercaseString];
        if (![lower containsString:@"troll"] &&
            ![lower containsString:@"recorder"] &&
            ![lower containsString:@"tr"] &&
            ![lower containsString:@"havoc"] &&
            ![lower containsString:@"license"] &&
            ![lower containsString:@"activation"]) {
            continue;
        }

        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) continue;

            IMP newImp = NULL;
            // Determine return type by selector name pattern
            if ([selName hasPrefix:@"is"] ||
                [selName hasPrefix:@"has"] ||
                [selName hasPrefix:@"can"] ||
                [selName hasPrefix:@"should"] ||
                [selName hasPrefix:@"needs"] ||
                [selName hasPrefix:@"check"] ||
                [selName hasPrefix:@"verify"]) {
                newImp = (IMP)_ret_YES;
            } else if ([selName isEqualToString:@"isFeatureUnlocked:"]) {
                newImp = (IMP)_ret_YES;
            } else {
                // String-returning methods
                newImp = (IMP)_ret_activated;
            }

            if (newImp) {
                method_setImplementation(method, newImp);
                swizzled++;
            }
        }
    }

    free(classes);
    NSLog(@"[TRBypass v16] ObjC brute-force swizzle: %d methods replaced across %d classes",
          swizzled, classCount);
}

// ============================================================================
#pragma mark - Constructor (Main Entry Point)
// ============================================================================

__attribute__((constructor))
static void _bypass_init(void) {
    NSLog(@"[TRBypass v16] ========================================");
    NSLog(@"[TRBypass v16] TrollRecorder Bypass v16 Initializing");
    NSLog(@"[TRBypass v16] Strategy: fishhook(Keychain) + swizzle(NSURLSession) + UserDefaults + Notification");
    NSLog(@"[TRBypass v16] ========================================");

    // ---- Phase 1: Pre-populate UserDefaults (before any app code runs) ----
    _presetUserDefaults();

    // ---- Phase 2: Install fishhook for Keychain C functions ----
    struct _rebinding rebindings[] = {
        {"SecItemCopyMatching", _hooked_SecItemCopyMatching, (void **)&original_SecItemCopyMatching},
        {"SecItemAdd", _hooked_SecItemAdd, (void **)&original_SecItemAdd},
        {"SecItemDelete", _hooked_SecItemDelete, (void **)&original_SecItemDelete},
    };

    _rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));

    // Verify hooks took effect
    if (original_SecItemCopyMatching) {
        NSLog(@"[TRBypass v16] ✓ SecItemCopyMatching hooked");
    } else {
        NSLog(@"[TRBypass v16] ✗ SecItemCopyMatching hook FAILED — original pointer is NULL");
    }
    if (original_SecItemAdd) {
        NSLog(@"[TRBypass v16] ✓ SecItemAdd hooked");
    } else {
        NSLog(@"[TRBypass v16] ✗ SecItemAdd hook FAILED");
    }
    if (original_SecItemDelete) {
        NSLog(@"[TRBypass v16] ✓ SecItemDelete hooked");
    } else {
        NSLog(@"[TRBypass v16] ✗ SecItemDelete hook FAILED");
    }

    // ---- Phase 3: Install NSURLSession swizzle (delayed) ----
    _installNSURLSessionHook();

    // ---- Phase 4: Install Notification interceptor ----
    _installNotificationInterceptor();

    // ---- Phase 5: Install ObjC brute-force swizzle (delayed, best-effort) ----
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _swizzleVerificationMethods();
    });

    NSLog(@"[TRBypass v16] Initialization complete. Waiting for app to launch...");
}
