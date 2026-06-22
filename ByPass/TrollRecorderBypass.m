// ============================================================
// TrollRecorder 验证绕过 dylib v13 (极简版)
// - 只做 UserDefaults 预设
// - 不调用 objc_runtime API
// - 不做方法替换
// - 不创建 pthread
// - 只用 Foundation API（NSUserDefaults）
// 目的：排除 dylib 本身导致崩溃的可能性
// ============================================================

#include <stdio.h>
#include <Foundation/Foundation.h>

__attribute__((constructor))
static void bypass_init(void) {
    @autoreleasepool {
        // 1. 标准 UserDefaults
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (d) {
            // 验证通过标志
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
            
            // 验证失败标志（设为 NO）
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
                @"needsLicenseCheck": @NO,
                @"needsLicensePrompt": @NO,
            };
            for (NSString *k in noDict) [d setBool:[noDict[k] boolValue] forKey:k];
            
            // 许可证信息
            [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
            [d setObject:@"premium" forKey:@"licensePlan"];
            [d setObject:@"trollstore-device" forKey:@"deviceID"];
            [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
            [d removeObjectForKey:@"purchaseRequiredToken"];
            [d synchronize];
        }
        
        // 2. 共享 UserDefaults（App Group）
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
        
        printf("[TRBypass v13] UserDefaults configured (minimal, no runtime patching)\n");
    }
}
