#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Foundation/Foundation.h>
#include <Security/Security.h>

// ============================================================
// TrollRecorder 验证绕过 dylib v7
// 核心策略：Hook 数据源（Keychain + UserDefaults），而非逐个方法
// ============================================================

// ---- 原始函数指针 ----
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = NULL;
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = NULL;

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
    // 匹配所有 wiki.qaq.trapp 相关的 service
    NSArray *services = @[
        @"wiki.qaq.trapp",
        @"group.wiki.qaq.trapp",
        @"GXZ23M5TP2.wiki.qaq.trapp",
        @"GXZ23M5TP2.iCloud.wiki.qaq.trapp.icloud-container",
        @"wiki.qaq.trapp.xpc",
    ];
    NSString *s = (__bridge NSString *)service;
    for (NSString *svc in services) {
        if ([s isEqualToString:svc] || [s containsString:svc] || [svc containsString:s]) {
            return YES;
        }
    }
    // 也匹配包含 "wiki.qaq.trapp" 的
    if ([s containsString:@"wiki.qaq.trapp"]) return YES;
    return NO;
}

// ---- Hook SecItemCopyMatching ----
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    // 获取原始函数
    if (!orig_SecItemCopyMatching) {
        orig_SecItemCopyMatching = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
        if (!orig_SecItemCopyMatching || orig_SecItemCopyMatching == SecItemCopyMatching) {
            // 自己找自己，说明还未加载，尝试 dlopen
            void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD);
            if (handle) {
                orig_SecItemCopyMatching = dlsym(handle, "SecItemCopyMatching");
            }
        }
        if (!orig_SecItemCopyMatching || orig_SecItemCopyMatching == SecItemCopyMatching) {
            return errSecNotAvailable;
        }
    }
    
    if (query && result) {
        CFStringRef service = CFDictionaryGetValue(query, kSecAttrService);
        CFStringRef account = CFDictionaryGetValue(query, kSecAttrAccount);
        
        if (isAppKeychainService(service) && account) {
            NSString *acct = (__bridge NSString *)account;
            NSDictionary *fakeData = fakeKeychainData();
            NSString *fakeStr = fakeData[acct];
            
            if (fakeStr) {
                // 检查是否是返回数据的查询
                if (CFDictionaryGetValue(query, kSecReturnData)) {
                    *result = (__bridge_retained CFDataRef)[fakeStr dataUsingEncoding:NSUTF8StringEncoding];
                    return errSecSuccess;
                }
            }
            
            // 对于任何查询，如果匹配 app service，返回成功
            // 如果查询需要返回数据但没有预置数据，返回空数据
            if (CFDictionaryGetValue(query, kSecReturnData)) {
                *result = (__bridge_retained CFDataRef)[@"{\"valid\":true,\"status\":\"active\"}" dataUsingEncoding:NSUTF8StringEncoding];
                return errSecSuccess;
            }
        }
        
        // 也检查 kSecAttrService 为 nil 但有 access group 的情况
        if (!service) {
            CFStringRef accessGroup = CFDictionaryGetValue(query, kSecAttrAccessGroup);
            if (accessGroup && isAppKeychainService(accessGroup)) {
                if (CFDictionaryGetValue(query, kSecReturnData)) {
                    *result = (__bridge_retained CFDataRef)[@"{\"valid\":true}" dataUsingEncoding:NSUTF8StringEncoding];
                    return errSecSuccess;
                }
            }
        }
    }
    
    return orig_SecItemCopyMatching(query, result);
}

// ---- Hook SecItemAdd ----
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!orig_SecItemAdd) {
        orig_SecItemAdd = dlsym(RTLD_DEFAULT, "SecItemAdd");
        if (!orig_SecItemAdd || orig_SecItemAdd == SecItemAdd) {
            void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD);
            if (handle) {
                orig_SecItemAdd = dlsym(handle, "SecItemAdd");
            }
        }
        if (!orig_SecItemAdd || orig_SecItemAdd == SecItemAdd) {
            return errSecNotAvailable;
        }
    }
    
    // 对于 app 的 Keychain 写入，假装成功
    if (attributes) {
        CFStringRef service = CFDictionaryGetValue(attributes, kSecAttrService);
        if (isAppKeychainService(service)) {
            return errSecSuccess;
        }
    }
    
    return orig_SecItemAdd(attributes, result);
}

