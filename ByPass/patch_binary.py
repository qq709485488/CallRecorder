#!/usr/bin/env python3
"""
TrollRecorder Binary Patcher v2
安全版本：仅精确匹配验证方法，固定 arm64 class_ro_t 布局，正确处理相对偏移方法表。

修复 v1 崩溃根因：
1. class_ro_t 偏移猜了 5 个位置 → 固定 arm64 布局
2. 相对方法表 imp 坐标计算错误 → 基于 method_list 基地址计算 VM addr
3. 部分匹配误伤正常方法 → 只用精确匹配
"""

import struct
import sys
import os

# ============================================================
# ARM64 指令常量
# ============================================================
RETURN_YES = bytes([0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])  # MOV W0,#1; RET
RETURN_NO  = bytes([0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])  # MOV W0,#0; RET
RETURN_NIL = bytes([0x00, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6])  # MOV X0,#0; RET
RET_ONLY   = bytes([0xC0, 0x03, 0x5F, 0xD6])                           # RET

# ============================================================
# Arm64 class_ro_t 固定布局 (iOS 14+ arm64e)
# ============================================================
# flags (4) + instanceStart (4) + instanceSize (4) + reserved (4) = 16
# ivarLayout (8) = 24 → name (8) = 32 → baseMethodList (8)
CLASS_RO_NAME_OFFSET        = 24
CLASS_RO_BASE_METHODS_OFFSET = 32

# ============================================================
# 验证方法精确匹配表（不含通配符）
# ============================================================
PATCH_YES = {  # 返回 YES/TRUE 的方法
    'shouldSkipCodeSignatureVerification',
    'isLicensed', 'hasValidLicense',
    'isValidApiKey:', 'isFeatureEnabled:', 'isActivated',
    'isPro', 'isPremium', 'isTrialValid', 'isPurchaseValid',
    'isActivatedDevice', 'isLicenseKeyValid', 'hasActiveSubscription',
    'isFeatureAvailable:', 'isModuleEnabled:',
    'checkLicenseStatus', 'verifyLicense', 'validateLicense',
    'isUserAuthenticated', 'isDeviceRegistered',
    'shouldAllowAccess', 'canProceed', 'isUnlocked',
    'isFullVersion', 'isPaid',
    'checkCodeSignature', 'verifyCodeSignature',
    'checkEntitlements', 'verifyEntitlements',
    'isValidSignature', 'verifySignature', 'isSignatureValid',
    'isCodeSignatureValid', 'checkSignature',
    'verifyAppIntegrity', 'checkAppIntegrity', 'isIntegrityCheckPassed',
    'checkReceipt', 'verifyReceipt', 'isReceiptValid', 'validateReceipt',
    # v14 新增：活性检测
    'startAliveChecks', 'performAliveCheck', 'stopAliveChecks',
    'checkAliveStatus', 'isAliveCheckRunning', 'shouldRunAliveChecks',
    # v14 新增：Keychain 监控
    'setupKeychainLockObserver', 'teardownKeychainLockObserver',
    'handleKeychainLockEvent:', 'keychainLockDetected',
    'isKeychainMonitoringActive',
    # v14 新增：BSGFeatureFlagStore / 配置验证
    'isFeatureEnabledForKey:', 'boolForKey:', 'integerForKey:',
    'doubleForKey:', 'stringForKey:', 'isActivatedFlag',
    'checkActivationFlag',
    # v14 新增：服务器验证回调
    'handleVerificationSuccess:', 'handleVerificationFailure:',
    'didVerifyLicense:', 'licenseVerificationDidComplete:',
    # 通用安全
    'hasValidEntitlements', 'isEntitlementCheckPassed',
    'shouldBypassVerification', 'isBypassEnabled',
}

PATCH_NO = {  # 返回 NO/FALSE 的方法
    '_shouldPromptLicense', 'requireVerification',
    'requireLinkDevice', 'shouldPresentLicensePrompt',
    'needsLicensePrompt', 'shouldShowPurchaseUI',
    'needsVerification', 'isVerificationRequired',
    'shouldRequireLogin', 'needsAuthentication',
    'isRestricted', 'isTrialExpired', 'isLicenseExpired',
    'shouldCheckLicense', 'needsLicenseCheck',
    'isBlocked', 'isSuspended', 'isRevoked',
    # v14 新增
    'shouldDisplayLicenseExpiredAlert',
    'shouldShowActivationRequired',
    'isTrialRevoked', 'isDeviceBlocked',
    'shouldPerformRemoteCheck',
    'needsRemoteValidation',
}

