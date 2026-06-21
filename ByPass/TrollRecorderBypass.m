#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <Security/Security.h>
#include <Foundation/Foundation.h>

// ============================================================
// TrollRecorder 验证绕过 dylib v3
// DYLD_INTERPOSE 挂钩 Keychain 访问 + UserDefaults 预设
// ============================================================

// ---- 原始函数指针 ----
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*original_SecItemDelete)(CFDictionaryRef query);

// ---- 伪造许可证数据 ----
static NSData *fakeLicenseData(void) {
    NSDictionary *license = @{
        @"license_key": @"TROLLSTORE-FREE",
        @"device_id": @"00000000-0000-0000-0000-000000000000",
        @"purchase_date": @"2024-01-01T00:00:00Z",
        @"expiry_date": @"2099-12-31T23:59:59Z",
        @"is_trial": @NO,
        @"is_active": @YES,
        @"plan": @"premium",
        @"features": @[@"call_recording", @"voice_memo", @"system_audio", @"auto_backup", @"floating_hud"]
    };
    return [NSPropertyListSerialization dataWithPropertyList:license format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

// ---- 检测许可证相关 Keychain 查询 ----
static BOOL isLicenseQuery(CFDictionaryRef query) {
    if (!query) return NO;
    NSDictionary *q = (__bridge NSDictionary *)query;
    NSString *service = q[(__bridge NSString *)kSecAttrService];
    NSString *account = q[(__bridge NSString *)kSecAttrAccount];
    NSString *group = q[(__bridge NSString *)kSecAttrAccessGroup];
    
    if (service) {
        if ([service containsString:@"trollrecorder"] ||
            [service containsString:@"wiki.qaq.trapp"] ||
            [service containsString:@"havoc"] ||
            [service containsString:@"TRApp"]) {
            return YES;
        }
    }
    if (account) {
        if ([account containsString:@"license"] ||
            [account containsString:@"purchase"] ||
            [account containsString:@"activation"] ||
            [account containsString:@"trollrecorder"]) {
            return YES;
        }
    }
    if (group) {
        if ([group containsString:@"wiki.qaq.trapp"]) {
            return YES;
        }
    }
    return NO;
}

// ---- 钩子：SecItemCopyMatching ----
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (isLicenseQuery(query)) {
        if (result) {
            NSDictionary *fakeResult = @{
                (__bridge NSString *)kSecValueData: fakeLicenseData(),
                (__bridge NSString *)kSecAttrAccount: @"license",
                (__bridge NSString *)kSecAttrService: @"wiki.qaq.trapp",
                (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
            };
            *result = (__bridge_retained CFTypeRef)fakeResult;
        }
        return errSecSuccess;
    }
    if (original_SecItemCopyMatching) {
        return original_SecItemCopyMatching(query, result);
    }
    return errSecParam;
}

// ---- 钩子：SecItemAdd ----
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (isLicenseQuery(attributes)) {
        return errSecSuccess;
    }
    if (original_SecItemAdd) {
        return original_SecItemAdd(attributes, result);
    }
    return errSecParam;
}

// ---- 钩子：SecItemDelete ----
static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    if (isLicenseQuery(query)) {
        return errSecSuccess;
    }
    if (original_SecItemDelete) {
        return original_SecItemDelete(query);
    }
    return errSecParam;
}

// ---- DYLD_INTERPOSE ----
// 在 dylib 加载时由 dyld 自动处理，比 constructor 更早
__attribute__((used, section("__DATA,__interpose")))
static struct {
    const void *replacement;
    const void *replacee;
} _interposers[] = {
    { (const void *)&hooked_SecItemCopyMatching, (const void *)&SecItemCopyMatching },
    { (const void *)&hooked_SecItemAdd, (const void *)&SecItemAdd },
    { (const void *)&hooked_SecItemDelete, (const void *)&SecItemDelete },
};

