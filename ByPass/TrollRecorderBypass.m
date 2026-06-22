// ============================================================
// TrollRecorder 验证绕过 dylib v11 (最小化版)
// 只做 UserDefaults 预设，不做方法替换
// 目的：先确认注入本身不崩溃，再逐步添加功能
// ============================================================

#include <stdio.h>
#include <Foundation/Foundation.h>

__attribute__((constructor))
static void bypass_init(void) {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (d) {
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
            
            [d setObject:@"TROLLSTORE-FREE" forKey:@"licenseKey"];
            [d setObject:@"premium" forKey:@"licensePlan"];
            [d setObject:@"trollstore-device" forKey:@"deviceID"];
            [d setObject:@"2099-12-31T23:59:59Z" forKey:@"licenseExpiryDate"];
            [d removeObjectForKey:@"purchaseRequiredToken"];
            [d synchronize];
        }
        
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
        
        printf("[TRBypass v11] UserDefaults configured\n");
    }
}