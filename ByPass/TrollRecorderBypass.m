#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <Foundation/Foundation.h>

// ============================================================
// TrollRecorder 验证绕过 dylib v4
// 极简版本：仅 UserDefaults 预设 + 方法替换
// 不使用 DYLD_INTERPOSE（可能在某些 iOS 版本上不兼容）
// ============================================================

// ---- UserDefaults 预设 ----
static void patchUserDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!d) return;
    
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

// ---- 查找并替换 KeychainHelper 方法 ----
static void patchKeychainHelper(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (!strstr(name, "KeychainHelper")) continue;
        
        NSLog(@"[TrollRecorderBypass] Found KeychainHelper: %s", name);
        
        // 替换 isLicensed -> 返回 YES
        Method m1 = class_getInstanceMethod(classes[i], @selector(isLicensed));
        if (m1) {
            method_setImplementation(m1, imp_implementationWithBlock(^BOOL(id self) { return YES; }));
            NSLog(@"[TrollRecorderBypass]   -> isLicensed patched");
        }
        
        // 替换 hasValidLicense -> 返回 YES
        Method m2 = class_getInstanceMethod(classes[i], @selector(hasValidLicense));
        if (m2) {
            method_setImplementation(m2, imp_implementationWithBlock(^BOOL(id self) { return YES; }));
            NSLog(@"[TrollRecorderBypass]   -> hasValidLicense patched");
        }
        
        break; // 找到一个就够了
    }
    free(classes);
}

// ---- 查找并替换 FeatureFlagStore ----
static void patchFeatureFlagStore(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (!strstr(name, "FeatureFlag")) continue;
        
        Method m = class_getInstanceMethod(classes[i], @selector(isFeatureEnabled:));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self, id name) { return YES; }));
            NSLog(@"[TrollRecorderBypass] FeatureFlagStore patched: %s", name);
        }
        break;
    }
    free(classes);
}

// ---- 构造函数 ----
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSLog(@"[TrollRecorderBypass] v4 loaded");
        
        // 立即预设 UserDefaults
        patchUserDefaults();
        
        // 延迟执行方法替换（等所有类加载完毕）
        dispatch_async(dispatch_get_main_queue(), ^{
            patchKeychainHelper();
            patchFeatureFlagStore();
            NSLog(@"[TrollRecorderBypass] v4 patch complete");
        });
    }
}