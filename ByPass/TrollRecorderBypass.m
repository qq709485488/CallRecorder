#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <Foundation/Foundation.h>

// ============================================================
// TrollRecorder 验证绕过 dylib v6
// 精简版：去掉全类遍历，只做针对性 hook
// 避免守护进程崩溃（守护进程有自己的许可证检查）
// ============================================================

// ---- 查找类 (不区分大小写) ----
static Class findClass(const char *partialName) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return NULL;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    Class found = NULL;
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        for (const char *p = name; *p; p++) {
            const char *a = p, *b = partialName;
            while (*a && *b && tolower(*a) == tolower(*b)) { a++; b++; }
            if (!*b) { found = classes[i]; break; }
        }
        if (found) break;
    }
    free(classes);
    return found;
}

// ---- 方法替换 ----
static BOOL patchMethod(Class cls, const char *selName, IMP newImp) {
    SEL sel = sel_getUid(selName);
    if (!sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        m = class_getClassMethod(cls, sel);
        if (!m) return NO;
    }
    method_setImplementation(m, newImp);
    return YES;
}

// ---- UserDefaults 预设 ----
static void patchUserDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!d) return;
    
    [d setBool:NO forKey:@"_shouldPromptLicense"];
    [d setBool:NO forKey:@"previousShouldPromptLicense"];
    [d setBool:NO forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
    [d setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
    [d setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
    [d setBool:YES forKey:@"isLicensed"];
    [d setBool:YES forKey:@"hasValidLicense"];
    [d setBool:YES forKey:@"licenseVerified"];
    [d setBool:YES forKey:@"shouldSkipCodeSignatureVerification"];
    [d setBool:NO forKey:@"requireVerification"];
    [d setBool:NO forKey:@"requireLinkDevice"];
    [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
    [d setObject:@"premium" forKey:@"licensePlan"];
    [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
    [d removeObjectForKey:@"purchaseRequiredToken"];
    [d synchronize];
    
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
    if (shared) {
        [shared setBool:YES forKey:@"shouldSkipCodeSignatureVerification"];
        [shared setBool:NO forKey:@"_shouldPromptLicense"];
        [shared setBool:NO forKey:@"requireVerification"];
        [shared setBool:NO forKey:@"requireLinkDevice"];
        [shared setBool:YES forKey:@"isLicensed"];
        [shared setBool:YES forKey:@"hasValidLicense"];
        [shared setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
        [shared removeObjectForKey:@"purchaseRequiredToken"];
        [shared synchronize];
    }
}

// ---- 写入假 Keychain 数据 ----
static void patchKeychain(void) {
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"havoc_api_key",
        (__bridge id)kSecAttrService: @"wiki.qaq.trapp",
        (__bridge id)kSecValueData: [@"TROLLSTORE-BYPASS-APIKEY" dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (status == errSecDuplicateItem) {
        NSDictionary *update = @{
            (__bridge id)kSecValueData: [@"TROLLSTORE-BYPASS-APIKEY" dataUsingEncoding:NSUTF8StringEncoding],
        };
        SecItemUpdate((__bridge CFDictionaryRef)addQuery, (__bridge CFDictionaryRef)update);
    }
    
    NSDictionary *tokenQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"user_token_info",
        (__bridge id)kSecAttrService: @"wiki.qaq.trapp",
        (__bridge id)kSecValueData: [@"{\"token\":\"valid\",\"expiry\":\"2099-12-31\"}" dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    SecItemAdd((__bridge CFDictionaryRef)tokenQuery, NULL);
}

// ---- 针对性方法替换（只替换已知的验证方法，不遍历全类） ----
static void patchTargetedMethods(void) {
    // 1. RootController: shouldSkipCodeSignatureVerification
    Class rootCtrl = findClass("RootController");
    if (rootCtrl) {
        patchMethod(rootCtrl, "shouldSkipCodeSignatureVerification", 
            imp_implementationWithBlock(^BOOL(id self) { return YES; }));
        patchMethod(rootCtrl, "_shouldPromptLicense", 
            imp_implementationWithBlock(^BOOL(id self) { return NO; }));
        // purchaseRequiredToken -> nil
        SEL tokSel = sel_getUid("purchaseRequiredToken");
        if (tokSel) {
            Method m = class_getInstanceMethod(rootCtrl, tokSel);
            if (m) method_setImplementation(m, imp_implementationWithBlock(^id(id self) { return nil; }));
        }
    }
    
    // 2. requireVerification / requireLinkDevice - 只在有这些方法的类上替换
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            Method m = class_getInstanceMethod(classes[i], sel_getUid("requireVerification"));
            if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self) { return NO; }));
            m = class_getInstanceMethod(classes[i], sel_getUid("requireLinkDevice"));
            if (m) method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self) { return NO; }));
        }
        free(classes);
    }
    
    // 3. PaymentManager: isValidApiKey:
    Class payMgr = findClass("PaymentManager");
    if (payMgr) {
        patchMethod(payMgr, "isValidApiKey:", 
            imp_implementationWithBlock(^BOOL(id self, id key) { return YES; }));
    }
    
    // 4. KeychainHelper: 只替换 isLicensed 和 hasValidLicense
    Class kcHelper = findClass("KeychainHelper");
    if (kcHelper) {
        patchMethod(kcHelper, "isLicensed", 
            imp_implementationWithBlock(^BOOL(id self) { return YES; }));
        patchMethod(kcHelper, "hasValidLicense", 
            imp_implementationWithBlock(^BOOL(id self) { return YES; }));
    }
    
    // 5. FeatureFlagStore: isFeatureEnabled:
    Class ffStore = findClass("FeatureFlag");
    if (ffStore) {
        patchMethod(ffStore, "isFeatureEnabled:", 
            imp_implementationWithBlock(^BOOL(id self, id name) { return YES; }));
    }
}

// ---- 构造函数 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        // 1. 立即预设 UserDefaults + Keychain（所有进程都需要）
        patchUserDefaults();
        patchKeychain();
        
        // 2. 延迟执行方法替换（等所有类加载完毕）
        dispatch_async(dispatch_get_main_queue(), ^{
            patchTargetedMethods();
        });
    }
}