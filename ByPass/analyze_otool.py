#!/usr/bin/env python3
"""
analyze_otool.py - 解析 otool -ov 输出，找到所有验证方法
输出格式: imp_addr|method_name|return_type|class_name
return_type: yes, no, nil, void
"""

import sys
import re

# 验证相关的方法名关键词
VERIFICATION_KEYWORDS = [
    # 签名验证
    'shouldSkipCodeSignatureVerification', 'checkCodeSignature', 'verifyCodeSignature',
    'checkEntitlements', 'verifyEntitlements', 'isValidSignature', 'verifySignature',
    'isSignatureValid', 'isCodeSignatureValid', 'checkSignature', 'verifyAppIntegrity',
    'checkAppIntegrity', 'isIntegrityCheckPassed',
    
    # 许可证
    'isLicensed', 'hasValidLicense', 'isValidApiKey', 'isValidLicense',
    'isLicenseKeyValid', 'checkLicense', 'verifyLicense', 'validateLicense',
    'checkLicenseStatus', 'hasActiveSubscription', 'isLicenseExpired',
    'isTrialValid', 'isTrialExpired', 'isActivated', 'isActivatedDevice',
    
    # 购买 / 高级功能
    'isPro', 'isPremium', 'isPaid', 'isFullVersion', 'isUnlocked',
    'isPurchaseValid', 'checkReceipt', 'verifyReceipt', 'isReceiptValid',
    'validateReceipt', 'purchaseRequiredToken', 'purchaseToken',
    
    # 功能开关
    'isFeatureEnabled', 'isFeatureAvailable', 'isModuleEnabled',
    
    # 验证要求
    'requireVerification', 'requireLinkDevice', 'isVerificationRequired',
    'needsVerification', 'needsAuthentication', 'shouldRequireLogin',
    'isUserAuthenticated', 'isDeviceRegistered',
    
    # 提示
    '_shouldPromptLicense', 'shouldPresentLicensePrompt', 'needsLicensePrompt',
    'shouldShowPurchaseUI', 'shouldCheckLicense', 'needsLicenseCheck',
    'shouldPresentLicense', 'shouldShowPurchase',
    
    # 状态
    'isBlocked', 'isSuspended', 'isRevoked', 'isRestricted',
    'shouldAllowAccess', 'canProceed', 'canAccess',
    
    # Token / Key
    'licenseToken', 'apiKey', 'userToken', 'authToken', 'licenseKey',
]

# 返回 NO 的方法关键词
RETURN_NO_KEYWORDS = [
    '_should', 'shouldPrompt', 'shouldShow', 'shouldCheck', 'shouldRequire',
    'require', 'need', 'isBlocked', 'isSuspended', 'isRevoked', 'isRestricted',
    'isExpired', 'isTrialExpired', 'isLicenseExpired', 'isVerificationRequired',
    'needsVerification', 'needsAuthentication', 'needsLicense', 'needsLicenseCheck',
    'needsLicensePrompt', 'shouldPresentLicense', 'shouldShowPurchase',
]

# 返回 nil 的方法关键词
RETURN_NIL_KEYWORDS = [
    'Token', 'token', 'apiKey', 'licenseKey',
]

# 返回 void 的方法关键词
RETURN_VOID_KEYWORDS = [
    # 通常没有 void 返回的验证方法
]


def is_verification_method(method_name):
    """检查方法名是否与验证相关"""
    lower = method_name.lower()
    for keyword in VERIFICATION_KEYWORDS:
        kw_lower = keyword.lower()
        # 精确匹配：方法名包含关键词，且关键词是完整单词/方法名片段
        # 避免 isPro 匹配 isProxy, isProperty 等
        idx = lower.find(kw_lower)
        if idx < 0:
            continue
        # 检查关键词前后是否是单词边界
        # 关键词前面是字符串开头或非字母字符
        # 关键词后面是字符串结尾、冒号或非字母字符
        before_ok = idx == 0 or not lower[idx-1].isalpha()
        after_pos = idx + len(kw_lower)
        after_ok = after_pos >= len(lower) or lower[after_pos] in ':' or not lower[after_pos].isalpha()
        if before_ok and after_ok:
            return True
    return False


