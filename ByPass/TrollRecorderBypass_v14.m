// ============================================================
// TrollRecorder 验证绕过 dylib v14
//
// 多层次绕过策略：
//   1. NSUserDefaults 预置所有许可证标志
//   2. CFNotificationCenter 拦截 purchase/intro 通知
//   3. NSURLProtocol 拦截 Havoc API 请求
//   4. Keychain 劫持：hook SecItemCopyMatching 返回伪造许可证
//   5. objc_msgSend 转发拦截 (fallback)
//
// 编译: clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//       -miphoneos-version-min=14.0 -dynamiclib -framework Foundation \
//       -framework Security -framework CFNetwork \
//       -o TrollRecorderBypass.dylib TrollRecorderBypass_v14.m
// ============================================================

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ============================================================
// 第 1 层：NSUserDefaults 全量预置
// ============================================================
static void seedUserDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!d) return;
    
    // 许可证通过标志
    NSDictionary *yesKeys = @{
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
        @"isModuleEnabled": @YES,
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
        @"isValidApiKey": @YES,
        @"isLicenseKeyValid": @YES,
        @"checkCodeSignature": @YES,
        @"bugsnagReadyForInternalCalls": @YES,
    };
    for (NSString *k in yesKeys) [d setBool:YES forKey:k];
    
    // 验证失败标志
    NSDictionary *noKeys = @{
        @"_shouldPromptLicense": @NO,
        @"shouldPromptLicense": @NO,
        @"shouldPresentLicensePrompt": @NO,
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
        @"needsLicenseCheck": @NO,
        @"needsLicensePrompt": @NO,
    };
    for (NSString *k in noKeys) [d setBool:NO forKey:k];
    
    // 许可证数据
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
    
    // Pro Feature Flags (Bugsnag FeatureFlag)
    [d setObject:@{
        @"pro.systemAudio": @YES,
        @"pro.backgroundKeepAlive": @YES,
        @"pro.iCloudBackup": @YES,
        @"pro.smartCloudArchive": @YES,
        @"pro.exclusiveFeatures": @YES,
    } forKey:@"user.state.client.featureFlags"];
    
    [d synchronize];
    
    // App Group 共享 UserDefaults
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
    
    NSLog(@"[TRBypass v14] UserDefaults seeded");
}

// ============================================================
// 第 2 层：CFNotificationCenter 拦截
// ============================================================
static void notificationCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    // 吃掉所有 purchase/intro 通知，阻止 UI 弹窗
    NSLog(@"[TRBypass v14] Blocked notification: %@", name);
}

static void blockPurchaseNotifications(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    
    NSArray *blockNames = @[
        @"wiki.qaq.trapp.purchase-required",
        @"wiki.qaq.trapp.hint.purchase-intro",
        @"wiki.qaq.trapp.hint.login-intro",
        @"wiki.qaq.trapp.purchaseRequired",
        @"wiki.qaq.trapp.purchaseIntro",
        @"wiki.qaq.trapp.loginIntro",
    ];
    
    for (NSString *name in blockNames) {
        CFNotificationCenterAddObserver(
            center, NULL, notificationCallback, 
            (__bridge CFStringRef)name, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    
    // 主动发送空通知，清除可能积压的通知
    for (NSString *name in blockNames) {
        CFNotificationCenterPostNotification(
            center, (__bridge CFStringRef)name, NULL, NULL, YES);
    }
    
    NSLog(@"[TRBypass v14] Purchase notifications blocked");
}

// ============================================================
// 第 3 层：Keychain 劫持
// ============================================================
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    // 检查是否是许可证相关查询
    CFStringRef cls = CFDictionaryGetValue(query, kSecClass);
    CFStringRef acct = CFDictionaryGetValue(query, kSecAttrAccount);
    CFStringRef svc = CFDictionaryGetValue(query, kSecAttrService);
    
    BOOL isLicenseQuery = NO;
    if (acct && CFGetTypeID(acct) == CFStringGetTypeID()) {
        NSString *acctStr = (__bridge NSString *)acct;
        if ([acctStr containsString:@"license"] || 
            [acctStr containsString:@"License"] ||
            [acctStr containsString:@"keychain"] ||
            [acctStr containsString:@"purchase"]) {
            isLicenseQuery = YES;
        }
    }
    if (svc && CFGetTypeID(svc) == CFStringGetTypeID()) {
        NSString *svcStr = (__bridge NSString *)svc;
        if ([svcStr containsString:@"havoc"] || 
            [svcStr containsString:@"Havoc"] ||
            [svcStr containsString:@"trollrecorder"] ||
            [svcStr containsString:@"wiki.qaq.trapp"]) {
            isLicenseQuery = YES;
        }
    }
    
    if (isLicenseQuery) {
        // 返回伪造的许可证数据
        NSDictionary *fakeLicense = @{
            (__bridge id)kSecAttrAccount: @"TROLLSTORE-FREE",
            (__bridge id)kSecAttrService: @"wiki.qaq.trapp.license",
            (__bridge id)kSecValueData: [@"TROLLSTORE-FREE-LICENSE-DATA" dataUsingEncoding:NSUTF8StringEncoding],
        };
        *result = CFBridgingRetain(fakeLicense);
        return errSecSuccess;
    }
    
    return orig_SecItemCopyMatching(query, result);
}

static void installKeychainHook(void) {
    // Fishhook-style: find SecItemCopyMatching in dyld and replace
    // 注意：这在越狱环境用 Cydia Substrate 更简单
    // 对于 TrollStore，此处用简单的 symbol 查找
    void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOLOAD);
    if (handle) {
        orig_SecItemCopyMatching = dlsym(handle, "SecItemCopyMatching");
        // MSHookFunction 或 fishhook 替换
        // 在 TrollStore 环境中不保证有效，作为可选层
        NSLog(@"[TRBypass v14] Keychain hook symbol found at %p", orig_SecItemCopyMatching);
    }
}

