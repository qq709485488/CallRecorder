// TrollRecorder v18 增强绕过 dylib
// 针对服务端验证（账号登录）、DRM 服务器、Havoc API 做全面拦截
// 版本：v17+ (enhanced for v18 account-based verification)

#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <Security/Security.h>
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

// ============================================================
// MARK: - 诊断日志系统
// ============================================================

static void writeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // 写入文件
    NSString *logPath = @"/tmp/bypass.log";
    NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                        dateStyle:NSDateFormatterNoStyle
                                                        timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, msg];
    
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [line writeToFile:logPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    
    NSLog(@"[TrollRecorderBypass] %@", msg);
}

// ============================================================
// MARK: - NSURLProtocol 拦截 DRM/Havoc API 响应
// ============================================================

@interface BypassURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation BypassURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host.lowercaseString;
    NSString *path = request.URL.path.lowercaseString;
    
    // 拦截所有 DRM 服务器和 Havoc API 请求
    if ([host containsString:@"drm.qaq.wiki"] ||
        [host containsString:@"drm.82flex.com"] ||
        [host containsString:@"drm-south.82flex.com"] ||
        ([host containsString:@"havoc.app"] && [path containsString:@"api"]) ||
        ([host containsString:@"havoc.app"] && [path containsString:@"sileo"])) {
        writeLog(@"NSURLProtocol: Intercepting request to %@%@", host, path);
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // 对 DRM 验证请求返回伪造的成功响应
    NSURL *url = self.request.URL;
    NSString *path = url.path.lowercaseString;
    
    // 构造伪造的验证成功响应
    NSDictionary *fakeResponse;
    NSInteger statusCode = 200;
    
    if ([url.host containsString:@"havoc.app"]) {
        // Havoc API 响应 — 模拟有效许可证
        fakeResponse = @{
            @"status": @"success",
            @"license": @{
                @"license_key": @"TROLLSTORE-BYPASS-V18",
                @"device_id": @"00000000-0000-0000-0000-000000000000",
                @"purchase_date": @"2024-01-01T00:00:00Z",
                @"expiry_date": @"2099-12-31T23:59:59Z",
                @"is_active": @YES,
                @"is_trial": @NO,
                @"plan": @"premium",
                @"features": @[
                    @"call_recording",
                    @"voice_memo",
                    @"system_audio",
                    @"auto_backup",
                    @"floating_hud",
                    @"icloud_sync",
                    @"transcription",
                    @"wechat_bridge"
                ]
            }
        };
    } else {
        // DRM 服务器响应 — 账号验证成功
        fakeResponse = @{
            @"code": @0,
            @"message": @"success",
            @"data": @{
                @"verified": @YES,
                @"license_type": @"premium",
                @"expires_at": @"2099-12-31T23:59:59Z",
                @"features": @[
                    @"call_recording",
                    @"voice_memo", 
                    @"system_audio",
                    @"auto_backup",
                    @"floating_hud"
                ],
                @"user_info": @{
                    @"email": @"bypass@trollstore.local",
                    @"username": @"TrollStore User",
                    @"is_pro": @YES,
                    @"subscription_active": @YES
                },
                @"token": @"bypass-token-v18-00000000",
                @"refresh_token": @"bypass-refresh-v18-00000000"
            }
        };
    }
    
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:fakeResponse
                                                           options:0
                                                             error:nil];
    
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:statusCode
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
        @"Content-Type": @"application/json",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)responseData.length],
        @"Cache-Control": @"no-cache"
    }];
    
    writeLog(@"NSURLProtocol: Returning fake response for %@ (status=%ld)", path, (long)statusCode);
    
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:responseData];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    [self.task cancel];
}

@end

// ============================================================
// MARK: - NSURLSession Hook — 备用拦截层
// ============================================================

static id (*original_NSURLSession_dataTaskWithRequest_completionHandler)(id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *));

