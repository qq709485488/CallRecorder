#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Security/Security.h>
#include <Foundation/Foundation.h>

// 原版 TrollRecorder 验证绕过 dylib
// 注入到 TRApp 和 TRCallMonitor 中，拦截许可证验证

// 保存原始函数指针
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);

// 前向声明
@interface TrollRecorderBypass : NSObject
+ (void)patchAll;
@end

// 伪造的许可证数据
static NSData *fakeLicenseData(void) {
    // 模拟一个有效的 Havoc 许可证响应
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

// 检查是否是许可证相关的 Keychain 查询
static BOOL isLicenseQuery(CFDictionaryRef query) {
    NSDictionary *q = (__bridge NSDictionary *)query;
    NSString *service = q[(__bridge NSString *)kSecAttrService];
    NSString *account = q[(__bridge NSString *)kSecAttrAccount];
    NSString *group = q[(__bridge NSString *)kSecAttrAccessGroup];
    
    // 检查是否是 TrollRecorder 的 Keychain 条目
    if (service && ([service containsString:@"trollrecorder"] || 
                     [service containsString:@"wiki.qaq.trapp"] ||
                     [service containsString:@"havoc"])) {
        return YES;
    }
    if (account && ([account containsString:@"trollrecorder"] || 
                     [account containsString:@"license"] ||
                     [account containsString:@"havoc"])) {
        return YES;
    }
    if (group && [group containsString:@"wiki.qaq.trapp"]) {
        return YES;
    }
    return NO;
}

// 钩子：SecItemCopyMatching
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (isLicenseQuery(query)) {
        // 返回伪造的许可证数据
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

// 钩子：SecItemAdd
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (isLicenseQuery(attributes)) {
        // 静默接受，假装写入成功
        return errSecSuccess;
    }
    return original_SecItemAdd(attributes, result);
}

// 利用 fishhook 原理手动 hook 函数
// 对于 Security framework，我们使用 dlsym 来获取原始函数
__attribute__((constructor))
static void init(void) {
    @autoreleasepool {
        NSLog(@"[TrollRecorderBypass] dylib loaded, hooking verification...");
        
        // 获取 Security framework 函数
        void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (security) {
            original_SecItemCopyMatching = dlsym(security, "SecItemCopyMatching");
            original_SecItemAdd = dlsym(security, "SecItemAdd");
            dlclose(security);
        }
        
        // 使用 fishhook 风格的 rebinding 来 hook C 函数
        // 这里使用一个简化的方法：直接通过 method swizzling 来处理
        
        // 延迟执行，确保所有类都已加载
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [TrollRecorderBypass patchAll];
        });
        
        NSLog(@"[TrollRecorderBypass] initialization complete");
    }
}

// 主要补丁逻辑
@implementation TrollRecorderBypass

+ (void)patchAll {
    NSLog(@"[TrollRecorderBypass] Applying patches...");
    
    // 1. Patch KeychainHelper (TRApp)
    [self patchKeychainHelperInApp];
    
    // 2. Patch TRKeychainHelper (TRCallMonitor)
    [self patchKeychainHelperInDaemon];
    
    // 3. Patch BSGFeatureFlagStore - 启用所有功能
    [self patchFeatureFlagStore];
    
    // 4. Patch license prompt
    [self patchLicensePrompt];
    
    // 5. Hook NSUserDefaults for license-related keys
    [self patchUserDefaults];
    
    NSLog(@"[TrollRecorderBypass] All patches applied successfully");
}

+ (void)patchKeychainHelperInApp {
    // TRApp 中的 KeychainHelper 是一个私有类
    // 类名: _TtC5TRAppP33_8F38294BAA415C91C37ADDA0FB9BAC4014KeychainHelper
    // 我们通过运行时查找并 swizzle
    
    Class helperClass = objc_getClass("_TtC5TRAppP33_8F38294BAA415C91C37ADDA0FB9BAC4014KeychainHelper");
    if (!helperClass) {
        // 尝试其他可能的类名
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            const char *name = class_getName(classes[i]);
            if (strstr(name, "KeychainHelper")) {
                helperClass = classes[i];
                NSLog(@"[TrollRecorderBypass] Found KeychainHelper class: %s", name);
                break;
            }
        }
        free(classes);
    }
    
    if (helperClass) {
        NSLog(@"[TrollRecorderBypass] Patching KeychainHelper in TRApp");
        [self swizzleKeychainHelper:helperClass];
    } else {
        NSLog(@"[TrollRecorderBypass] KeychainHelper class not found in TRApp");
    }
}