// ---- 获取原始函数（通过 dlopen 指定 Security.framework 句柄，绕过 interposer） ----
static void loadOriginalFunctions(void) {
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD);
    if (sec) {
        original_SecItemCopyMatching = dlsym(sec, "SecItemCopyMatching");
        original_SecItemAdd = dlsym(sec, "SecItemAdd");
        original_SecItemDelete = dlsym(sec, "SecItemDelete");
        NSLog(@"[TrollRecorderBypass] Original functions loaded: %p %p %p",
              original_SecItemCopyMatching, original_SecItemAdd, original_SecItemDelete);
    } else {
        NSLog(@"[TrollRecorderBypass] ERROR: Cannot open Security.framework");
    }
}

// ---- UserDefaults 预设 ----
static void patchUserDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!d) return;
    
    [d setBool:NO forKey:@"_shouldPromptLicense"];
    [d setBool:NO forKey:@"previousShouldPromptLicense"];
    [d setBool:NO forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
    [d setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
    [d setBool:YES forKey:@"isLicensed"];
    [d setBool:YES forKey:@"hasValidLicense"];
    [d setBool:YES forKey:@"licenseVerified"];
    [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
    [d setObject:@"premium" forKey:@"licensePlan"];
    [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
    [d synchronize];
    
    // App Group 共享
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
    if (shared) {
        [shared setBool:NO forKey:@"_shouldPromptLicense"];
        [shared setBool:YES forKey:@"isLicensed"];
        [shared setBool:YES forKey:@"hasValidLicense"];
        [shared setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
        [shared synchronize];
    }
    
    NSLog(@"[TrollRecorderBypass] UserDefaults patched");
}

// ---- 轻量级方法替换（只处理已知的特定类） ----
static void patchKeyMethods(void) {
    // 查找 KeychainHelper 类
    Class helperClass = NULL;
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (strstr(name, "KeychainHelper")) {
            helperClass = classes[i];
            NSLog(@"[TrollRecorderBypass] Found KeychainHelper: %s", name);
            break;
        }
    }
    free(classes);
    
    if (helperClass) {
        // 只替换 isLicensed 和 hasValidLicense
        SEL selectors[] = { @selector(isLicensed), @selector(hasValidLicense) };
        for (int i = 0; i < 2; i++) {
            Method m = class_getInstanceMethod(helperClass, selectors[i]);
            if (m) {
                IMP imp = imp_implementationWithBlock(^BOOL(id self) { return YES; });
                method_setImplementation(m, imp);
                NSLog(@"[TrollRecorderBypass] Patched [%s %@]", class_getName(helperClass), NSStringFromSelector(selectors[i]));
            }
        }
    }
    
    // 查找 BSGFeatureFlagStore
    Class bsgs = NULL;
    numClasses = objc_getClassList(NULL, 0);
    classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (strstr(name, "FeatureFlag")) {
            bsgs = classes[i];
            break;
        }
    }
    free(classes);
    
    if (bsgs) {
        Method m = class_getInstanceMethod(bsgs, @selector(isFeatureEnabled:));
        if (m) {
            IMP imp = imp_implementationWithBlock(^BOOL(id self, id name) { return YES; });
            method_setImplementation(m, imp);
            NSLog(@"[TrollRecorderBypass] Patched FeatureFlagStore");
        }
    }
}

// ---- 构造函数 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSLog(@"[TrollRecorderBypass] v3 loaded, installing hooks...");
        
        // 1. 获取原始函数（必须在 interposer 激活后，通过 dlopen(RTLD_NOLOAD) 获取）
        loadOriginalFunctions();
        
        // 2. 预设 UserDefaults
        patchUserDefaults();
        
        // 3. 延迟执行方法替换（等所有类加载完毕）
        dispatch_async(dispatch_get_main_queue(), ^{
            patchKeyMethods();
            NSLog(@"[TrollRecorderBypass] v3 patch complete");
        });
    }
}