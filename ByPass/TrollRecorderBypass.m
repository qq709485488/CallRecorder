// ============================================================
// TrollRecorder 验证绕过 dylib v8
// 核心策略：DYLD_INTERPOSE Hook Keychain + UserDefaults 预设 + 全面方法替换
// 修复：使用 DYLD_INTERPOSE 替代手动函数覆盖，避免符号冲突导致闪退
// ============================================================

#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Foundation/Foundation.h>
#include <Security/Security.h>

// ---- DYLD_INTERPOSE 宏 ----
#define DYLD_INTERPOSE(_replacement, _original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { \
        unsigned long long replacement; \
        unsigned long long original; \
    } _dyld_interpose_ ## _replacement = \
    { (unsigned long long)&_replacement, (unsigned long long)&_original }

// ---- 需要拦截的 Keychain account 和返回数据 ----
static NSDictionary *fakeKeychainData(void) {
    static NSDictionary *data = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        data = @{
            @"havoc_api_key": @"TROLLSTORE-BYPASS-VALID-API-KEY-2024",
            @"user_token_info": @"{\"token\":\"valid\",\"plan\":\"premium\",\"expiry\":\"2099-12-31T23:59:59Z\",\"device_id\":\"trollstore-device\"}",
            @"license_info": @"{\"type\":\"premium\",\"status\":\"active\",\"expiry\":\"2099-12-31\",\"features\":[\"all\"]}",
            @"device_license": @"{\"activated\":true,\"device_count\":1,\"max_devices\":99}",
            @"purchase_receipt": @"{\"valid\":true,\"product_id\":\"premium_lifetime\"}",
            @"api_key_validation": @"{\"valid\":true,\"plan\":\"premium\",\"expires_at\":\"2099-12-31\"}",
            @"subscription_info": @"{\"active\":true,\"plan\":\"premium\",\"renews\":true,\"expiry\":\"2099-12-31\"}",
        };
    });
    return data;
}

// ---- 应用相关 Keychain service ----
static BOOL isAppKeychainService(CFStringRef service) {
    if (!service) return NO;
    NSString *s = (__bridge NSString *)service;
    if ([s containsString:@"wiki.qaq.trapp"]) return YES;
    return NO;
}

// ---- Hook SecItemCopyMatching（DYLD_INTERPOSE 方式）----
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    // 使用 RTLD_NEXT 获取真正的原始函数
    static OSStatus (*real)(CFDictionaryRef, CFTypeRef*) = NULL;
    if (!real) {
        real = dlsym(RTLD_NEXT, "SecItemCopyMatching");
        if (!real) {
            void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOLOAD);
            if (h) real = dlsym(h, "SecItemCopyMatching");
        }
        if (!real) return errSecNotAvailable;
    }
    
    if (query && result) {
        CFStringRef service = CFDictionaryGetValue(query, kSecAttrService);
        CFStringRef account = CFDictionaryGetValue(query, kSecAttrAccount);
        
        if (isAppKeychainService(service) && account) {
            NSString *acct = (__bridge NSString *)account;
            NSDictionary *fake = fakeKeychainData();
            NSString *val = fake[acct];
            if (val && CFDictionaryGetValue(query, kSecReturnData)) {
                *result = (__bridge CFDataRef)[val dataUsingEncoding:NSUTF8StringEncoding];
                return errSecSuccess;
            }
            if (CFDictionaryGetValue(query, kSecReturnData)) {
                *result = (__bridge CFDataRef)[@"{\"valid\":true,\"status\":\"active\"}" dataUsingEncoding:NSUTF8StringEncoding];
                return errSecSuccess;
            }
        }
        
        if (!service) {
            CFStringRef ag = CFDictionaryGetValue(query, kSecAttrAccessGroup);
            if (isAppKeychainService(ag) && CFDictionaryGetValue(query, kSecReturnData)) {
                *result = (__bridge CFDataRef)[@"{\"valid\":true}" dataUsingEncoding:NSUTF8StringEncoding];
                return errSecSuccess;
            }
        }
    }
    
    return real(query, result);
}

