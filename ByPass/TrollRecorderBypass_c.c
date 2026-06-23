// ============================================================
// TrollRecorderBypass_c.c - Pure C dylib with fishhook high-priority hooks
// 策略：使用 fishhook 在 C 层做符号重绑定，constructor(101) 高优先级加载
// 拦截：Keychain、设备信息、越狱检测、环境变量、ObjC 类查询
// ============================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#import <Foundation/Foundation.h>

#include "fishhook.h"

// ============================================================
// MARK: - 诊断日志 (写入 /tmp/bypass_c.log)
// ============================================================

static FILE *log_fp = NULL;

static void c_log(const char *fmt, ...) {
    if (!log_fp) {
        log_fp = fopen("/tmp/bypass_c.log", "a");
        if (!log_fp) return;
    }
    va_list args;
    va_start(args, fmt);
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    fprintf(log_fp, "[%02d:%02d:%02d] ", tm->tm_hour, tm->tm_min, tm->tm_sec);
    vfprintf(log_fp, fmt, args);
    fprintf(log_fp, "\n");
    fflush(log_fp);
    va_end(args);
}

// ============================================================
// MARK: - Original function pointers
// ============================================================

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static CFTypeRef (*orig_MGCopyAnswerWithError)(CFStringRef question, void *error);
static int (*orig_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static char *(*orig_getenv)(const char *name);
static Class (*orig_NSClassFromString)(NSString *name);
static Class (*orig_objc_getClass)(const char *name);

// ============================================================
// MARK: - Hook 1: SecItemCopyMatching (Keychain 读取拦截)
// ============================================================

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    // 读取请求中可能的 account / service 信息用于日志
    CFStringRef acct = query ? CFDictionaryGetValue(query, kSecAttrAccount) : NULL;
    CFStringRef svc  = query ? CFDictionaryGetValue(query, kSecAttrService) : NULL;
    CFStringRef cls  = query ? CFDictionaryGetValue(query, kSecClass) : NULL;

    char acct_buf[128] = {0}, svc_buf[128] = {0}, cls_buf[64] = {0};
    if (acct) CFStringGetCString(acct, acct_buf, sizeof(acct_buf), kCFStringEncodingUTF8);
    if (svc)  CFStringGetCString(svc,  svc_buf,  sizeof(svc_buf),  kCFStringEncodingUTF8);
    if (cls)  CFStringGetCString(cls,  cls_buf,  sizeof(cls_buf),  kCFStringEncodingUTF8);

    // 对已知的 license/verification 相关 keychain 项返回空
    if ((svc_buf[0] && (strstr(svc_buf, "license") ||
                        strstr(svc_buf, "License") ||
                        strstr(svc_buf, "purchase") ||
                        strstr(svc_buf, "Purchase") ||
                        strstr(svc_buf, "verification") ||
                        strstr(svc_buf, "activation") ||
                        strstr(svc_buf, "receipt") ||
                        strstr(svc_buf, "Receipt") ||
                        strstr(svc_buf, "signature") ||
                        strstr(svc_buf, "entitlement") ||
                        strstr(svc_buf, "Havoc") ||
                        strstr(svc_buf, "havoc") ||
                        strstr(svc_buf, "82flex") ||
                        strstr(svc_buf, "drm") ||
                        strstr(svc_buf, "DRM"))) ||
        (acct_buf[0] && (strstr(acct_buf, "license") ||
                         strstr(acct_buf, "License") ||
                         strstr(acct_buf, "activation")))) {
        
        c_log("SecItemCopyMatching BLOCKED: class=%s service=%s account=%s", cls_buf, svc_buf, acct_buf);
        
        // 返回 errSecItemNotFound (-25300)，让 app 认为 Keychain 中没有相关数据
        if (result) *result = NULL;
        return -25300; // errSecItemNotFound — invalid backwards compatibility
    }

    c_log("SecItemCopyMatching: class=%s service=%s account=%s -> PASS", cls_buf, svc_buf, acct_buf);
    return orig_SecItemCopyMatching(query, result);
}

// ============================================================
// MARK: - Hook 2: SecItemAdd (Keychain 写入拦截)
// ============================================================

static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFStringRef svc = attributes ? CFDictionaryGetValue(attributes, kSecAttrService) : NULL;
    CFStringRef acct = attributes ? CFDictionaryGetValue(attributes, kSecAttrAccount) : NULL;

    char svc_buf[128] = {0}, acct_buf[128] = {0};
    if (svc)  CFStringGetCString(svc,  svc_buf,  sizeof(svc_buf),  kCFStringEncodingUTF8);
    if (acct) CFStringGetCString(acct, acct_buf, sizeof(acct_buf), kCFStringEncodingUTF8);

    // 阻止验证相关数据写入 Keychain
    if ((svc_buf[0] && (strstr(svc_buf, "license") ||
                        strstr(svc_buf, "License") ||
                        strstr(svc_buf, "purchase") ||
                        strstr(svc_buf, "verification") ||
                        strstr(svc_buf, "activation")))) {
        c_log("SecItemAdd BLOCKED: service=%s account=%s", svc_buf, acct_buf);
        // 返回成功但不真正写入
        if (result) *result = NULL;
        return 0; // errSecSuccess
    }

    c_log("SecItemAdd: service=%s account=%s -> PASS", svc_buf, acct_buf);
    return orig_SecItemAdd(attributes, result);
}

// ============================================================
// MARK: - Hook 3: MGCopyAnswerWithError (设备信息伪造)
// ============================================================