static BOOL shouldInterceptURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return ([host containsString:@"drm.qaq.wiki"] ||
            [host containsString:@"drm.82flex.com"] ||
            [host containsString:@"drm-south.82flex.com"] ||
            [host containsString:@"havoc.app"]);
}

static id hooked_NSURLSession_dataTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    if (shouldInterceptURL(request.URL)) {
        writeLog(@"URLSession Hook: Intercepting %@", request.URL.absoluteString);
        
        // 包装 completionHandler，注入伪造响应
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            // 不调用原始回调，而是返回伪造的成功响应
            NSDictionary *fakeResponse = @{
                @"code": @0,
                @"message": @"success",
                @"data": @{
                    @"verified": @YES,
                    @"license_type": @"premium",
                    @"expires_at": @"2099-12-31T23:59:59Z",
                    @"token": @"bypass-token-v18-session",
                    @"user_info": @{
                        @"is_pro": @YES,
                        @"subscription_active": @YES
                    }
                }
            };
            NSData *fakeData = [NSJSONSerialization dataWithJSONObject:fakeResponse options:0 error:nil];
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{@"Content-Type": @"application/json"}];
            writeLog(@"URLSession Hook: Returning fake response for %@", request.URL.path);
            completionHandler(fakeData, fakeResp, nil);
        };
        
        return original_NSURLSession_dataTaskWithRequest_completionHandler(self, _cmd, request, wrappedHandler);
    }
    return original_NSURLSession_dataTaskWithRequest_completionHandler(self, _cmd, request, completionHandler);
}

// ============================================================
// MARK: - Keychain Hook（保留 v16 逻辑）
// ============================================================

static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);

static NSData *fakeLicenseData(void) {
    NSDictionary *license = @{
        @"license_key": @"TROLLSTORE-BYPASS-V18",
        @"device_id": @"00000000-0000-0000-0000-000000000000",
        @"purchase_date": @"2024-01-01T00:00:00Z",
        @"expiry_date": @"2099-12-31T23:59:59Z",
        @"is_trial": @NO,
        @"is_active": @YES,
        @"plan": @"premium",
        @"features": @[@"call_recording", @"voice_memo", @"system_audio", @"auto_backup", @"floating_hud", @"transcription", @"icloud_sync"]
    };
    return [NSPropertyListSerialization dataWithPropertyList:license format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

static BOOL isLicenseQuery(CFDictionaryRef query) {
    NSDictionary *q = (__bridge NSDictionary *)query;
    NSString *service = q[(__bridge NSString *)kSecAttrService];
    NSString *account = q[(__bridge NSString *)kSecAttrAccount];
    NSString *group = q[(__bridge NSString *)kSecAttrAccessGroup];
    
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

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (isLicenseQuery(query)) {
        if (result) {
            NSDictionary *fakeResult = @{
                (__bridge NSString *)kSecValueData: fakeLicenseData(),
                (__bridge NSString *)kSecAttrAccount: @"license",
                (__bridge NSString *)kSecAttrService: @"wiki.qaq.trapp",
                (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
            };
            *result = (__bridge_retained CFTypeRef)fakeResult;
        }
        writeLog(@"Keychain: Returning fake license data");
        return errSecSuccess;
    }
    return original_SecItemCopyMatching(query, result);
}

static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (isLicenseQuery(attributes)) {
        writeLog(@"Keychain: Silently accepting license write");
        return errSecSuccess;
    }
    return original_SecItemAdd(attributes, result);
}

// ============================================================
// MARK: - Method Swizzling 工具
// ============================================================

static void swizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method replMethod = class_getInstanceMethod(cls, replacement);
    if (origMethod && replMethod) {
        method_exchangeImplementations(origMethod, replMethod);
        writeLog(@"Swizzled: %@ -> %@ in %s", NSStringFromSelector(original), NSStringFromSelector(replacement), class_getName(cls));
    }
}

static void addMethodOverride(Class cls, SEL selector, id block, const char *types) {
    IMP imp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, selector, imp, types)) {
        Method method = class_getInstanceMethod(cls, selector);
        if (method) {
            method_setImplementation(method, imp);
        }
    }
}

