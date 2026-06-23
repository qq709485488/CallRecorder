// TrollRecorderBypass_safe.m — 最小安全诊断版本
// 用途：在不引入任何 hook/swizzle 的前提下验证 dylib 加载是否导致 v19 闪退
// 策略：仅做 constructor 诊断日志 + +[load] UserDefaults 预置值，全部 @try/@catch 包裹
// 链接：仅 Foundation framework（不含 Security/UIKit）

#include <stdio.h>
#include <Foundation/Foundation.h>

// ============================================================
// MARK: - 诊断日志（纯 C，fopen/fprintf/fclose，不依赖 NSLog）
// ============================================================

static void safeWriteLog(const char *format, ...) {
    @try {
        va_list args;
        va_start(args, format);
        char buf[2048];
        vsnprintf(buf, sizeof(buf), format, args);
        va_end(args);
        
        FILE *fp = fopen("/tmp/bypass.log", "a");
        if (fp) {
            fprintf(fp, "%s\n", buf);
            fclose(fp);
        }
    } @catch (NSException *exception) {
        // 静默忽略日志写入失败
    }
}

// ============================================================
// MARK: - +[load] UserDefaults 预置值
// ============================================================

@interface TrollRecorderBypassSafe : NSObject
@end

@implementation TrollRecorderBypassSafe

+ (void)load {
    @try {
        safeWriteLog("[SAFE] TrollRecorderBypassSafe +[load] called");
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
        
        // --- 标准 UserDefaults ---
        [defaults setBool:NO  forKey:@"_shouldPromptLicense"];
        [defaults setBool:NO  forKey:@"previousShouldPromptLicense"];
        [defaults setBool:NO  forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
        [defaults setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
        [defaults setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
        [defaults synchronize];
        
        // --- 共享 UserDefaults (App Group) ---
        if (shared) {
            [shared setBool:NO  forKey:@"_shouldPromptLicense"];
            [shared setBool:YES forKey:@"isLicensed"];
            [shared setBool:YES forKey:@"isPro"];
            [shared setBool:YES forKey:@"isPremium"];
            [shared setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
            [shared setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
            [shared synchronize];
        }
        
        safeWriteLog("[SAFE] UserDefaults preset values written successfully");
        
    } @catch (NSException *exception) {
        safeWriteLog("[SAFE] +[load] EXCEPTION: %s", [exception.reason UTF8String] ?: "(null)");
    }
}

@end

// ============================================================
// MARK: - DYLD Constructor（诊断入口）
// ============================================================

__attribute__((constructor))
static void bypass_safe_constructor(void) {
    @try {
        safeWriteLog("========================================");
        safeWriteLog("[SAFE] TrollRecorderBypassSafe dylib LOADED");
        safeWriteLog("[SAFE] Process: %s", [[[NSProcessInfo processInfo] processName] UTF8String] ?: "(null)");
        safeWriteLog("[SAFE] Bundle: %s", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "(null)");
        safeWriteLog("[SAFE] DYLD_INSERT_LIBRARIES loaded successfully");
        safeWriteLog("[SAFE] Mode: minimal diagnostic — no hooks, no swizzles");
        safeWriteLog("========================================");
    } @catch (NSException *exception) {
        // 即使 constructor 本身崩溃也尽量写一行
        FILE *fp = fopen("/tmp/bypass.log", "a");
        if (fp) {
            fprintf(fp, "[SAFE] constructor CRASHED: %s\n", [exception.reason UTF8String] ?: "(null)");
            fclose(fp);
        }
    }
}

// ============================================================
// 以下全部注释：hook / swizzle / NSURLProtocol / Keychain / PaymentManager
// 恢复绕过逻辑时逐步取消注释
// ============================================================

// ------------------------------------------------------------
// NSURLProtocol（已禁用）
// ------------------------------------------------------------
/*
@interface BypassURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
...
@end
@implementation BypassURLProtocol
...
@end
*/

// ------------------------------------------------------------
// NSURLSession Hook（已禁用）
// ------------------------------------------------------------
/*
static id (*original_NSURLSession_dataTask...)(...);
static id hooked_NSURLSession_dataTask...(...) { ... }
*/

// ------------------------------------------------------------
// Keychain Hook（已禁用）
// ------------------------------------------------------------
/*
static OSStatus (*original_SecItemCopyMatching)(...);
static OSStatus (*original_SecItemAdd)(...);
*/
// 注意：恢复 Keychain hook 时需要加回 #include <Security/Security.h> 和 clang -framework Security

// ------------------------------------------------------------
// PaymentManager / ApplicationStorage / CloudService / DeviceInfo / CheckUpdateManager（已禁用）
// ------------------------------------------------------------
/*
+ (void)patchPaymentManager { ... }
+ (void)patchApplicationStorage { ... }
+ (void)patchCloudService { ... }
+ (void)patchDeviceInfo { ... }
+ (void)patchCheckUpdateManager { ... }
*/

// ------------------------------------------------------------
// NSURLSession Hook / ASWebAuthenticationSession / FeatureFlagStore / blockLicensePrompts（已禁用）
// ------------------------------------------------------------
// 注意：恢复 ASWebAuthenticationSession 时需要加回 #include <UIKit/UIKit.h> 和 clang -framework UIKit