PATCH_NIL = {  # 返回 nil/0 的方法
    'purchaseRequiredToken', 'licenseToken',
    'apiKey', 'userToken', 'authToken',
    'licenseKey', 'purchaseToken',
    'deviceToken', 'sessionToken',
    'activationCode', 'verificationCode',
}

PATCH_VOID = {  # void 返回的方法（什么都不做）
    'presentLicensePrompt', 'displayLicenseError:',
    'showPurchaseView', 'showActivationUI',
    'presentTrialExpiredAlert', 'showVerificationFailed',
    'handleLicenseExpired',
    'performRemoteActivation',
    'sendVerificationRequest',
    'reportViolation:', 'reportLicenseIssue:',
}


class SafeMachOPatcher:
    """安全的 Mach-O 二进制补丁工具（v2）"""

    # Mach-O 常量
    MH_MAGIC_64   = 0xFEEDFACF
    MH_CIGAM_64   = 0xCFFAEDFE
    FAT_MAGIC     = 0xBEBAFECA
    CPU_TYPE_ARM64 = 0x0100000C

    LC_SEGMENT_64 = 0x19
    LC_SYMTAB     = 0x02

    METHOD_LIST_FIXED    = 0x00000003  # 固定格式 entsize=24
    METHOD_LIST_RELATIVE = 0x80000003  # 相对偏移格式 entsize=12 (仅方法选择器相对)

    def __init__(self, data: bytes):
        self.data = bytearray(data)
        self.patches_applied = []

        magic = struct.unpack('<I', data[0:4])[0]
        self.slices = []  # (file_offset, cputype)

        if magic == self.FAT_MAGIC:
            nfat = struct.unpack('>I', data[4:8])[0]
            for i in range(nfat):
                cputype = struct.unpack('>I', data[8+i*20:12+i*20])[0]
                offset  = struct.unpack('>I', data[16+i*20:20+i*20])[0]
                self.slices.append((offset, cputype))
        elif magic in (self.MH_MAGIC_64, self.MH_CIGAM_64):
            self.slices.append((0, self.CPU_TYPE_ARM64))
        else:
            raise ValueError(f"Unknown Mach-O magic: {hex(magic)}")

    # ----- 地址转换 -----
    def _build_vm_map(self, base: int):
        """构建虚拟地址→文件偏移映射 + 收集 section 信息"""
        header = struct.unpack('<IIIIIIII', self.data[base:base+32])
        ncmds = header[4]
        pos = base + 32

        vm_map = []  # [(vm_start, vm_end, file_base)]
        sections = {}
        classlist_off, classlist_count = None, None
        methname_addr, methname_off, methname_size = None, None, None

        for _ in range(ncmds):
            if pos + 8 > len(self.data):
                break
            cmd, cmdsize = struct.unpack('<II', self.data[pos:pos+8])

            if cmd == self.LC_SEGMENT_64:
                segname = self.data[pos+8:pos+24].rstrip(b'\x00').decode('ascii', errors='replace')
                vmaddr  = struct.unpack('<Q', self.data[pos+24:pos+32])[0]
                vmsize  = struct.unpack('<Q', self.data[pos+32:pos+40])[0]
                fileoff = struct.unpack('<Q', self.data[pos+40:pos+48])[0]
                filesize= struct.unpack('<Q', self.data[pos+48:pos+56])[0]
                nsects  = struct.unpack('<I', self.data[pos+64:pos+68])[0]

                if filesize > 0:
                    vm_map.append((vmaddr, vmaddr + filesize, fileoff - vmaddr))

                # 子 section
                sp = pos + 72
                for _ in range(nsects):
                    if sp + 80 > len(self.data):
                        break
                    sn = self.data[sp:sp+16].rstrip(b'\x00').decode('ascii', errors='replace')
                    sg = self.data[sp+16:sp+32].rstrip(b'\x00').decode('ascii', errors='replace')
                    sa = struct.unpack('<Q', self.data[sp+32:sp+40])[0]
                    ss = struct.unpack('<Q', self.data[sp+40:sp+48])[0]
                    so = struct.unpack('<I', self.data[sp+48:sp+52])[0]
                    sections[(sg, sn)] = (sa, so, ss)

                    if sn == '__objc_classlist':
                        classlist_off = so
                        classlist_count = ss // 8
                    elif sn == '__objc_methname':
                        methname_addr = sa
                        methname_off  = so
                        methname_size = ss

                    sp += 80

            pos += cmdsize

        return vm_map, sections, classlist_off, classlist_count, methname_addr, methname_off, methname_size

    def _vm_to_file(self, vmaddr, vm_map):
        for vm_start, vm_end, delta in vm_map:
            if vm_start <= vmaddr < vm_end:
                return vmaddr + delta
        return None

    def _read64(self, off):
        if off + 8 > len(self.data):
            return 0
        return struct.unpack('<Q', self.data[off:off+8])[0]

    def _read_u32(self, off):
        if off + 4 > len(self.data):
            return 0
        return struct.unpack('<I', self.data[off:off+4])[0]

    def _read_i32(self, off):
        if off + 4 > len(self.data):
            return 0
        return struct.unpack('<i', self.data[off:off+4])[0]

    def _cstr_at(self, vmaddr, vm_map):
        fo = self._vm_to_file(vmaddr, vm_map)
        if fo is None or fo >= len(self.data):
            return None
        try:
            end = self.data.index(0, fo, min(fo + 512, len(self.data)))
            return self.data[fo:end].decode('utf-8', errors='replace')
        except ValueError:
            return None

    # ----- 方法枚举 -----
    def _enumerate_methods_in_class(self, class_addr, vm_map):
        """给定 class 地址，返回 [(imp_vmaddr, method_name)]"""
        # objc_class 结构 (arm64): isa(8) + superclass(8) + cache(8) + vtable(8) + data(8)
        class_fo = self._vm_to_file(class_addr, vm_map)
        if class_fo is None:
            return []

        data_vm = self._read64(class_fo + 32)  # class_ro_t *
        if data_vm == 0:
            return []

        ro_fo = self._vm_to_file(data_vm, vm_map)
        if ro_fo is None:
            return []

        # 只读固定偏移 CLASS_RO_BASE_METHODS_OFFSET (=32)
        methods_vm = self._read64(ro_fo + CLASS_RO_BASE_METHODS_OFFSET)
        if methods_vm == 0:
            return []

        ml_fo = self._vm_to_file(methods_vm, vm_map)
        if ml_fo is None:
            return []

        # method_list_t: flags(4) + count(4) + methods[]
        flags = self._read_u32(ml_fo)
        count = self._read_u32(ml_fo + 4)
        if count == 0 or count > 5000:
            return []

        is_relative  = bool(flags & 0x80000000)
        is_direct    = bool(flags & 0x40000000)
        entsize_fixed = flags & 0xFFFF
        methods = []

        if is_relative:
            # 相对偏移格式: selector(4) + types(4) + imp(4) = 12 bytes
            # 偏移基准分别为各自字段所在位置
            entsize = 12
            for j in range(count):
                mo = ml_fo + 8 + j * entsize
                if mo + 12 > len(self.data):
                    break
                sel_rel = self._read_i32(mo)
                imp_rel = self._read_i32(mo + 8)
                # selector 名字：ml_fo+8+j*12 + sel_rel → 字符串地址
                sel_addr = (mo) + sel_rel
                name = self._cstr_at(sel_addr, vm_map)
                # IMP: methods_vm+8+j*12+8 + imp_rel → VM 地址
                imp_vm = methods_vm + 8 + j * 12 + 8 + imp_rel
                if name:
                    methods.append((imp_vm, name))
        else:
            # 固定格式: name(8) + types(8) + imp(8) = 24 bytes
            for j in range(count):
                mo = ml_fo + 8 + j * 24
                if mo + 24 > len(self.data):
                    break
                name_vm = self._read64(mo)
                imp_vm  = self._read64(mo + 16)
                name = self._cstr_at(name_vm, vm_map)
                if name:
                    methods.append((imp_vm, name))

        return methods

    def _get_class_name(self, class_addr, vm_map):
        """获取 ObjC 类名"""
        class_fo = self._vm_to_file(class_addr, vm_map)
        if class_fo is None:
            return None
        data_vm = self._read64(class_fo + 32)
        if data_vm == 0:
            return None
        ro_fo = self._vm_to_file(data_vm, vm_map)
        if ro_fo is None:
            return None
        name_vm = self._read64(ro_fo + CLASS_RO_NAME_OFFSET)  # 固定偏移 24
        return self._cstr_at(name_vm, vm_map)

    # ----- 方法分类 -----
    def _classify_method(self, name):
        """判断方法名属于哪类 patch"""
        if name in PATCH_YES:
            return RETURN_YES
        if name in PATCH_NO:
            return RETURN_NO
        if name in PATCH_NIL:
            return RETURN_NIL
        if name in PATCH_VOID:
            return RET_ONLY
        return None

    # ----- 主流程 -----
    def find_targets(self):
        """返回 [(imp_fileoff, class_name, method_name, patch_bytes)]"""
        results = []

        for slice_off, cputype in self.slices:
            if cputype != self.CPU_TYPE_ARM64:
                continue

            vm_map, sections, classlist_off, classlist_count, *_ = self._build_vm_map(slice_off)

            if classlist_off is None:
                continue

            base = slice_off

            for i in range(min(classlist_count, 2000)):
                class_vm = self._read64(base + classlist_off + i * 8)
                if class_vm == 0:
                    continue

                class_name = self._get_class_name(class_vm, vm_map)
                if class_name is None:
                    continue

                methods = self._enumerate_methods_in_class(class_vm, vm_map)

                for imp_vm, method_name in methods:
                    patch = self._classify_method(method_name)
                    if patch is None:
                        continue
                    imp_fo = self._vm_to_file(imp_vm, vm_map)
                    if imp_fo is None:
                        continue
                    results.append((imp_fo, class_name, method_name, patch))

        return results

    def apply(self, dry_run=False):
        """应用所有补丁"""
        targets = self.find_targets()

        if dry_run:
            print(f"Found {len(targets)} target methods:")
            for imp_fo, cls, name, patch in sorted(targets):
                pdesc = {RETURN_YES: "YES", RETURN_NO: "NO", RETURN_NIL: "nil", RET_ONLY: "void"}[patch]
                print(f"  0x{imp_fo:08X}  [{cls}] {name}  -> {pdesc}")
            return len(targets)

        # 去重（同一个 imp_fo 可能被多个 class 方法表引用）
        seen = set()
        patched = 0
        for imp_fo, cls, name, patch in targets:
            if imp_fo in seen:
                continue
            seen.add(imp_fo)
            if imp_fo + len(patch) > len(self.data):
                print(f"  SKIP: 0x{imp_fo:08X} [{cls}] {name} (超出文件范围)")
                continue
            self.data[imp_fo:imp_fo + len(patch)] = patch
            self.patches_applied.append((imp_fo, cls, name, patch))
            patched += 1

        for imp_fo, cls, name, patch in self.patches_applied:
            pdesc = {RETURN_YES: "YES", RETURN_NO: "NO", RETURN_NIL: "nil", RET_ONLY: "void"}[patch]
            print(f"  PATCHED: 0x{imp_fo:08X} [{cls}] {name} -> {pdesc}")

        return patched

    def save(self, path):
        with open(path, 'wb') as f:
            f.write(bytes(self.data))


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 patch_binary.py <binary> [--dry-run] [-o out]")
        sys.exit(1)

    binary = sys.argv[1]
    dry_run = '--dry-run' in sys.argv
    out = binary
    for i, a in enumerate(sys.argv):
        if a == '-o' and i + 1 < len(sys.argv):
            out = sys.argv[i + 1]

    print(f"=== TrollRecorder Binary Patcher v2 ===")
    print(f"  Input : {binary}")
    print(f"  Output: {out}")

    with open(binary, 'rb') as f:
        data = f.read()

    patcher = SafeMachOPatcher(data)
    n = patcher.apply(dry_run=dry_run)

    if not dry_run:
        patcher.save(out)
        print(f"\n  Patched {n} methods, saved to {out}")
    else:
        print(f"\n  Total: {n} targets (dry-run)")

    return 0

if __name__ == '__main__':
    sys.exit(main())
