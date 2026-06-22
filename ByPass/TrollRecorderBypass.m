// ============================================================
// TrollRecorder 验证绕过 dylib v10
// 方案：纯 C 函数 IMP 替换（避免 arm64e PAC block 崩溃）
//       + pthread 延迟执行（避免构造函数中 runtime 未初始化）
//       + UserDefaults 预设
//       + 已知类方法替换（不用全局扫描）
// ============================================================

#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Foundation/Foundation.h>

// ---- 纯 C 函数作为 IMP（不用 block，避免 PAC 问题）----
static BOOL return_YES(id self, SEL _cmd) { return YES; }
static BOOL return_YES_arg(id self, SEL _cmd, id arg) { return YES; }
static BOOL return_NO(id self, SEL _cmd) { return NO; }

// ---- 工具函数 ----
static void patch_class_sel(const char *className, const char *selName, IMP imp) {
    if (!className || !selName || !imp) return;
    Class cls = objc_getClass(className);
    if (!cls) {
        // 也尝试 NSClassFromString
        cls = (Class)objc_getClass(className);
        if (!cls) return;
    }
    SEL sel = sel_getUid(selName);
    if (!sel) return;
    
    Method m = class_getInstanceMethod(cls, sel);
    if (m) { method_setImplementation(m, imp); return; }
    m = class_getClassMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

#define PATCH(cls, sel, imp) patch_class_sel(cls, sel, imp)

// ============================================================
// 方法替换线程
// ============================================================
static void *patcher(void *arg) {
    (void)arg;
    // 等 3 秒确保 runtime 完全初始化
    sleep(3);
    
    @autoreleasepool {
        // ---- 1. UserDefaults 预设 ----
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (d) {
            NSDictionary *yesDict = @{
                @"isLicensed": @YES,
                @"hasValidLicense": @YES,
                @"licenseVerified": @YES,
                @"shouldSkipCodeSignatureVerification": @YES,
                @"isPro": @YES,
                @"isPremium": @YES,
                @"isPaid": @YES,
                @"isFullVersion": @YES,
                @"isUnlocked": @YES,
                @"isActivated": @YES,
                @"isActivatedDevice": @YES,
                @"isPurchaseValid": @YES,
                @"isReceiptValid": @YES,
                @"hasActiveSubscription": @YES,
                @"isFeatureEnabled": @YES,
                @"isFeatureAvailable": @YES,
                @"ApplicationDidPresentPurchaseIntro": @YES,
                @"ApplicationDidPresentLoginIntro": @YES,
                @"isSignatureValid": @YES,
                @"isCodeSignatureValid": @YES,
                @"isIntegrityCheckPassed": @YES,
                @"isTrialValid": @YES,
                @"shouldAllowAccess": @YES,
                @"canProceed": @YES,
                @"canAccess": @YES,
                @"isUserAuthenticated": @YES,
                @"isDeviceRegistered": @YES,
                @"isValidSignature": @YES,
            };
            for (NSString *k in yesDict) [d setBool:[yesDict[k] boolValue] forKey:k];
            
            NSDictionary *noDict = @{
                @"_shouldPromptLicense": @NO,
                @"shouldPromptLicense": @NO,
                @"ApplicationLicenseNeedsPromptOnNextLaunch": @NO,
                @"requireVerification": @NO,
                @"requireLinkDevice": @NO,
                @"isVerificationRequired": @NO,
                @"needsVerification": @NO,
                @"needsAuthentication": @NO,
                @"shouldRequireLogin": @NO,
                @"isBlocked": @NO,
                @"isSuspended": @NO,
                @"isRevoked": @NO,
                @"isRestricted": @NO,
                @"isLicenseExpired": @NO,
                @"isTrialExpired": @NO,
                @"shouldShowPurchaseUI": @NO,
                @"shouldCheckLicense": @NO,
            };
            for (NSString *k in noDict) [d setBool:[noDict[k] boolValue] forKey:k];
            
            [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
            [d setObject:@"premium" forKey:@"licensePlan"];
            [d setObject:@"trollstore-device" forKey:@"deviceID"];
            [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
            [d synchronize];
        }
        
        // ---- 2. 共享 UserDefaults ----
        NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
        if (shared) {
            [shared setBool:YES forKey:@"isLicensed"];
            [shared setBool:YES forKey:@"hasValidLicense"];
            [shared setBool:YES forKey:@"shouldSkipCodeSignatureVerification"];
            [shared setBool:YES forKey:@"isPro"];
            [shared setBool:YES forKey:@"isPremium"];
            [shared setBool:YES forKey:@"isActivated"];
            [shared setBool:NO forKey:@"_shouldPromptLicense"];
            [shared setBool:NO forKey:@"requireVerification"];
            [shared setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
            [shared synchronize];
        }
        
        // ---- 3. 修改已知类的方法 ----
        // 需要返回 YES 的 selector 列表
        const char *yesSelList[] = {
            "isLicensed", "hasValidLicense", "licenseVerified",
            "isPro", "isPremium", "isPaid", "isFullVersion", "isUnlocked",
            "isActivated", "isActivatedDevice",
            "isPurchaseValid", "isReceiptValid", "hasActiveSubscription",
            "shouldSkipCodeSignatureVerification",
            "isSignatureValid", "isCodeSignatureValid",
            "isIntegrityCheckPassed", "isTrialValid",
            "shouldAllowAccess", "canProceed", "canAccess",
            "isUserAuthenticated", "isDeviceRegistered",
            "isValidSignature", "agreeToLicense",
            "checkCodeSignature", "verifyCodeSignature",
            "isEnabled", "isAvailable", "isSupported", "isAuthorized", "isAllowed",
            NULL
        };
        const char *yesArgSelList[] = {
            "isValidApiKey:", "isValidLicense:",
            "isFeatureEnabled:", "isFeatureAvailable:",
            "isModuleEnabled:", "isAuthorized:", "isAllowed:",
            NULL
        };
        const char *noSelList[] = {
            "_shouldPromptLicense", "shouldPromptLicense",
            "requireVerification", "requireLinkDevice", "isVerificationRequired",
            "needsVerification", "needsAuthentication",
            "isBlocked", "isSuspended", "isRevoked", "isRestricted",
            "isLicenseExpired", "isTrialExpired",
            "shouldShowPurchaseUI", "shouldCheckLicense",
            NULL
        };
        
        // 已知验证相关类名
        const char *classList[] = {
            "TRKeychainHelper", "TRKeychainManager",
            "TRPaymentManager", "TRPurchaseManager", "TRSubscriptionManager",
            "TRLicenseManager", "TRLicenseController", "TRLicenseChecker", "TRLicenseValidator",
            "TRFeatureManager", "BSGFeatureFlagStore", "BSGFeatureFlagManager",
            "TRHavocAPIClient", "HavocAPIClient",
            "TRReceiptValidator", "TRIntegrityChecker", "TRSignatureVerifier",
            "TRRootController", "TRAppController", "TRAppDelegate",
            "TRSettingsController", "TRConfigManager",
            "TRUserManager", "TRDeviceManager",
            "TRLicense", "TRStateManager", "TRFeature",
            NULL
        };
        
        int totalPatched = 0;
        IMP yesIMP = (IMP)return_YES;
        IMP yesArgIMP = (IMP)return_YES_arg;
        IMP noIMP = (IMP)return_NO;
        
        for (int i = 0; classList[i]; i++) {
            Class cls = objc_getClass(classList[i]);
            if (!cls) continue;
            
            for (int j = 0; yesSelList[j]; j++) {
                SEL sel = sel_getUid(yesSelList[j]);
                if (!sel) continue;
                Method m = class_getInstanceMethod(cls, sel);
                if (m) { method_setImplementation(m, yesIMP); totalPatched++; continue; }
                m = class_getClassMethod(cls, sel);
                if (m) { method_setImplementation(m, yesIMP); totalPatched++; }
            }
            for (int j = 0; yesArgSelList[j]; j++) {
                SEL sel = sel_getUid(yesArgSelList[j]);
                if (!sel) continue;
                Method m = class_getInstanceMethod(cls, sel);
                if (m) { method_setImplementation(m, yesArgIMP); totalPatched++; continue; }
                m = class_getClassMethod(cls, sel);
                if (m) { method_setImplementation(m, yesArgIMP); totalPatched++; }
            }
            for (int j = 0; noSelList[j]; j++) {
                SEL sel = sel_getUid(noSelList[j]);
                if (!sel) continue;
                Method m = class_getInstanceMethod(cls, sel);
                if (m) { method_setImplementation(m, noIMP); totalPatched++; continue; }
                m = class_getClassMethod(cls, sel);
                if (m) { method_setImplementation(m, noIMP); totalPatched++; }
            }
        }
        
        printf("[TRBypass v10] Patched %d methods on known classes\n", totalPatched);
    }
    return NULL;
}

// ============================================================
// 构造函数 - 只做一件事：启动延迟线程
// ============================================================
__attribute__((constructor))
static void init(void) {
    pthread_t th;
    pthread_create(&th, NULL, patcher, NULL);
    pthread_detach(th);
    printf("[TRBypass v10] Loaded, patcher thread started\n");
}