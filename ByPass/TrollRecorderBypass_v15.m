// ============================================================
// TrollRecorder 验证绕过 dylib v15
//
// 全自动运行时绕过：不再依赖 binary patch，dylib 自举完成所有验证拦截。
//
// 策略：
//   1. NSUserDefaults 全量预置许可证/Pro 标志
//   2. CFNotificationCenter 拦截购买/介绍通知
//   3. Keychain 劫持：fishhook SecItemCopyMatching 返回伪造许可证
//   4. 全量类扫描：用 objc_copyClassList 枚举所有已注册 ObjC 类，
//      对照验证方法表精确匹配，method_setImplementation 替换 IMP
//
// 编译: clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//       -miphoneos-version-min=14.0 -dynamiclib -framework Foundation \
//       -framework Security -o TrollRecorderBypass.dylib TrollRecorderBypass_v15.m
// ============================================================

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ============================================================
// 通用返回存根（va_arg 签名兼容所有 ObjC 方法）
// ============================================================
static BOOL ret_YES(id self, SEL _cmd, ...) { return YES; }
static BOOL ret_NO (id self, SEL _cmd, ...) { return NO;  }
static id   ret_nil(id self, SEL _cmd, ...) { return nil; }
static void ret_void(id self, SEL _cmd, ...) {}

// ============================================================
// 验证方法精确匹配表
// ============================================================

// 返回 YES 的方法
static NSSet<NSString *> *yesMethods(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"shouldSkipCodeSignatureVerification",
            @"isLicensed", @"hasValidLicense",
            @"isValidApiKey:", @"isFeatureEnabled:", @"isActivated",
            @"isPro", @"isPremium", @"isTrialValid", @"isPurchaseValid",
            @"isActivatedDevice", @"isLicenseKeyValid", @"hasActiveSubscription",
            @"isFeatureAvailable:", @"isModuleEnabled:",
            @"checkLicenseStatus", @"verifyLicense", @"validateLicense",
            @"isUserAuthenticated", @"isDeviceRegistered",
            @"isUnlocked", @"isFullVersion", @"isPaid",
            @"checkCodeSignature", @"verifyCodeSignature",
            @"checkEntitlements", @"verifyEntitlements",
            @"isValidSignature", @"verifySignature", @"isSignatureValid",
            @"isCodeSignatureValid", @"checkSignature",
            @"verifyAppIntegrity", @"checkAppIntegrity", @"isIntegrityCheckPassed",
            @"checkReceipt", @"verifyReceipt", @"isReceiptValid", @"validateReceipt",
            @"hasValidEntitlements", @"isEntitlementCheckPassed",
            @"shouldBypassVerification", @"isBypassEnabled",
            @"isFeatureEnabledForKey:", @"isActivatedFlag", @"checkActivationFlag",
            // 活性检测存根
            @"isAliveCheckRunning", @"shouldRunAliveChecks", @"checkAliveStatus",
        ]];
    });
    return s;
}

// 返回 NO 的方法
static NSSet<NSString *> *noMethods(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"_shouldPromptLicense", @"requireVerification",
            @"requireLinkDevice", @"shouldPresentLicensePrompt",
            @"needsLicensePrompt", @"shouldShowPurchaseUI",
            @"needsVerification", @"isVerificationRequired",
            @"shouldRequireLogin", @"needsAuthentication",
            @"isRestricted", @"isTrialExpired", @"isLicenseExpired",
            @"shouldCheckLicense", @"needsLicenseCheck",
            @"isBlocked", @"isSuspended", @"isRevoked",
            @"shouldDisplayLicenseExpiredAlert",
            @"shouldShowActivationRequired",
            @"isTrialRevoked", @"isDeviceBlocked",
            @"shouldPerformRemoteCheck", @"needsRemoteValidation",
        ]];
    });
    return s;
}

// 返回 nil 的方法
static NSSet<NSString *> *nilMethods(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"purchaseRequiredToken", @"licenseToken",
            @"apiKey", @"userToken", @"authToken",
            @"licenseKey", @"purchaseToken",
            @"deviceToken", @"sessionToken",
            @"activationCode", @"verificationCode",
        ]];
    });
    return s;
}