def determine_return_type(method_name):
    """根据方法名推断返回类型"""
    lower = method_name.lower()
    
    # 返回 nil 的方法
    for kw in RETURN_NIL_KEYWORDS:
        if kw.lower() in lower:
            return 'nil'
    
    # 返回 NO 的方法
    for kw in RETURN_NO_KEYWORDS:
        if kw.lower() in lower:
            return 'no'
    
    # 默认返回 YES
    return 'yes'


def parse_otool_output(otool_text):
    """
    解析 otool -ov 输出
    
    otool -ov 输出格式:
    Contents of (__DATA,__objc_classlist) section
    ...
    类名 format:
    _OBJC_CLASS_$_ClassName
    或
    ClassName:
    
    方法列表格式:
    instance_methods:
        name    0x...
        types   0x...
        imp     0x...
    """
    results = []
    current_class = None
    current_method_name = None
    current_method_imp = None
    
    for line in otool_text.split('\n'):
        line = line.strip()
        
        # 检测类名
        # 格式1: _OBJC_CLASS_$_ClassName
        if '_OBJC_CLASS_$_' in line:
            parts = line.split('_OBJC_CLASS_$_')
            if len(parts) > 1:
                current_class = parts[-1].strip()
                if current_class.endswith(':'):
                    current_class = current_class[:-1]
        
        # 格式2: ClassName (superclass ...)
        # 当看到 "Contents of" 时，可能是一个新的类
        if line.startswith('Contents of') and 'objc_class' in line:
            pass
        
        # 格式3: 缩进对齐的类名（在 meta_class 或 class 之后）
        if line.startswith('_OBJC_METACLASS_$_'):
            pass
        
        # 检测方法名
        if line.startswith('name') and '0x' in line:
            # 提取方法名（在下一行或同一行）
            # 格式: name    0x... MethodName
            match = re.search(r'name\s+0x[0-9a-fA-F]+\s+(.+)', line)
            if match:
                current_method_name = match.group(1).strip()
            else:
                current_method_name = None
        
        # 检测 IMP 地址
        if line.startswith('imp') and '0x' in line:
            match = re.search(r'imp\s+(0x[0-9a-fA-F]+)', line)
            if match:
                current_method_imp = match.group(1)
                
                # 如果当前方法名有效，且是验证方法，记录
                if current_method_name and current_method_imp:
                    if is_verification_method(current_method_name):
                        return_type = determine_return_type(current_method_name)
                        results.append({
                            'class': current_class or 'Unknown',
                            'method': current_method_name,
                            'imp': current_method_imp,
                            'return_type': return_type,
                        })
                
                current_method_name = None
    
    return results


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 analyze_otool.py <otool_dump.txt> <binary_path> [output_patches.txt]")
        sys.exit(1)
    
    dump_file = sys.argv[1]
    binary_path = sys.argv[2]
    output_file = sys.argv[3] if len(sys.argv) > 3 else None
    
    with open(dump_file, 'r', encoding='utf-8', errors='ignore') as f:
        otool_text = f.read()
    
    # 检查是否有错误
    if 'Unknown file format' in otool_text or 'not an object file' in otool_text:
        print(f"ERROR: otool could not parse {binary_path}")
        print(otool_text[:500])
        sys.exit(1)
    
    results = parse_otool_output(otool_text)
    
    print(f"Found {len(results)} verification methods in {binary_path}:")
    
    lines = []
    for r in results:
        print(f"  [{r['class']}] {r['method']} -> IMP={r['imp']} (return={r['return_type']})")
        lines.append(f"{r['imp']}|{r['method']}|{r['return_type']}|{r['class']}")
    
    if output_file:
        with open(output_file, 'w') as f:
            f.write('\n'.join(lines))
        print(f"\nPatches written to: {output_file}")
    
    return len(results)


if __name__ == '__main__':
    main()
    sys.exit(0)