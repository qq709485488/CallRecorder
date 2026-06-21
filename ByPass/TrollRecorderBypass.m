#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Security/Security.h>
#include <Foundation/Foundation.h>

// ============================================================
// TrollRecorder 验证绕过 dylib v2
// 使用 DYLD_INTERPOSE 真正挂钩 C 函数 + 运行时方法替换
// ============================================================

// ---- 保存原始函数指针 ----
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

// ---- 检测是否是许可证相关查询 ----
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
    return original_SecItemCopyMatching(query, result);
}

// ---- 钩子：SecItemAdd ----
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (isLicenseQuery(attributes)) {
        return errSecSuccess;
    }
    return original_SecItemAdd(attributes, result);
}

// ---- 钩子：SecItemDelete ----
static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    if (isLicenseQuery(query)) {
        return errSecSuccess;
    }
    return original_SecItemDelete(query);
}

// ---- DYLD_INTERPOSE 结构 ----
// 这会在 dylib 加载时自动挂钩 C 函数，比 constructor 更早执行
__attribute__((used, section("__DATA,__interpose")))
static struct {
    const void *replacement;
    const void *replacee;
} _interposers[] = {
    { (const void *)&hooked_SecItemCopyMatching, (const void *)&SecItemCopyMatching },
    { (const void *)&hooked_SecItemAdd, (const void *)&SecItemAdd },
    { (const void *)&hooked_SecItemDelete, (const void *)&SecItemDelete },
};

// ---- 构造函数：在 dylib 加载时执行 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        // 获取原始函数（通过 RTLD_NEXT 跳过我们的钩子）
        original_SecItemCopyMatching = dlsym(RTLD_NEXT, "SecItemCopyMatching");
        original_SecItemAdd = dlsym(RTLD_NEXT, "SecItemAdd");
        original_SecItemDelete = dlsym(RTLD_NEXT, "SecItemDelete");
        
        NSLog(@"[TrollRecorderBypass] DYLD_INTERPOSE active, hooks installed");
        
        // 立即执行补丁（不延迟！）
        [TrollRecorderBypass applyAllPatches];
    }
}

// ============================================================
// 运行时方法替换
// ============================================================
@interface TrollRecorderBypass : NSObject
@end

@implementation TrollRecorderBypass

+ (void)applyAllPatches {
    // 1. 预置 UserDefaults（最优先）
    [self patchUserDefaults];
    
    // 2. 查找并 swizzle 所有许可证相关方法
    [self patchAllLicenseMethods];
    
    // 3. 补丁 BSGFeatureFlagStore
    [self patchFeatureFlagStore];
    
    NSLog(@"[TrollRecorderBypass] All patches applied");
}