static CFTypeRef hooked_MGCopyAnswerWithError(CFStringRef question, void *error) {
    char q_buf[256] = {0};
    if (question) CFStringGetCString(question, q_buf, sizeof(q_buf), kCFStringEncodingUTF8);
    
    c_log("MGCopyAnswerWithError: question=%s", q_buf);

    // 伪造 Jailbreak 相关设备信息
    if (strstr(q_buf, "jailbreak") ||
        strstr(q_buf, "Jailbreak") ||
        strstr(q_buf, "JailBreak") ||
        strstr(q_buf, "jb")) {
        c_log("  -> FAKE: jailbreak=no");
        // 返回 kCFBooleanFalse 意味着没有越狱
        CFRetain(kCFBooleanFalse);
        return kCFBooleanFalse;
    }

    // 其他问题正常透传
    return orig_MGCopyAnswerWithError(question, error);
}

// ============================================================
// MARK: - Hook 4: sysctlbyname (越狱检测绕过)
// ============================================================

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                               void *newp, size_t newlen) {
    c_log("sysctlbyname: name=%s", name ? name : "(null)");

    // 绕过越狱检测相关 sysctl 查询
    if (name) {
        if (strstr(name, "security.mac")) {
            // 伪造：没有 MAC 策略模块加载
            c_log("  -> FAKE: security.mac=no policy");
            if (oldp && oldlenp && *oldlenp > 0) {
                memset(oldp, 0, *oldlenp);
            }
            return 0;
        }
        if (strstr(name, "kern.bootargs")) {
            // 伪造 boot-args（越狱设备通常有特殊 boot-args）
            const char *fake_bootargs = "";
            size_t len = strlen(fake_bootargs) + 1;
            if (oldp && oldlenp && *oldlenp >= len) {
                memcpy(oldp, fake_bootargs, len);
                *oldlenp = len;
            }
            c_log("  -> FAKE: kern.bootargs=empty");
            return 0;
        }
    }

    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ============================================================
// MARK: - Hook 5: getenv (环境变量伪造)
// ============================================================

static char *hooked_getenv(const char *name) {
    c_log("getenv: name=%s", name ? name : "(null)");

    // 伪造动态库注入检测环境变量
    if (name) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) {
            c_log("  -> FAKE: DYLD_INSERT_LIBRARIES=NULL");
            return NULL;
        }
        if (strcmp(name, "DYLD_FORCE_FLAT_NAMESPACE") == 0) {
            c_log("  -> FAKE: DYLD_FORCE_FLAT_NAMESPACE=NULL");
            return NULL;
        }
        if (strcmp(name, "DYLD_PRINT_TO_FILE") == 0) {
            c_log("  -> FAKE: DYLD_PRINT_TO_FILE=NULL");
            return NULL;
        }
    }

    return orig_getenv(name);
}

// ============================================================
// MARK: - Hook 6: NSClassFromString (Objective-C 类查询拦截)
// ============================================================

// 需要先声明 objc_getClass 的原始实现
static Class hooked_NSClassFromString(NSString *name) {
    if (name) {
        const char *cname = [name UTF8String];
        c_log("NSClassFromString: %s", cname ? cname : "(null)");
        
        // 对特定越狱检测类返回 nil（类不存在）
        if (cname && (strstr(cname, "Jailbreak") ||
                      strstr(cname, "jailbreak") ||
                      strstr(cname, "JBDetection") ||
                      strstr(cname, "AntiJailbreak"))) {
            c_log("  -> FAKE: class %s = nil", cname);
            return nil;
        }
    }
    return orig_NSClassFromString(name);
}

static Class hooked_objc_getClass(const char *name) {
    c_log("objc_getClass: %s", name ? name : "(null)");

    if (name && (strstr(name, "Jailbreak") ||
                 strstr(name, "jailbreak") ||
                 strstr(name, "JBDetection") ||
                 strstr(name, "AntiJailbreak"))) {
        c_log("  -> FAKE: class %s = nil", name);
        return nil;
    }

    return orig_objc_getClass(name);
}

// ============================================================
// MARK: - fishhook 符号重绑定表
// ============================================================

static struct rebinding rebindings[] = {
    {"SecItemCopyMatching",  (void *)hooked_SecItemCopyMatching,  (void **)&orig_SecItemCopyMatching},
    {"SecItemAdd",           (void *)hooked_SecItemAdd,           (void **)&orig_SecItemAdd},
    {"MGCopyAnswerWithError",(void *)hooked_MGCopyAnswerWithError,(void **)&orig_MGCopyAnswerWithError},
    {"sysctlbyname",         (void *)hooked_sysctlbyname,         (void **)&orig_sysctlbyname},
    {"getenv",               (void *)hooked_getenv,               (void **)&orig_getenv},
    {"NSClassFromString",    (void *)hooked_NSClassFromString,    (void **)&orig_NSClassFromString},
    {"objc_getClass",        (void *)hooked_objc_getClass,        (void **)&orig_objc_getClass},
};

// ============================================================
// MARK: - Constructor (优先级 101，高于普通 constructor)
// ============================================================

__attribute__((constructor(101)))
static void bypass_c_init(void) {
    c_log("=== TrollRecorderBypass_c dylib loaded (fishhook C-layer) ===");
    c_log("fishhook rebinding %zu symbols...", sizeof(rebindings) / sizeof(rebindings[0]));

    // 应用 fishhook 符号重绑定
    int ret = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    if (ret == 0) {
        c_log("fishhook rebind_symbols SUCCESS");
    } else {
        c_log("fishhook rebind_symbols FAILED: %d", ret);
    }

    c_log("=== bypass_c_init complete ===");
}

// ============================================================
// MARK: - Destructor
// ============================================================

__attribute__((destructor))
static void bypass_c_fini(void) {
    c_log("=== TrollRecorderBypass_c dylib unloaded ===");
    if (log_fp) {
        fclose(log_fp);
        log_fp = NULL;
    }
}