+ (void)patchKeychainHelperInDaemon {
    // TRCallMonitor 中的 TRKeychainHelper
    Class helperClass = NSClassFromString(@"TRKeychainHelper");
    if (helperClass) {
        NSLog(@"[TrollRecorderBypass] Patching TRKeychainHelper in TRCallMonitor");
        [self swizzleKeychainHelper:helperClass];
    } else {
        NSLog(@"[TrollRecorderBypass] TRKeychainHelper class not found");
    }
}

+ (void)swizzleKeychainHelper:(Class)helperClass {
    // 遍历所有方法，找到读取/写入许可证的方法
    unsigned int methodCount;
    Method *methods = class_copyMethodList(helperClass, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *methodName = NSStringFromSelector(selector);
        NSLog(@"[TrollRecorderBypass] KeychainHelper method: %@", methodName);
    }
    free(methods);
    
    // 尝试 hook 常见的读取方法
    [self swizzleMethod:@selector(loadLicense) inClass:helperClass withBlock:^id(id self) {
        NSLog(@"[TrollRecorderBypass] Intercepted loadLicense, returning fake license");
        return @{
            @"license_key": @"TROLLSTORE-FREE",
            @"is_active": @YES,
            @"plan": @"premium",
            @"expiry_date": @"2099-12-31T23:59:59Z"
        };
    }];
    
    [self swizzleMethod:@selector(readLicense) inClass:helperClass withBlock:^id(id self) {
        NSLog(@"[TrollRecorderBypass] Intercepted readLicense, returning fake license");
        return @{
            @"license_key": @"TROLLSTORE-FREE",
            @"is_active": @YES,
            @"plan": @"premium"
        };
    }];
    
    [self swizzleMethod:@selector(isLicensed) inClass:helperClass withBlock:^id(id self) {
        return @YES;
    }];
    
    [self swizzleMethod:@selector(hasValidLicense) inClass:helperClass withBlock:^id(id self) {
        return @YES;
    }];
}

+ (void)patchFeatureFlagStore {
    Class bsgsClass = NSClassFromString(@"BSGFeatureFlagStore");
    if (bsgsClass) {
        NSLog(@"[TrollRecorderBypass] Patching BSGFeatureFlagStore");
        // 让所有 feature flag 都返回 true
        [self swizzleMethod:@selector(isFeatureEnabled:) inClass:bsgsClass withBlock:^id(id self, NSString *name) {
            NSLog(@"[TrollRecorderBypass] Feature flag '%@' -> enabled", name);
            return @YES;
        }];
    }
}

+ (void)patchLicensePrompt {
    // Hook _shouldPromptLicense
    // 查找包含此方法的类
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        unsigned int methodCount;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *name = NSStringFromSelector(sel);
            if ([name containsString:@"shouldPromptLicense"] || 
                [name containsString:@"presentHintPurchaseIntro"] ||
                [name containsString:@"purchaseRequired"]) {
                NSLog(@"[TrollRecorderBypass] Found license prompt method: %@ in class: %s", name, class_getName(cls));
                // 替换为返回 NO
                [self swizzleMethod:sel inClass:cls withBlock:^id(id self) {
                    return @NO;
                }];
            }
        }
        free(methods);
    }
    free(classes);
}

+ (void)patchUserDefaults {
    // 设置许可证相关 UserDefaults 键
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:NO forKey:@"_shouldPromptLicense"];
    [defaults setBool:NO forKey:@"previousShouldPromptLicense"];
    [defaults setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
    [defaults setBool:NO forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
    [defaults setObject:@"TROLLSTORE-FREE" forKey:@"purchaseRequiredToken"];
    [defaults synchronize];
    
    // 也设置共享的 UserDefaults
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
    [shared setBool:NO forKey:@"_shouldPromptLicense"];
    [shared setBool:YES forKey:@"isLicensed"];
    [shared synchronize];
    
    NSLog(@"[TrollRecorderBypass] UserDefaults patched");
}

// 通用 Method Swizzling 辅助方法
+ (void)swizzleMethod:(SEL)selector inClass:(Class)cls withBlock:(id)block {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        // 方法不存在，尝试添加
        IMP blockImp = imp_implementationWithBlock(block);
        const char *typeEncoding = "@@:";
        // 尝试获取正确的方法签名
        if (selector == @selector(isFeatureEnabled:)) {
            typeEncoding = "@@:@";
        }
        class_addMethod(cls, selector, blockImp, typeEncoding);
        return;
    }
    
    IMP blockImp = imp_implementationWithBlock(block);
    method_setImplementation(method, blockImp);
    NSLog(@"[TrollRecorderBypass] Swizzled %@ in %s", NSStringFromSelector(selector), class_getName(cls));
}

@end