// ---- NSUserDefaults 验证相关 key 列表 ----
static NSSet *verificationKeys(void) {
    static NSSet *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            // 许可证相关
            @"isLicensed", @"hasValidLicense", @"licenseVerified", @"licenseKey",
            @"licensePlan", @"licenseExpiryDate", @"licenseToken", @"purchaseRequiredToken",
            // 签名验证
            @"shouldSkipCodeSignatureVerification", @"isSignatureValid", @"isCodeSignatureValid",
            // 提示
            @"_shouldPromptLicense", @"previousShouldPromptLicense",
            @"ApplicationLicenseNeedsPromptOnNextLaunch",
            @"ApplicationDidPresentPurchaseIntro", @"ApplicationDidPresentLoginIntro",
            // 验证要求
            @"requireVerification", @"requireLinkDevice", @"isVerificationRequired",
            @"needsVerification", @"needsAuthentication", @"needsLicense",
            // 购买/高级
            @"isPro", @"isPremium", @"isPaid", @"isFullVersion", @"isUnlocked",
            @"isActivated", @"isActivatedDevice",
            @"isPurchaseValid", @"isReceiptValid", @"hasActiveSubscription",
            // 状态
            @"isBlocked", @"isSuspended", @"isRevoked", @"isRestricted",
            @"isTrialValid", @"isTrialExpired", @"isLicenseExpired",
            // 功能
            @"isFeatureEnabled", @"isFeatureAvailable", @"isModuleEnabled",
            // 访问
            @"shouldAllowAccess", @"canProceed", @"canAccess",
            @"isUserAuthenticated", @"isDeviceRegistered",
            // API
            @"apiKey", @"userToken", @"authToken",
        ]];
    });
    return keys;
}

// 返回 YES 的 key
static NSSet *returnYesKeys(void) {
    static NSSet *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"isLicensed", @"hasValidLicense", @"licenseVerified",
            @"shouldSkipCodeSignatureVerification", @"isSignatureValid", @"isCodeSignatureValid",
            @"ApplicationDidPresentPurchaseIntro", @"ApplicationDidPresentLoginIntro",
            @"isPro", @"isPremium", @"isPaid", @"isFullVersion", @"isUnlocked",
            @"isActivated", @"isActivatedDevice",
            @"isPurchaseValid", @"isReceiptValid", @"hasActiveSubscription",
            @"isFeatureEnabled", @"isFeatureAvailable", @"isModuleEnabled",
            @"shouldAllowAccess", @"canProceed", @"canAccess",
            @"isUserAuthenticated", @"isDeviceRegistered",
            @"isTrialValid",
        ]];
    });
    return keys;
}

// ---- 方法替换工具 ----
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

static Class findClass(const char *partialName) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return NULL;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    Class found = NULL;
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (strstr(name, partialName) != NULL) {
            found = classes[i];
            break;
        }
    }
    free(classes);
    return found;
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