// ============================================================
// MARK: - 核心绕过逻辑
// ============================================================

@interface TrollRecorderBypassV18 : NSObject
+ (void)applyAllPatches;
@end

@implementation TrollRecorderBypassV18

+ (void)applyAllPatches {
    writeLog(@"Applying v18 bypass patches...");
    
    // 1. 注册 NSURLProtocol 拦截 DRM/Havoc 请求
    [self registerURLProtocol];
    
    // 2. Hook NSURLSession
    [self hookURLSession];
    
    // 3. Patch KeychainHelper
    [self patchKeychainHelper];
    
    // 4. Patch PaymentManager
    [self patchPaymentManager];
    
    // 5. Patch ApplicationStorage（许可证状态存储）
    [self patchApplicationStorage];
    
    // 6. Patch CloudService（云端同步）
    [self patchCloudService];
    
    // 7. Patch DeviceInfo（设备 ID）
    [self patchDeviceInfo];
    
    // 8. Patch CheckUpdateManager
    [self patchCheckUpdateManager];
    
    // 9. Hook UserDefaults
    [self patchUserDefaults];
    
    // 10. Patch ASWebAuthenticationSession
    [self patchWebAuthSession];
    
    // 11. Patch FeatureFlagStore
    [self patchFeatureFlagStore];
    
    // 12. Block license prompts
    [self blockLicensePrompts];
    
    writeLog(@"All v18 patches applied successfully");
}

// ============================================================
// 1. NSURLProtocol 注册
// ============================================================
+ (void)registerURLProtocol {
    [NSURLProtocol registerClass:[BypassURLProtocol class]];
    writeLog(@"NSURLProtocol registered");
}

// ============================================================
// 2. NSURLSession Hook
// ============================================================
+ (void)hookURLSession {
    Class sessionClass = NSClassFromString(@"NSURLSession");
    if (sessionClass) {
        SEL sel = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
        Method method = class_getInstanceMethod(sessionClass, sel);
        if (method) {
            original_NSURLSession_dataTaskWithRequest_completionHandler = (void *)method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_NSURLSession_dataTaskWithRequest_completionHandler);
            writeLog(@"NSURLSession.dataTaskWithRequest:completionHandler: hooked");
        }
    }
}

// ============================================================
// 3. KeychainHelper Patch
// ============================================================
+ (void)patchKeychainHelper {
    // v18 类名
    Class keychainClass = objc_getClass("_TtC5TRAppP33_8F38294BAA415C91C37ADDA0FB9BAC4014KeychainHelper");
    
    if (!keychainClass) {
        // 降级：搜索所有包含 KeychainHelper 的类
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            const char *name = class_getName(classes[i]);
            if (strstr(name, "KeychainHelper")) {
                keychainClass = classes[i];
                break;
            }
        }
        free(classes);
    }
    
    if (keychainClass) {
        writeLog(@"Found KeychainHelper: %s", class_getName(keychainClass));
        
        // Hook isLicensed
        addMethodOverride(keychainClass, NSSelectorFromString(@"isLicensed"), ^BOOL(id self) {
            writeLog(@"KeychainHelper.isLicensed -> YES");
            return YES;
        }, "B@:");
        
        // Hook hasValidLicense
        addMethodOverride(keychainClass, NSSelectorFromString(@"hasValidLicense"), ^BOOL(id self) {
            writeLog(@"KeychainHelper.hasValidLicense -> YES");
            return YES;
        }, "B@:");
        
        // Hook readLicense / loadLicense
        SEL readSel = NSSelectorFromString(@"readLicense");
        SEL loadSel = NSSelectorFromString(@"loadLicense");
        
        id licenseBlock = ^NSDictionary *(id self) {
            writeLog(@"KeychainHelper.readLicense/loadLicense -> fake license");
            return @{
                @"license_key": @"TROLLSTORE-BYPASS-V18",
                @"is_active": @YES,
                @"is_trial": @NO,
                @"plan": @"premium",
                @"expiry_date": @"2099-12-31T23:59:59Z",
                @"device_id": @"00000000-0000-0000-0000-000000000000"
            };
        };
        
        if (class_getInstanceMethod(keychainClass, readSel)) {
            addMethodOverride(keychainClass, readSel, licenseBlock, "@@:");
        }
        if (class_getInstanceMethod(keychainClass, loadSel)) {
            addMethodOverride(keychainClass, loadSel, licenseBlock, "@@:");
        }
    } else {
        writeLog(@"KeychainHelper class not found");
    }
}

