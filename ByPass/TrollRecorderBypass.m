// ============================================================
// TrollRecorder 验证绕过 dylib v9
// 方案：ObjC 级别绕过，不 hook C 函数（避免符号冲突）
// 定位 KeychainHelper 等已知类 + UserDefaults 预设 + 全局方法替换
// ============================================================

#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Foundation/Foundation.h>
#include <Security/Security.h>

// ---- 通过 NSClassFromString 查找类并替换方法 ----
static void patchClassMethod(const char *className, const char *selName, IMP imp) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) return;
    SEL sel = sel_getUid(selName);
    if (!sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) { method_setImplementation(m, imp); return; }
    m = class_getClassMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

// ---- 创建替换 IMP ----
static IMP makeYesIMP(void) {
    return imp_implementationWithBlock(^BOOL(id self) { return YES; });
}
static IMP makeYesArgIMP(void) {
    return imp_implementationWithBlock(^BOOL(id self, id arg) { return YES; });
}
static IMP makeNoIMP(void) {
    return imp_implementationWithBlock(^BOOL(id self) { return NO; });
}

// ---- 设置 UserDefaults（构造函数中尽量早执行） ----
static void setupUserDefaults(void) {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (!d) return;
        
        // 全部许可证/状态设为通过
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
        [d setBool:YES forKey:@"isPurchaseValid"];
        [d setBool:YES forKey:@"isReceiptValid"];
        [d setBool:YES forKey:@"hasActiveSubscription"];
        [d setBool:YES forKey:@"isFeatureEnabled"];
        [d setBool:YES forKey:@"isFeatureAvailable"];
        [d setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
        [d setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
        [d setBool:YES forKey:@"isSignatureValid"];
        [d setBool:YES forKey:@"isCodeSignatureValid"];
        [d setBool:YES forKey:@"isIntegrityCheckPassed"];
        [d setBool:YES forKey:@"isTrialValid"];
        [d setBool:YES forKey:@"shouldAllowAccess"];
        [d setBool:YES forKey:@"canProceed"];
        [d setBool:YES forKey:@"canAccess"];
        [d setBool:YES forKey:@"isUserAuthenticated"];
        [d setBool:YES forKey:@"isDeviceRegistered"];
        [d setBool:YES forKey:@"isValidSignature"];
        
        // 全部关闭验证/提示
        [d setBool:NO forKey:@"_shouldPromptLicense"];
        [d setBool:NO forKey:@"shouldPromptLicense"];
        [d setBool:NO forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
        [d setBool:NO forKey:@"requireVerification"];
        [d setBool:NO forKey:@"requireLinkDevice"];
        [d setBool:NO forKey:@"isVerificationRequired"];
        [d setBool:NO forKey:@"needsVerification"];
        [d setBool:NO forKey:@"needsAuthentication"];
        [d setBool:NO forKey:@"shouldRequireLogin"];
        [d setBool:NO forKey:@"isBlocked"];
        [d setBool:NO forKey:@"isSuspended"];
        [d setBool:NO forKey:@"isRevoked"];
        [d setBool:NO forKey:@"isRestricted"];
        [d setBool:NO forKey:@"isLicenseExpired"];
        [d setBool:NO forKey:@"isTrialExpired"];
        [d setBool:NO forKey:@"shouldShowPurchaseUI"];
        [d setBool:NO forKey:@"shouldCheckLicense"];
        [d setBool:NO forKey:@"needsLicenseCheck"];
        [d setBool:NO forKey:@"needsLicensePrompt"];
        
        // 值
        [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
        [d setObject:@"premium" forKey:@"licensePlan"];
        [d setObject:@"trollstore-device" forKey:@"deviceID"];
        [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
        [d removeObjectForKey:@"purchaseRequiredToken"];
        [d synchronize];
        
        // 共享容器
        NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
        if (shared) {
            [shared setBool:YES forKey:@"shouldSkipCodeSignatureVerification"];
            [shared setBool:YES forKey:@"isLicensed"];
            [shared setBool:YES forKey:@"hasValidLicense"];
            [shared setBool:YES forKey:@"isPro"];
            [shared setBool:YES forKey:@"isPremium"];
            [shared setBool:YES forKey:@"isActivated"];
            [shared setBool:NO forKey:@"_shouldPromptLicense"];
            [shared setBool:NO forKey:@"requireVerification"];
            [shared setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
            [shared removeObjectForKey:@"purchaseRequiredToken"];
            [shared synchronize];
        }
    }
}

// ---- 已知验证类的方法替换 ----
static void patchAppClasses(void) {
    @autoreleasepool {
        IMP yes = makeYesIMP();
        IMP yesArg = makeYesArgIMP();
        IMP no = makeNoIMP();
        
        // 已知的验证相关类名列表
        NSArray *classes = @[
            // 主 Keychain 相关
            @"TRKeychainHelper",
            @"TRKeychainManager",
            @"KeychainHelper",
            @"KeychainManager",
            @"TRKeychainItem",
            
            // 支付/购买
            @"TRPaymentManager",
            @"PaymentManager",
            @"TRPaymentHandler",
            @"TRPurchaseManager",
            @"PurchaseManager",
            @"TRStoreManager",
            @"TRSubscriptionManager",
            
            // 许可证
            @"TRLicenseManager",
            @"LicenseManager",
            @"TRLicenseController",
            @"TRLicenseChecker",
            @"TRLicenseValidator",
            
            // 功能开关
            @"TRFeatureManager",
            @"FeatureManager",
            @"BSGFeatureFlagStore",
            @"BSGFeatureFlagManager",
            @"BSGFeatureService",
            @"BSGPurchaseService",
            
            // API/Havoc
            @"TRHavocAPIClient",
            @"HavocAPIClient",
            @"TRAPIClient",
            @"TRHavocService",
            @"HavocService",
            
            // 根控制器
            @"TRRootController",
            @"RootController",
            @"TRRootViewController",
            @"TRTabBarController",
            
            // 应用相关
            @"TRAppController",
            @"TRAppDelegate",
            @"TRApplication",
            @"TRAppState",
            @"TRAppConfig",
            
            // 收据/签名
            @"TRReceiptValidator",
            @"ReceiptValidator",
            @"TRCodeSignChecker",
            @"TRIntegrityChecker",
            @"TRSignatureVerifier",
            
            // 设置/配置
            @"TRSettingsController",
            @"SettingsController",
            @"TRConfigManager",
            @"ConfigManager",
            
            // 用户/设备
            @"TRUserManager",
            @"UserManager",
            @"TRDeviceManager",
            @"DeviceManager",
            @"TRDeviceAuth",
            
            // 其他 TR 类
            @"TRLicense",
            @"TRPurchase",
            @"TRProduct",
            @"TRStateManager",
            @"TRSessionManager",
            @"TRFeature",
            @"TRModule",
            @"TREntitlement",
            @"TRAuthorization",
        ];
        
        int patched = 0;
        for (NSString *cn in classes) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            
            // 返回 YES 的方法
            NSArray *yesSels = @[
                @"isLicensed", @"hasValidLicense", @"licenseVerified",
                @"isPro", @"isPremium", @"isPaid", @"isFullVersion", @"isUnlocked",
                @"isActivated", @"isActivatedDevice",
                @"isPurchaseValid", @"isReceiptValid", @"hasActiveSubscription",
                @"shouldSkipCodeSignatureVerification",
                @"isSignatureValid", @"isCodeSignatureValid",
                @"isIntegrityCheckPassed", @"isTrialValid",
                @"shouldAllowAccess", @"canProceed", @"canAccess",
                @"isUserAuthenticated", @"isDeviceRegistered",
                @"isValidSignature", @"agreeToLicense",
                @"checkLicense", @"verifyLicense", @"validateLicense",
                @"checkReceipt", @"verifyReceipt", @"checkLicenseStatus",
                @"checkCodeSignature", @"verifyCodeSignature",
                @"checkEntitlements", @"verifyEntitlements",
                @"verifyAppIntegrity", @"checkAppIntegrity",
                @"isValidApiKey:", @"isValidLicense:",
                @"isFeatureEnabled:", @"isFeatureAvailable:",
                @"isModuleEnabled:", @"isAuthorized:", @"isAllowed:",
                @"isEnabled", @"isAvailable", @"isSupported", @"isAuthorized", @"isAllowed",
            ];
            for (NSString *sn in yesSels) {
                SEL sel = sel_getUid([sn UTF8String]);
                if (!sel) continue;
                BOOL hasArg = ([sn containsString:@":"]);
                Method m = class_getInstanceMethod(cls, sel);
                if (m) method_setImplementation(m, hasArg ? yesArg : yes);
                else {
                    m = class_getClassMethod(cls, sel);
                    if (m) method_setImplementation(m, hasArg ? yesArg : yes);
                    else continue;
                }
                patched++;
            }
            
            // 返回 NO 的方法
            NSArray *noSels = @[
                @"_shouldPromptLicense", @"shouldPromptLicense",
                @"shouldPresentLicensePrompt", @"needsLicensePrompt",
                @"shouldShowPurchaseUI", @"shouldCheckLicense",
                @"needsLicenseCheck", @"shouldPresentLicense", @"shouldShowPurchase",
                @"requireVerification", @"requireLinkDevice", @"isVerificationRequired",
                @"needsVerification", @"needsAuthentication", @"shouldRequireLogin",
                @"isBlocked", @"isSuspended", @"isRevoked", @"isRestricted",
                @"isLicenseExpired", @"isTrialExpired",
                @"requireLinkDevice", @"isVerificationRequired",
            ];
            for (NSString *sn in noSels) {
                SEL sel = sel_getUid([sn UTF8String]);
                if (!sel) continue;
                Method m = class_getInstanceMethod(cls, sel);
                if (m) method_setImplementation(m, no);
                else {
                    m = class_getClassMethod(cls, sel);
                    if (m) method_setImplementation(m, no);
                }
                patched++;
            }
        }
        printf("[TRBypass v9] Patched %d methods on %lu known classes\n", patched, (unsigned long)[classes count]);
    }
}

// ---- 全局扫描替换 ----
static void patchAllObjs(void) {
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *clsList = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(clsList, num);
    
    IMP yes = makeYesIMP();
    IMP yesArg = makeYesArgIMP();
    IMP no = makeNoIMP();
    
    const char *yesSels[] = {
        "isLicensed", "hasValidLicense", "isValidApiKey:", "isValidLicense:",
        "isPro", "isPremium", "isPaid", "isFullVersion", "isUnlocked",
        "isActivated", "isActivatedDevice", "isPurchaseValid", "isReceiptValid",
        "hasActiveSubscription",
        "shouldSkipCodeSignatureVerification",
        "isSignatureValid", "isCodeSignatureValid",
        "isIntegrityCheckPassed", "isTrialValid",
        NULL
    };
    
    const char *noSels[] = {
        "_shouldPromptLicense",
        "shouldPromptLicense",
        "requireVerification", "requireLinkDevice",
        "isVerificationRequired",
        "isBlocked", "isSuspended", "isRevoked", "isRestricted",
        "isLicenseExpired", "isTrialExpired",
        NULL
    };
    
    int patched = 0;
    for (int i = 0; i < num && patched < 300; i++) {
        const char *name = class_getName(clsList[i]);
        if (!name) continue;
        // 只处理 TR* 和已知关键类
        BOOL match = NO;
        if (strncmp(name, "TR", 2) == 0) match = YES;
        else if (strstr(name, "Havoc") != NULL) match = YES;
        else if (strncmp(name, "BSG", 3) == 0) match = YES;
        if (!match) continue;
        
        for (int j = 0; yesSels[j]; j++) {
            SEL sel = sel_getUid(yesSels[j]);
            if (!sel) continue;
            Method m = class_getInstanceMethod(clsList[i], sel);
            if (m) { method_setImplementation(m, strchr(yesSels[j], ':') ? yesArg : yes); patched++; continue; }
            m = class_getClassMethod(clsList[i], sel);
            if (m) { method_setImplementation(m, strchr(yesSels[j], ':') ? yesArg : yes); patched++; }
        }
        for (int j = 0; noSels[j]; j++) {
            SEL sel = sel_getUid(noSels[j]);
            if (!sel) continue;
            Method m = class_getInstanceMethod(clsList[i], sel);
            if (m) { method_setImplementation(m, no); patched++; continue; }
            m = class_getClassMethod(clsList[i], sel);
            if (m) { method_setImplementation(m, no); patched++; }
        }
    }
    free(clsList);
    printf("[TRBypass v9] Global: patched %d methods\n", patched);
}

// ============================================================
// 构造函数 - 只做 ObjC 级别的工作，不碰 C 函数
// ============================================================
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        setupUserDefaults();
        // 先替换已知类
        patchAppClasses();
        // 然后全局扫描
        patchAllObjs();
    }
}