// ---- 设置 Keychain ----
static void setupKeychain(void) {
    NSDictionary *fakeData = fakeKeychainData();
    NSArray *services = @[@"wiki.qaq.trapp", @"GXZ23M5TP2.wiki.qaq.trapp"];
    
    for (NSString *svc in services) {
        for (NSString *acct in fakeData) {
            NSString *value = fakeData[acct];
            NSDictionary *addQuery = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrAccount: acct,
                (__bridge id)kSecAttrService: svc,
                (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
                (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
            };
            OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
            if (status == errSecDuplicateItem) {
                NSDictionary *update = @{
                    (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
                };
                orig_SecItemAdd ? SecItemUpdate((__bridge CFDictionaryRef)addQuery, (__bridge CFDictionaryRef)update) : (void)0;
            }
        }
    }
}

// ---- 全面方法替换 ----
static void patchAllVerificationMethods(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    
    // 返回 BOOL YES 的 selector
    const char *returnYesSelectors[] = {
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
        "isReceiptValid", "validateReceipt", "isLicenseKeyValid",
        "isValidApiKey", "checkCodeSignature", "verifyCodeSignature",
        "checkEntitlements", "verifyEntitlements", "verifyAppIntegrity",
        "checkAppIntegrity", "agreeToLicense",
        "isEnabled", "isAvailable", "isSupported", "isAuthorized", "isAllowed",
        NULL
    };
    
    // 返回 BOOL NO 的 selector
    const char *returnNoSelectors[] = {
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
    IMP returnYesWithArgIMP = imp_implementationWithBlock(^BOOL(id self, id arg) { return YES; });
    IMP returnNoIMP = imp_implementationWithBlock(^BOOL(id self) { return NO; });
    
    int patched = 0;
    for (int i = 0; i < numClasses && patched < 500; i++) {
        const char *className = class_getName(classes[i]);
        if (!className) continue;
        
        // 只处理 app 命名空间相关的类
        // 检查是否是 TR* 前缀或包含关键名称
        BOOL isAppClass = NO;
        if (strncmp(className, "TR", 2) == 0) isAppClass = YES;
        else if (strstr(className, "Keychain") != NULL) isAppClass = YES;
        else if (strstr(className, "Payment") != NULL) isAppClass = YES;
        else if (strstr(className, "License") != NULL) isAppClass = YES;
        else if (strstr(className, "Root") != NULL) isAppClass = YES;
        else if (strstr(className, "Feature") != NULL) isAppClass = YES;
        else if (strstr(className, "Purchase") != NULL) isAppClass = YES;
        else if (strstr(className, "Receipt") != NULL) isAppClass = YES;
        else if (strstr(className, "Signature") != NULL) isAppClass = YES;
        else if (strstr(className, "Entitlement") != NULL) isAppClass = YES;
        else if (strstr(className, "BSG") == className) isAppClass = YES;
        else if (strstr(className, "Havoc") != NULL) isAppClass = YES;
        else if (strstr(className, "App") != NULL) isAppClass = YES;
        else if (strstr(className, "Settings") != NULL) isAppClass = YES;
        else if (strstr(className, "Config") != NULL) isAppClass = YES;
        else if (strstr(className, "Store") != NULL) isAppClass = YES;
        else if (strstr(className, "Manager") != NULL) isAppClass = YES;
        
        if (!isAppClass) continue;
        
        // 返回 YES 的方法
        for (int j = 0; returnYesSelectors[j] != NULL; j++) {
            SEL sel = sel_getUid(returnYesSelectors[j]);
            if (!sel) continue;
            Method m = class_getInstanceMethod(classes[i], sel);
            if (!m) m = class_getClassMethod(classes[i], sel);
            if (!m) continue;
            
            // 检查是否有参数
            const char *selName = sel_getName(sel);
            BOOL hasArg = (strchr(selName, ':') != NULL);
            method_setImplementation(m, hasArg ? returnYesWithArgIMP : returnYesIMP);
            patched++;
        }
        
        // 返回 NO 的方法
        for (int j = 0; returnNoSelectors[j] != NULL; j++) {
            SEL sel = sel_getUid(returnNoSelectors[j]);
            if (!sel) continue;
            Method m = class_getInstanceMethod(classes[i], sel);
            if (!m) m = class_getClassMethod(classes[i], sel);
            if (!m) continue;
            method_setImplementation(m, returnNoIMP);
            patched++;
        }
    }
    free(classes);
    printf("[TrollRecorderBypass v7] Patched %d verification methods\n", patched);
}

// ---- 构造函数 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        // 1. 初始化原始函数指针
        void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD);
        if (handle) {
            orig_SecItemCopyMatching = dlsym(handle, "SecItemCopyMatching");
            orig_SecItemAdd = dlsym(handle, "SecItemAdd");
        }
        if (!orig_SecItemCopyMatching) {
            orig_SecItemCopyMatching = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
        }
        if (!orig_SecItemAdd) {
            orig_SecItemAdd = dlsym(RTLD_DEFAULT, "SecItemAdd");
        }
        
        // 2. 设置 UserDefaults
        setupUserDefaults();
        
        // 3. 设置 Keychain（使用原始函数写入）
        if (orig_SecItemAdd) {
            setupKeychain();
        }
        
        // 4. 延迟执行方法替换（使用 dispatch_after 兼容主进程和守护进程）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), 
            dispatch_get_main_queue(), ^{
            patchAllVerificationMethods();
        });
        
        // 5. 也通过 dispatch_async 确保在守护进程中也能执行
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // 等待 1 秒后检查是否已在主线程执行过
            sleep(1);
            // 如果主线程没执行（守护进程），在后台线程执行
            static int patched = 0;
            if (!patched) {
                patched = 1;
                patchAllVerificationMethods();
            }
        });
    }
}