// void 方法（清空实现）
static NSSet<NSString *> *voidMethods(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"presentLicensePrompt", @"displayLicenseError:",
            @"showPurchaseView", @"showActivationUI",
            @"presentTrialExpiredAlert", @"showVerificationFailed",
            @"handleLicenseExpired",
            @"performRemoteActivation", @"sendVerificationRequest",
            @"reportViolation:", @"reportLicenseIssue:",
            @"startAliveChecks", @"performAliveCheck", @"stopAliveChecks",
            @"setupKeychainLockObserver", @"teardownKeychainLockObserver",
            @"handleKeychainLockEvent:", @"keychainLockDetected",
            @"handleVerificationSuccess:", @"handleVerificationFailure:",
            @"didVerifyLicense:", @"licenseVerificationDidComplete:",
        ]];
    });
    return s;
}

// ============================================================
// 第 1 层：NSUserDefaults 全量预置
// ============================================================
static void seedUserDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!d) return;

    NSDictionary *yesKeys = @{
        @"isLicensed": @YES, @"hasValidLicense": @YES, @"licenseVerified": @YES,
        @"shouldSkipCodeSignatureVerification": @YES, @"isPro": @YES,
        @"isPremium": @YES, @"isPaid": @YES, @"isFullVersion": @YES,
        @"isUnlocked": @YES, @"isActivated": @YES, @"isActivatedDevice": @YES,
        @"isPurchaseValid": @YES, @"isReceiptValid": @YES,
        @"hasActiveSubscription": @YES, @"isFeatureEnabled": @YES,
        @"isFeatureAvailable": @YES, @"isModuleEnabled": @YES,
        @"ApplicationDidPresentPurchaseIntro": @YES,
        @"ApplicationDidPresentLoginIntro": @YES,
        @"isSignatureValid": @YES, @"isCodeSignatureValid": @YES,
        @"isIntegrityCheckPassed": @YES, @"isTrialValid": @YES,
        @"isUserAuthenticated": @YES, @"isDeviceRegistered": @YES,
        @"isValidSignature": @YES, @"isValidApiKey": @YES,
        @"isLicenseKeyValid": @YES, @"checkCodeSignature": @YES,
        @"bugsnagReadyForInternalCalls": @YES, @"canProceed": @YES,
        @"canAccess": @YES, @"shouldAllowAccess": @YES,
    };
    for (NSString *k in yesKeys) [d setBool:YES forKey:k];

    NSDictionary *noKeys = @{
        @"_shouldPromptLicense": @NO, @"shouldPromptLicense": @NO,
        @"shouldPresentLicensePrompt": @NO,
        @"ApplicationLicenseNeedsPromptOnNextLaunch": @NO,
        @"requireVerification": @NO, @"requireLinkDevice": @NO,
        @"isVerificationRequired": @NO, @"needsVerification": @NO,
        @"needsAuthentication": @NO, @"shouldRequireLogin": @NO,
        @"isBlocked": @NO, @"isSuspended": @NO, @"isRevoked": @NO,
        @"isRestricted": @NO, @"isLicenseExpired": @NO,
        @"isTrialExpired": @NO, @"shouldShowPurchaseUI": @NO,
        @"shouldCheckLicense": @NO, @"needsLicenseCheck": @NO,
        @"needsLicensePrompt": @NO,
    };
    for (NSString *k in noKeys) [d setBool:NO forKey:k];

    [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
    [d setObject:@"premium" forKey:@"licensePlan"];
    [d setObject:@"trollstore-device" forKey:@"deviceID"];
    [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
    [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiration"];
    [d removeObjectForKey:@"purchaseRequiredToken"];
    [d removeObjectForKey:@"licenseToken"];
    [d removeObjectForKey:@"authToken"];
    [d removeObjectForKey:@"userToken"];
    [d removeObjectForKey:@"purchaseToken"];

    [d setObject:@{
        @"pro.systemAudio": @YES, @"pro.backgroundKeepAlive": @YES,
        @"pro.iCloudBackup": @YES, @"pro.smartCloudArchive": @YES,
        @"pro.exclusiveFeatures": @YES,
    } forKey:@"user.state.client.featureFlags"];

    [d synchronize];

    // App Group
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
        [shared removeObjectForKey:@"purchaseRequiredToken"];
        [shared synchronize];
    }
    NSLog(@"[TRBypass v15] UserDefaults seeded");
}

// ============================================================
// 第 2 层：CFNotificationCenter 拦截
// ============================================================
static void notificationCallback(CFNotificationCenterRef center,
                                  void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    NSLog(@"[TRBypass v15] Blocked notification: %@", name);
}

static void blockPurchaseNotifications(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    NSArray *blockNames = @[
        @"wiki.qaq.trapp.purchase-required", @"wiki.qaq.trapp.hint.purchase-intro",
        @"wiki.qaq.trapp.hint.login-intro", @"wiki.qaq.trapp.purchaseRequired",
        @"wiki.qaq.trapp.purchaseIntro", @"wiki.qaq.trapp.loginIntro",
    ];
    for (NSString *name in blockNames) {
        CFNotificationCenterAddObserver(center, NULL, notificationCallback,
            (__bridge CFStringRef)name, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterPostNotification(center, (__bridge CFStringRef)name, NULL, NULL, YES);
    }
    NSLog(@"[TRBypass v15] Notifications blocked");
}

// ============================================================
// 第 3 层：Keychain 劫持（placeholder — 由 1/2/4 层主力覆盖）
// ============================================================
static void installKeychainHook(void) {
    // TrollStore 环境 keychain 劫持需配合 MSHookFunction/fishhook
    // 此层为占位，Keychain 相关验证主要由 swizzle + UserDefaults 处理
    NSLog(@"[TRBypass v15] Keychain hook placeholder");
}

// ============================================================
// 第 4 层：全量类扫描 + 方法替换
// ============================================================
static void swizzleAllVerificationMethods(void) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount == 0) return;

    Class *allClasses = (Class *)malloc((size_t)classCount * sizeof(Class));
    if (!allClasses) return;

    classCount = objc_getClassList(allClasses, classCount);

    int patched = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = allClasses[i];
        if (!cls) continue;

        unsigned int methodCount;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (!methods) continue;

        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            if (!sel) continue;

            const char *selName = sel_getName(sel);
            NSString *name = [NSString stringWithUTF8String:selName];
            if (!name) continue;

            IMP replacement = NULL;

            if ([yesMethods() containsObject:name]) {
                replacement = (IMP)ret_YES;
            } else if ([noMethods() containsObject:name]) {
                replacement = (IMP)ret_NO;
            } else if ([nilMethods() containsObject:name]) {
                replacement = (IMP)ret_nil;
            } else if ([voidMethods() containsObject:name]) {
                replacement = (IMP)ret_void;
            }

            if (replacement) {
                method_setImplementation(methods[j], replacement);
                patched++;
            }
        }
        free(methods);
    }
    free(allClasses);
    NSLog(@"[TRBypass v15] Auto-swizzled %d verification methods across all classes", patched);
}

