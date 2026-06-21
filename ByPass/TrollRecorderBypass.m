#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <Foundation/Foundation.h>

// ============================================================
// TrollRecorder 验证绕过 dylib v5
// 基于二进制逆向分析，针对 RootController 的验证逻辑
//
// 分析结果:
//   TRApp.RootController (_TtC5TRApp14RootController) 包含:
//     - shouldSkipCodeSignatureVerification (Tq,N,R) -> 设为 YES 跳过签名检查
//     - _shouldPromptLicense -> 设为 NO 不弹许可提示
//     - purchaseRequiredToken -> 设为 nil 不要求购买
//     - requireVerification / requireLinkDevice -> 设为 NO
//   checkCodeSignature() 在 Constants.swift 中检查 [CS] 签名标记
//   isValidApiKey: 验证 Havoc API Key
// ============================================================

// ---- 查找类 (不区分大小写) ----
static Class findClassCaseInsensitive(const char *partialName) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return NULL;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    
    Class found = NULL;
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        // 部分匹配（不区分大小写）
        if (strlen(partialName) > 0) {
            for (const char *p = name; *p; p++) {
                const char *a = p;
                const char *b = partialName;
                while (*a && *b && tolower(*a) == tolower(*b)) { a++; b++; }
                if (!*b) {
                    found = classes[i];
                    NSLog(@"[TrollRecorderBypass] Found class: %s", name);
                    break;
                }
            }
        }
        if (found) break;
    }
    free(classes);
    return found;
}

// ---- 方法替换辅助 ----
static BOOL patchMethod(Class cls, const char *selName, IMP newImp) {
    SEL sel = sel_getUid(selName);
    if (!sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        // 尝试类方法
        m = class_getClassMethod(cls, sel);
        if (!m) return NO;
    }
    method_setImplementation(m, newImp);
    NSLog(@"[TrollRecorderBypass] Patched [%s %s]", class_getName(cls), selName);
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
    
    NSLog(@"[TrollRecorderBypass] UserDefaults patched");
}