// ---- Hook SecItemAdd（DYLD_INTERPOSE 方式）----
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    static OSStatus (*real)(CFDictionaryRef, CFTypeRef*) = NULL;
    if (!real) {
        real = dlsym(RTLD_NEXT, "SecItemAdd");
        if (!real) {
            void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOLOAD);
            if (h) real = dlsym(h, "SecItemAdd");
        }
        if (!real) return errSecNotAvailable;
    }
    
    // 对于 app 的 Keychain 写入，假装成功
    if (attributes) {
        CFStringRef service = CFDictionaryGetValue(attributes, kSecAttrService);
        if (isAppKeychainService(service)) return errSecSuccess;
    }
    return real(attributes, result);
}

// ---- DYLD_INTERPOSE 声明 ----
DYLD_INTERPOSE(hooked_SecItemCopyMatching, SecItemCopyMatching);
DYLD_INTERPOSE(hooked_SecItemAdd, SecItemAdd);

// ---- NSUserDefaults 验证相关 key ----
static NSSet *verificationKeys(void) {
    static NSSet *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"isLicensed", @"hasValidLicense", @"licenseVerified", @"licenseKey",
            @"licensePlan", @"licenseExpiryDate", @"licenseToken", @"purchaseRequiredToken",
            @"shouldSkipCodeSignatureVerification", @"isSignatureValid", @"isCodeSignatureValid",
            @"_shouldPromptLicense", @"previousShouldPromptLicense",
            @"ApplicationLicenseNeedsPromptOnNextLaunch",
            @"ApplicationDidPresentPurchaseIntro", @"ApplicationDidPresentLoginIntro",
            @"requireVerification", @"requireLinkDevice", @"isVerificationRequired",
            @"needsVerification", @"needsAuthentication", @"needsLicense",
            @"isPro", @"isPremium", @"isPaid", @"isFullVersion", @"isUnlocked",
            @"isActivated", @"isActivatedDevice",
            @"isPurchaseValid", @"isReceiptValid", @"hasActiveSubscription",
            @"isBlocked", @"isSuspended", @"isRevoked", @"isRestricted",
            @"isTrialValid", @"isTrialExpired", @"isLicenseExpired",
            @"isFeatureEnabled", @"isFeatureAvailable", @"isModuleEnabled",
            @"shouldAllowAccess", @"canProceed", @"canAccess",
            @"isUserAuthenticated", @"isDeviceRegistered",
            @"apiKey", @"userToken", @"authToken",
        ]];
    });
    return keys;
}

// ---- 方法替换工具 ----
static void patchMethodOnClass(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) { method_setImplementation(m, imp); return; }
    m = class_getClassMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

// ---- 设置 UserDefaults ----
static void setupUserDefaults(void) {
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
    [d setBool:YES forKey:@"isPro"];
    [d setBool:YES forKey:@"isPremium"];
    [d setBool:YES forKey:@"isPaid"];
    [d setBool:YES forKey:@"isFullVersion"];
    [d setBool:YES forKey:@"isUnlocked"];
    [d setBool:YES forKey:@"isActivated"];
    [d setBool:YES forKey:@"isActivatedDevice"];
    [d setBool:NO forKey:@"requireVerification"];
    [d setBool:NO forKey:@"requireLinkDevice"];
    [d setBool:NO forKey:@"isVerificationRequired"];
    [d setBool:NO forKey:@"needsVerification"];
    [d setBool:NO forKey:@"isBlocked"];
    [d setBool:NO forKey:@"isSuspended"];
    [d setBool:NO forKey:@"isRevoked"];
    [d setBool:NO forKey:@"isLicenseExpired"];
    [d setBool:NO forKey:@"isTrialExpired"];
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
        [shared setBool:YES forKey:@"isPro"];
        [shared setBool:YES forKey:@"isPremium"];
        [shared setBool:YES forKey:@"isActivated"];
        [shared setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
        [shared removeObjectForKey:@"purchaseRequiredToken"];
        [shared synchronize];
    }
}