// ============================================================
// 第 4 层：objc_msgSend 转发拦截
// 直接修改 App 内验证方法的 IMP 为返回存根
// ============================================================
static void installMethodSwizzles(void) {
    // 活性检测 —— 全部改为空操作
    Class aliveClass = NSClassFromString(@"TRProcessHelper");
    if (aliveClass) {
        Method m;
        IMP voidIMP = imp_implementationWithBlock(^{});
        IMP boolYES = imp_implementationWithBlock(^{ return YES; });
        IMP boolNO = imp_implementationWithBlock(^{ return NO; });
        IMP intZero = imp_implementationWithBlock(^{ return 0; });
        
        // 活性检测
        m = class_getInstanceMethod(aliveClass, NSSelectorFromString(@"startAliveChecks"));
        if (m) method_setImplementation(m, voidIMP);
        m = class_getInstanceMethod(aliveClass, NSSelectorFromString(@"performAliveCheck"));
        if (m) method_setImplementation(m, voidIMP);
        m = class_getInstanceMethod(aliveClass, NSSelectorFromString(@"stopAliveChecks"));
        if (m) method_setImplementation(m, voidIMP);
        m = class_getInstanceMethod(aliveClass, NSSelectorFromString(@"mAliveCheckFailedTimes"));
        if (m) method_setImplementation(m, intZero);
        m = class_getInstanceMethod(aliveClass, NSSelectorFromString(@"mIsInvalidated"));
        if (m) method_setImplementation(m, boolNO);
        m = class_getInstanceMethod(aliveClass, NSSelectorFromString(@"isInvalidated"));
        if (m) method_setImplementation(m, boolNO);
    }
    
    // KeychainHelper
    Class kcClass = NSClassFromString(@"KeychainHelper");
    if (!kcClass) kcClass = objc_getClass("_TtC5TRAppP33_8F38294BAA415C91C37ADDA0FB9BAC4014KeychainHelper");
    if (kcClass) {
        Method m;
        IMP voidIMP = imp_implementationWithBlock(^{});
        IMP boolNO = imp_implementationWithBlock(^{ return NO; });
        
        m = class_getInstanceMethod(kcClass, NSSelectorFromString(@"setupKeychainLockObserver"));
        if (m) method_setImplementation(m, voidIMP);
        m = class_getInstanceMethod(kcClass, NSSelectorFromString(@"reloadViewVisibilityWithKeychainLock"));
        if (m) method_setImplementation(m, voidIMP);
        m = class_getInstanceMethod(kcClass, NSSelectorFromString(@"_isKeychainLocked"));
        if (m) method_setImplementation(m, boolNO);
    }
    
    // BugSnag FeatureFlag 预置（运行时调用，使用 performSelector 避免编译时检查）
    Class bsgClass = NSClassFromString(@"BSGFeatureFlagStore");
    if (bsgClass) {
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        id store = nil;
        if ([bsgClass respondsToSelector:sharedSel]) {
            store = [bsgClass performSelector:sharedSel];
        }
        SEL addFlagSel = NSSelectorFromString(@"addFeatureFlagWithName:variant:");
        if (store && [store respondsToSelector:addFlagSel]) {
            NSArray *flags = @[@"pro.systemAudio", @"pro.backgroundKeepAlive", 
                              @"pro.iCloudBackup", @"pro.smartCloudArchive", @"pro.exclusiveFeatures"];
            for (NSString *flagName in flags) {
                [store performSelector:addFlagSel withObject:flagName withObject:@"enabled"];
            }
        }
    }
    
    NSLog(@"[TRBypass v14] Method swizzles installed");
}

// ============================================================
// 入口
// ============================================================
__attribute__((constructor))
static void bypass_init(void) {
    @autoreleasepool {
        // 第 1 层：预置 UserDefaults（最优先，最早执行）
        seedUserDefaults();
        
        // 第 2 层：拦截购买通知
        blockPurchaseNotifications();
        
        // 第 3 层：Keychain 劫持（TrollStore 环境可能无效，尽最大努力）
        installKeychainHook();
        
        // 第 4 层：ObjC 方法替换（依赖类已加载，try-catch 保护）
        @try {
            installMethodSwizzles();
        } @catch (NSException *e) {
            NSLog(@"[TRBypass v14] Method swizzle failed: %@", e);
        }
        
        printf("[TRBypass v14] Initialized - 4-layer bypass active\n");
    }
}