// ============================================================
// 4. PaymentManager Patch（v18 新增）
// ============================================================
+ (void)patchPaymentManager {
    Class pmClass = NSClassFromString(@"_TtC5TRApp14PaymentManager");
    if (pmClass) {
        writeLog(@"Found PaymentManager");
        
        // Hook isPurchased
        addMethodOverride(pmClass, NSSelectorFromString(@"isPurchased"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        // Hook purchaseStatus — 返回 "purchased" 字符串
        addMethodOverride(pmClass, NSSelectorFromString(@"purchaseStatus"), ^NSString *(id self) {
            return @"purchased";
        }, "@@:");
        
        // Hook verifyPurchase: — 立即返回成功
        addMethodOverride(pmClass, NSSelectorFromString(@"verifyPurchase:"), ^void(id self, void (^completion)(BOOL, NSError *)) {
            writeLog(@"PaymentManager.verifyPurchase -> success");
            if (completion) completion(YES, nil);
        }, "v@:@?");
        
        // Hook isSubscriptionActive
        addMethodOverride(pmClass, NSSelectorFromString(@"isSubscriptionActive"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        writeLog(@"PaymentManager patched");
    }
}

// ============================================================
// 5. ApplicationStorage Patch
// ============================================================
+ (void)patchApplicationStorage {
    Class storageClass = NSClassFromString(@"_TtC5TRApp18ApplicationStorage");
    if (storageClass) {
        writeLog(@"Found ApplicationStorage");
        
        // Hook license related properties
        addMethodOverride(storageClass, NSSelectorFromString(@"isLicensed"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        addMethodOverride(storageClass, NSSelectorFromString(@"isPro"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        addMethodOverride(storageClass, NSSelectorFromString(@"isPremium"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        addMethodOverride(storageClass, NSSelectorFromString(@"licenseStatus"), ^NSString *(id self) {
            return @"active";
        }, "@@:");
        
        writeLog(@"ApplicationStorage patched");
    }
}

// ============================================================
// 6. CloudService Patch（云端同步需要有效的许可证）
// ============================================================
+ (void)patchCloudService {
    Class cloudClass = NSClassFromString(@"_TtC5TRApp12CloudService");
    if (cloudClass) {
        writeLog(@"Found CloudService");
        
        addMethodOverride(cloudClass, NSSelectorFromString(@"isSubscriptionValid"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        addMethodOverride(cloudClass, NSSelectorFromString(@"canSync"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        writeLog(@"CloudService patched");
    }
}

// ============================================================
// 7. DeviceInfo Patch — 避免真实设备 ID 被上传
// ============================================================
+ (void)patchDeviceInfo {
    Class diClass = NSClassFromString(@"_TtC5TRApp10DeviceInfo");
    if (diClass) {
        writeLog(@"Found DeviceInfo");
        
        addMethodOverride(diClass, NSSelectorFromString(@"uniqueDeviceID"), ^NSString *(id self) {
            return @"00000000-0000-0000-0000-000000000000";
        }, "@@:");
        
        addMethodOverride(diClass, NSSelectorFromString(@"internalDeviceID"), ^NSString *(id self) {
            return @"00000000-0000-0000-0000-000000000000";
        }, "@@:");
        
        addMethodOverride(diClass, NSSelectorFromString(@"persistentDeviceID"), ^NSString *(id self) {
            return @"00000000-0000-0000-0000-000000000000";
        }, "@@:");
        
        writeLog(@"DeviceInfo patched");
    }
}

// ============================================================
// 8. CheckUpdateManager Patch
// ============================================================
+ (void)patchCheckUpdateManager {
    Class cumClass = NSClassFromString(@"_TtC5TRApp18CheckUpdateManager");
    if (cumClass) {
        writeLog(@"Found CheckUpdateManager");
        
        // 阻止更新检查中的许可证验证
        addMethodOverride(cumClass, NSSelectorFromString(@"validateEntitlement:"), ^BOOL(id self, id entitlement) {
            return YES;
        }, "B@:@");
        
        writeLog(@"CheckUpdateManager patched");
    }
}

// ============================================================
// 9. UserDefaults Patch
// ============================================================
+ (void)patchUserDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.wiki.qaq.trapp"];
    
    // 阻止许可证提示
    [defaults setBool:NO forKey:@"_shouldPromptLicense"];
    [defaults setBool:NO forKey:@"previousShouldPromptLicense"];
    [defaults setBool:NO forKey:@"ApplicationLicenseNeedsPromptOnNextLaunch"];
    [defaults setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
    [defaults setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
    
    // 设置许可证令牌
    [defaults setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"purchaseRequiredToken"];
    [defaults setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"ApplicationExportTokens"];
    [defaults setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"exportTokens"];
    [defaults setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"currentExportTokens"];
    [defaults setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"previousExportTokens"];
    
    // 提示类
    [defaults setBool:YES forKey:@"hintLoginIntro"];
    [defaults setBool:YES forKey:@"hintPurchaseIntro"];
    
    // 购买日期
    [defaults setObject:@"2024-01-01T00:00:00Z" forKey:@"purchaseDates"];
    
    // 神秘键值 (planck/planckh/plankv)
    [defaults setInteger:99999 forKey:@"planck"];
    [defaults setInteger:99999 forKey:@"planckh"];
    [defaults setInteger:99999 forKey:@"plankv"];
    
    [defaults synchronize];
    
    // 共享 UserDefaults
    [shared setBool:NO forKey:@"_shouldPromptLicense"];
    [shared setBool:YES forKey:@"isLicensed"];
    [shared setBool:YES forKey:@"isPro"];
    [shared setBool:YES forKey:@"isPremium"];
    [shared setBool:YES forKey:@"ApplicationDidPresentPurchaseIntro"];
    [shared setBool:YES forKey:@"ApplicationDidPresentLoginIntro"];
    [shared setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"purchaseRequiredToken"];
    [shared setObject:@"TROLLSTORE-BYPASS-V18" forKey:@"exportTokens"];
    [shared synchronize];
    
    writeLog(@"UserDefaults patched (standard + shared group)");
}

// ============================================================
// 10. ASWebAuthenticationSession Patch — 阻止网页登录
// ============================================================
+ (void)patchWebAuthSession {
    // PinSessionDelegate 管理购买/登录会话
    Class pinDelegate = objc_getClass("_TtC5TRAppP33_8F38294BAA415C91C37ADDA0FB9BAC4018PinSessionDelegate");
    if (pinDelegate) {
        writeLog(@"Found PinSessionDelegate");
        
        // 让 isSessionValid 永远返回 YES
        addMethodOverride(pinDelegate, NSSelectorFromString(@"isSessionValid"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        // validated 永远返回 YES
        addMethodOverride(pinDelegate, NSSelectorFromString(@"validated"), ^BOOL(id self) {
            return YES;
        }, "B@:");
        
        writeLog(@"PinSessionDelegate patched");
    }
    
    // 如果 app 直接使用 ASWebAuthenticationSession
    Class webAuthClass = NSClassFromString(@"ASWebAuthenticationSession");
    if (webAuthClass) {
        // Hook start 方法 — 直接调用 completionHandler 返回成功
        addMethodOverride(webAuthClass, NSSelectorFromString(@"start"), ^BOOL(id self) {
            writeLog(@"ASWebAuthenticationSession.start -> blocked, returning success");
            
            // 获取 callbackURLScheme
            NSString *scheme = nil;
            SEL schemeSel = NSSelectorFromString(@"callbackURLScheme");
            if ([self respondsToSelector:schemeSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                scheme = [self performSelector:schemeSel];
                #pragma clang diagnostic pop
            }
            
            if (scheme) {
                NSURL *fakeURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://auth/success?token=bypass-v18", scheme]];
                
                SEL handlerSel = NSSelectorFromString(@"completionHandler");
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                void (^handler)(NSURL *, NSError *) = [self performSelector:handlerSel];
                #pragma clang diagnostic pop
                
                if (handler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        handler(fakeURL, nil);
                    });
                }
            }
            return YES;
        }, "B@:");
        
        writeLog(@"ASWebAuthenticationSession patched");
    }
}

// ============================================================
// 11. FeatureFlagStore Patch
// ============================================================
+ (void)patchFeatureFlagStore {
    Class bsgsClass = NSClassFromString(@"BSGFeatureFlagStore");
    if (bsgsClass) {
        writeLog(@"Patching BSGFeatureFlagStore");
        
        addMethodOverride(bsgsClass, NSSelectorFromString(@"isFeatureEnabled:"), ^BOOL(id self, NSString *name) {
            writeLog(@"Feature flag '%@' -> enabled", name);
            return YES;
        }, "B@:@");
    }
}

// ============================================================
// 12. Block License Prompts
// ============================================================
+ (void)blockLicensePrompts {
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
                [name containsString:@"presentHintLoginIntro"] ||
                [name containsString:@"purchaseRequired"] ||
                [name containsString:@"requirePurchase"] ||
                [name containsString:@"showPurchasePage"] ||
                [name containsString:@"showLicensePrompt"]) {
                
                writeLog(@"Blocking license prompt: %@ in %s", name, class_getName(cls));
                
                // Block 返回 NO
                IMP block = imp_implementationWithBlock(^BOOL(id self) {
                    return NO;
                });
                
                Method method = methods[j];
                if (method) {
                    method_setImplementation(method, block);
                }
            }
            
            if ([name containsString:@"agreeToLicense"]) {
                IMP block = imp_implementationWithBlock(^void(id self) {
                    writeLog(@"agreeToLicense -> bypassed");
                });
                Method method = methods[j];
                if (method) {
                    method_setImplementation(method, block);
                }
            }
        }
        free(methods);
    }
    free(classes);
}

@end

// ============================================================
// MARK: - DYLD Constructor（诊断日志 + 初始化）
// ============================================================

__attribute__((constructor))
static void bypass_constructor(void) {
    @autoreleasepool {
        writeLog(@"========================================");
        writeLog(@"TrollRecorderBypass v18 dylib LOADED");
        writeLog(@"Process: %@", [[NSProcessInfo processInfo] processName]);
        writeLog(@"Bundle: %@", [[NSBundle mainBundle] bundleIdentifier]);
        writeLog(@"DYLD_INSERT_LIBRARIES loaded successfully");
        writeLog(@"========================================");
        
        // 获取 Security framework 函数
        void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (security) {
            original_SecItemCopyMatching = dlsym(security, "SecItemCopyMatching");
            original_SecItemAdd = dlsym(security, "SecItemAdd");
            dlclose(security);
            writeLog(@"Security framework hooks ready");
        }
        
        // 延迟执行 patch，确保所有类已加载
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [TrollRecorderBypassV18 applyAllPatches];
        });
        
        writeLog(@"Constructor complete — patches scheduled");
    }
}