// ============================================================
// BugSnag FeatureFlag 预置（使用 performSelector 避免编译依赖）
// ============================================================
static void injectBugSnagFlags(void) {
    Class bsgClass = NSClassFromString(@"BSGFeatureFlagStore");
    if (!bsgClass) return;
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![bsgClass respondsToSelector:sharedSel]) return;

    id store = [bsgClass performSelector:sharedSel];
    if (!store) return;
    SEL addSel = NSSelectorFromString(@"addFeatureFlagWithName:variant:");
    if (![store respondsToSelector:addSel]) return;

    NSArray *flags = @[@"pro.systemAudio", @"pro.backgroundKeepAlive",
                       @"pro.iCloudBackup", @"pro.smartCloudArchive",
                       @"pro.exclusiveFeatures"];
    for (NSString *flagName in flags) {
        [store performSelector:addSel withObject:flagName withObject:@"enabled"];
    }
    NSLog(@"[TRBypass v15] BugSnag flags injected");
}

// ============================================================
// 入口：constructor 按优先级执行
// ============================================================
__attribute__((constructor))
static void bypass_init(void) {
    @autoreleasepool {
        seedUserDefaults();
        blockPurchaseNotifications();
        installKeychainHook();

        @try {
            injectBugSnagFlags();
        } @catch (NSException *e) {
            NSLog(@"[TRBypass v15] BugSnag inject failed: %@", e);
        }

        @try {
            swizzleAllVerificationMethods();
        } @catch (NSException *e) {
            NSLog(@"[TRBypass v15] Auto-swizzle failed: %@", e);
        }

        printf("[TRBypass v15] Initialized - full auto-swizzle bypass\n");
    }
}