+ (void)patchUserDefaults {
    // 标准 UserDefaults
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *licenseKeys = @[
        @"_shouldPromptLicense",
        @"previousShouldPromptLicense",
        @"ApplicationLicenseNeedsPromptOnNextLaunch",
        @"ApplicationDidPresentPurchaseIntro",
        @"_shouldPromptRating",
        @"_shouldPromptReview",
        @"presentedHintPurchaseIntro",
        @"_trollrecorder_license",
        @"_trollrecorder_activation",
        @"licenseVerified",
        @"isLicensed",
        @"hasValidLicense",
        @"licenseKey",
        @"purchaseRequiredToken",
        @"purchaseVerified",
        @"activationStatus",
        @"trialStartDate",
        @"trialEndDate",
        @"licenseExpiryDate",
        @"licenseType",
        @"licensePlan",
        @"licenseFeatures",
    ];
    for (NSString *key in licenseKeys) {
        [d removeObjectForKey:key];
    }
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
    
    // App Group 共享 UserDefaults
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

+ (void)patchAllLicenseMethods {
    // 遍历所有已加载的类，查找许可证相关方法
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    
    // 要拦截的方法选择器
    SEL licenseSelectors[] = {
        @selector(isLicensed),
        @selector(hasValidLicense),
        @selector(licenseStatus),
        @selector(checkLicense),
        @selector(verifyLicense),
        @selector(validateLicense),
        @selector(loadLicense),
        @selector(readLicense),
        @selector(getLicense),
        @selector(fetchLicense),
        @selector(shouldPromptLicense),
        @selector(needsLicense),
        @selector(requiresLicense),
        @selector(licenseExpired),
        @selector(purchaseRequired),
        @selector(isActivated),
        @selector(activationStatus),
        @selector(isTrialExpired),
        @selector(isFeatureEnabled:),
    };
    int numSelectors = sizeof(licenseSelectors) / sizeof(SEL);
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        const char *className = class_getName(cls);
        
        // 跳过系统类
        if (strncmp(className, "NS", 2) == 0 ||
            strncmp(className, "UI", 2) == 0 ||
            strncmp(className, "CA", 2) == 0 ||
            strncmp(className, "CF", 2) == 0 ||
            strncmp(className, "_NS", 3) == 0 ||
            strncmp(className, "_UI", 3) == 0 ||
            strncmp(className, "__NS", 4) == 0 ||
            strncmp(className, "OS_", 3) == 0 ||
            strncmp(className, "Fig", 3) == 0 ||
            strncmp(className, "AV", 2) == 0 ||
            strncmp(className, "Core", 4) == 0) {
            continue;
        }
        
        // 只处理与许可证/Keychain/购买相关的类
        BOOL isRelevant = NO;
        if (strstr(className, "Keychain") ||
            strstr(className, "License") ||
            strstr(className, "Purchase") ||
            strstr(className, "Feature") ||
            strstr(className, "Store") ||
            strstr(className, "Activation") ||
            strstr(className, "Verify") ||
            strstr(className, "Havoc") ||
            strstr(className, "TRApp") ||
            strstr(className, "BSG")) {
            isRelevant = YES;
        }
        
        if (!isRelevant) continue;
        
        // 检查这个类是否有我们关心的方法
        for (int j = 0; j < numSelectors; j++) {
            SEL sel = licenseSelectors[j];
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) method = class_getClassMethod(cls, sel);
            if (method) {
                NSLog(@"[TrollRecorderBypass] Found method [%s %@]", className, NSStringFromSelector(sel));
                char returnType[256];
                method_getReturnType(method, returnType, sizeof(returnType));
                
                // 返回 BOOL 的方法 -> 返回 YES
                if (strcmp(returnType, "B") == 0 || strcmp(returnType, "c") == 0) {
                    IMP yesImp = imp_implementationWithBlock(^BOOL(id self) { return YES; });
                    method_setImplementation(method, yesImp);
                    NSLog(@"[TrollRecorderBypass]   -> always returns YES");
                }
                // 返回对象的方法 -> 返回 nil 或假数据
                else if (returnType[0] == '@') {
                    if (sel == @selector(loadLicense) || sel == @selector(readLicense) || sel == @selector(getLicense) || sel == @selector(fetchLicense)) {
                        IMP fakeImp = imp_implementationWithBlock(^id(id self) {
                            return @{
                                @"license_key": @"TROLLSTORE-FREE",
                                @"is_active": @YES,
                                @"plan": @"premium",
                                @"expiry_date": @"2099-12-31T23:59:59Z"
                            };
                        });
                        method_setImplementation(method, fakeImp);
                        NSLog(@"[TrollRecorderBypass]   -> returns fake license");
                    } else {
                        IMP nilImp = imp_implementationWithBlock(^id(id self) { return nil; });
                        method_setImplementation(method, nilImp);
                        NSLog(@"[TrollRecorderBypass]   -> returns nil");
                    }
                }
                // isFeatureEnabled: -> 返回 YES
                else if (sel == @selector(isFeatureEnabled:)) {
                    IMP yesImp = imp_implementationWithBlock(^BOOL(id self, id name) { return YES; });
                    method_setImplementation(method, yesImp);
                    NSLog(@"[TrollRecorderBypass]   -> always returns YES");
                }
            }
        }
    }
    free(classes);
}

+ (void)patchFeatureFlagStore {
    Class bsgsClass = NSClassFromString(@"BSGFeatureFlagStore");
    if (!bsgsClass) {
        // 尝试查找包含 "FeatureFlag" 的类
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            const char *name = class_getName(classes[i]);
            if (strstr(name, "FeatureFlag")) {
                bsgsClass = classes[i];
                break;
            }
        }
        free(classes);
    }
    
    if (bsgsClass) {
        Method method = class_getInstanceMethod(bsgsClass, @selector(isFeatureEnabled:));
        if (method) {
            IMP yesImp = imp_implementationWithBlock(^BOOL(id self, id name) { return YES; });
            method_setImplementation(method, yesImp);
            NSLog(@"[TrollRecorderBypass] Patched FeatureFlagStore");
        }
    }
}

@end