// ---- 写入假 Keychain 数据 ----
static void patchKeychain(void) {
    // 写入假 apiKey 到 Keychain
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"havoc_api_key",
        (__bridge id)kSecAttrService: @"wiki.qaq.trapp",
        (__bridge id)kSecValueData: [@"TROLLSTORE-BYPASS-APIKEY" dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (status == errSecSuccess) {
        NSLog(@"[TrollRecorderBypass] Keychain apiKey added");
    } else if (status == errSecDuplicateItem) {
        // 已存在，更新
        NSDictionary *update = @{
            (__bridge id)kSecValueData: [@"TROLLSTORE-BYPASS-APIKEY" dataUsingEncoding:NSUTF8StringEncoding],
        };
        SecItemUpdate((__bridge CFDictionaryRef)addQuery, (__bridge CFDictionaryRef)update);
        NSLog(@"[TrollRecorderBypass] Keychain apiKey updated");
    }
    
    // 写入假 UserTokenInfo
    NSDictionary *tokenQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"user_token_info",
        (__bridge id)kSecAttrService: @"wiki.qaq.trapp",
        (__bridge id)kSecValueData: [@"{\"token\":\"valid\",\"expiry\":\"2099-12-31\"}" dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    status = SecItemAdd((__bridge CFDictionaryRef)tokenQuery, NULL);
    if (status == errSecSuccess) {
        NSLog(@"[TrollRecorderBypass] Keychain token added");
    }
}

// ---- 方法替换 ----
static void patchAllMethods(void) {
    // 1. RootController: shouldSkipCodeSignatureVerification -> YES
    Class rootCtrl = findClassCaseInsensitive("RootController");
    if (rootCtrl) {
        patchMethod(rootCtrl, "shouldSkipCodeSignatureVerification", imp_implementationWithBlock(^BOOL(id self) { return YES; }));
        patchMethod(rootCtrl, "_shouldPromptLicense", imp_implementationWithBlock(^BOOL(id self) { return NO; }));
        // purchaseRequiredToken -> nil
        SEL tokSel = sel_getUid("purchaseRequiredToken");
        if (tokSel) {
            Method tokM = class_getInstanceMethod(rootCtrl, tokSel);
            if (tokM) {
                method_setImplementation(tokM, imp_implementationWithBlock(^id(id self) { return nil; }));
                NSLog(@"[TrollRecorderBypass] Patched [RootController purchaseRequiredToken]");
            }
        }
    }
    
    // 2. PaymentManager: isValidApiKey: -> YES
    Class payMgr = findClassCaseInsensitive("PaymentManager");
    if (payMgr) {
        patchMethod(payMgr, "isValidApiKey:", imp_implementationWithBlock(^BOOL(id self, id key) { return YES; }));
    }
    
    // 3. 查找任何包含 requireVerification / requireLinkDevice 的类
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            // 检查是否有 requireVerification 方法
            SEL rvSel = sel_getUid("requireVerification");
            if (rvSel && class_getInstanceMethod(classes[i], rvSel)) {
                const char *name = class_getName(classes[i]);
                patchMethod(classes[i], "requireVerification", imp_implementationWithBlock(^BOOL(id self) { return NO; }));
                NSLog(@"[TrollRecorderBypass] Found requireVerification on: %s", name);
            }
            // 检查是否有 requireLinkDevice 方法
            SEL rlSel = sel_getUid("requireLinkDevice");
            if (rlSel && class_getInstanceMethod(classes[i], rlSel)) {
                const char *name = class_getName(classes[i]);
                patchMethod(classes[i], "requireLinkDevice", imp_implementationWithBlock(^BOOL(id self) { return NO; }));
                NSLog(@"[TrollRecorderBypass] Found requireLinkDevice on: %s", name);
            }
        }
        free(classes);
    }
    
    // 4. KeychainHelper: 替换所有验证方法
    Class kcHelper = findClassCaseInsensitive("KeychainHelper");
    if (kcHelper) {
        const char *selectors[] = {
            "isLicensed", "hasValidLicense", "isValidApiKey:", "isVerified",
            "isActivated", "isTrial", "isPremium", "isPro"
        };
        for (int i = 0; i < 8; i++) {
            SEL sel = sel_getUid(selectors[i]);
            if (sel) {
                Method m = class_getInstanceMethod(kcHelper, sel);
                if (m) {
                    method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self, ...) { return YES; }));
                    NSLog(@"[TrollRecorderBypass] Patched [KeychainHelper %s]", selectors[i]);
                }
            }
        }
    }
    
    // 5. FeatureFlagStore: 全部功能启用
    Class ffStore = findClassCaseInsensitive("FeatureFlag");
    if (ffStore) {
        patchMethod(ffStore, "isFeatureEnabled:", imp_implementationWithBlock(^BOOL(id self, id name) { return YES; }));
    }
    
    // 6. 查找所有包含 isPro / isPremium / isTrial 的类并替换
    Class *allClasses = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(allClasses, numClasses);
    const char *checkSels[] = {"isPro", "isPremium", "isTrial", "isActivated", "isVerified"};
    for (int i = 0; i < numClasses; i++) {
        for (int j = 0; j < 5; j++) {
            SEL sel = sel_getUid(checkSels[j]);
            if (sel && class_getInstanceMethod(allClasses[i], sel)) {
                method_setImplementation(class_getInstanceMethod(allClasses[i], sel), 
                    imp_implementationWithBlock(^BOOL(id self) { return YES; }));
                NSLog(@"[TrollRecorderBypass] Patched [%s %s]", class_getName(allClasses[i]), checkSels[j]);
            }
        }
    }
    free(allClasses);
}

// ---- 构造函数 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSLog(@"[TrollRecorderBypass] v5 loaded - targeted verification bypass");
        
        // 1. 预设 UserDefaults
        patchUserDefaults();
        
        // 2. 写入假 Keychain 数据
        patchKeychain();
        
        // 3. 延迟执行方法替换（等所有类加载完毕）
        dispatch_async(dispatch_get_main_queue(), ^{
            patchAllMethods();
            NSLog(@"[TrollRecorderBypass] v5 patch complete");
        });
    }
}