// ---- 全面方法替换（精简版，避免误伤系统类）----
static void patchAllVerificationMethods(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    
    // 返回 BOOL YES 的 selector
    const char *yesSelectors[] = {
        "isLicensed", "hasValidLicense", "isValidApiKey:", "isValidLicense:",
        "isPro", "isPremium", "isPaid", "isFullVersion", "isUnlocked",
        "isActivated", "isActivatedDevice", "isPurchaseValid", "isReceiptValid",
        "hasActiveSubscription", "isFeatureEnabled:", "isFeatureAvailable:",
        "isModuleEnabled:", "shouldSkipCodeSignatureVerification",
        "isSignatureValid", "isCodeSignatureValid", "isIntegrityCheckPassed",
        "shouldAllowAccess", "canProceed", "canAccess",
        "isUserAuthenticated", "isDeviceRegistered", "isTrialValid",
        "isValidSignature", "verifySignature", "checkLicense", "verifyLicense",
        "validateLicense", "checkLicenseStatus", "checkReceipt", "verifyReceipt",
        "isValidApiKey", "checkCodeSignature", "verifyCodeSignature",
        "checkEntitlements", "verifyEntitlements", "verifyAppIntegrity",
        "checkAppIntegrity", "agreeToLicense",
        "isEnabled", "isAvailable", "isSupported", "isAuthorized", "isAllowed",
        NULL
    };
    
    // 返回 BOOL NO 的 selector
    const char *noSelectors[] = {
        "_shouldPromptLicense", "shouldPromptLicense", "shouldPresentLicensePrompt",
        "needsLicensePrompt", "shouldShowPurchaseUI", "shouldCheckLicense",
        "needsLicenseCheck", "shouldPresentLicense", "shouldShowPurchase",
        "requireVerification", "requireLinkDevice", "isVerificationRequired",
        "needsVerification", "needsAuthentication", "shouldRequireLogin",
        "isBlocked", "isSuspended", "isRevoked", "isRestricted",
        "isLicenseExpired", "isTrialExpired",
        NULL
    };
    
    IMP returnYesIMP = imp_implementationWithBlock(^BOOL(id self) { return YES; });
    IMP returnYesArgIMP = imp_implementationWithBlock(^BOOL(id self, id arg) { return YES; });
    IMP returnNoIMP = imp_implementationWithBlock(^BOOL(id self) { return NO; });
    
    int patched = 0;
    for (int i = 0; i < numClasses && patched < 500; i++) {
        const char *cn = class_getName(classes[i]);
        if (!cn) continue;
        
        // 严格匹配：只处理 TR* 前缀或 TR* 子系统的类
        BOOL isAppClass = NO;
        if (strncmp(cn, "TR", 2) == 0) isAppClass = YES;
        else if (strncmp(cn, "_TtC", 4) == 0) {
            // Swift 类名形如 _TtC12TrollRecorder11MyClass
            // 需要进一步检查是否包含应用相关名称
            if (strstr(cn, "Troll") || strstr(cn, "troll") || strstr(cn, "TR") || strstr(cn, "Tr")) {
                isAppClass = YES;
            }
        }
        else if (strstr(cn, "Keychain") && strstr(cn, "TR")) isAppClass = YES;
        else if (strstr(cn, "Payment") && strstr(cn, "TR")) isAppClass = YES;
        else if (strstr(cn, "License") && strstr(cn, "TR")) isAppClass = YES;
        else if (strstr(cn, "Receipt") && strstr(cn, "TR")) isAppClass = YES;
        else if (strstr(cn, "Havoc") != NULL) isAppClass = YES;
        else if (strncmp(cn, "BSG", 3) == 0) isAppClass = YES;
        
        if (!isAppClass) continue;
        
        // 返回 YES 的方法
        for (int j = 0; yesSelectors[j]; j++) {
            SEL sel = sel_getUid(yesSelectors[j]);
            if (!sel) continue;
            const char *sn = sel_getName(sel);
            BOOL hasArg = (strchr(sn, ':') != NULL);
            patchMethodOnClass(classes[i], sel, hasArg ? returnYesArgIMP : returnYesIMP);
            patched++;
        }
        
        // 返回 NO 的方法
        for (int j = 0; noSelectors[j]; j++) {
            SEL sel = sel_getUid(noSelectors[j]);
            if (!sel) continue;
            patchMethodOnClass(classes[i], sel, returnNoIMP);
            patched++;
        }
    }
    free(classes);
    printf("[TrollRecorderBypass v8] Patched %d verification methods\n", patched);
}

// ---- 构造函数 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        // 1. 设置 UserDefaults
        setupUserDefaults();
        
        // 2. 延迟执行方法替换
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            patchAllVerificationMethods();
        });
        
        // 3. 守护进程兼容：如果主队列没执行，全局队列兜底
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            sleep(2);
            static int done = 0;
            if (!done) {
                done = 1;
                patchAllVerificationMethods();
            }
        });
    }
}