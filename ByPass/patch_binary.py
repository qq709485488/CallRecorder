#!/usr/bin/env python3
"""
TrollRecorder Binary Patcher
直接修改 Mach-O 二进制文件，移除所有验证逻辑。
策略：
1. 解析 Mach-O，找到 Objective-C 类结构
2. 定位所有验证相关的方法
3. 将方法实现替换为 "return YES/NO/nil" 的 stub
4. 同时处理 C 函数级别的验证
"""

import struct
import sys
import os
from typing import Optional, List, Tuple, Dict

# ============================================================
# ARM64 指令常量
# ============================================================
# MOV W0, #1 ; RET  (返回 BOOL YES)
RETURN_YES = bytes([0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])
# MOV W0, #0 ; RET  (返回 BOOL NO)
RETURN_NO = bytes([0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])
# MOV X0, #0 ; RET  (返回 nil/0)
RETURN_NIL = bytes([0x00, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6])
# RET only (void 函数)
RET_ONLY = bytes([0xC0, 0x03, 0x5F, 0xD6])

# ============================================================
# 验证相关的方法名（选择器）
# ============================================================
VERIFICATION_METHODS = {
    # 返回 YES 的方法
    'shouldSkipCodeSignatureVerification': RETURN_YES,
    'isLicensed': RETURN_YES,
    'hasValidLicense': RETURN_YES,
    'isValidApiKey:': RETURN_YES,
    'isFeatureEnabled:': RETURN_YES,
    'isActivated': RETURN_YES,
    'isPro': RETURN_YES,
    'isPremium': RETURN_YES,
    'isTrialValid': RETURN_YES,
    'isPurchaseValid': RETURN_YES,
    'isActivatedDevice': RETURN_YES,
    'isLicenseKeyValid': RETURN_YES,
    'hasActiveSubscription': RETURN_YES,
    'isFeatureAvailable:': RETURN_YES,
    'isModuleEnabled:': RETURN_YES,
    'checkLicenseStatus': RETURN_YES,
    'verifyLicense': RETURN_YES,
    'validateLicense': RETURN_YES,
    'isUserAuthenticated': RETURN_YES,
    'isDeviceRegistered': RETURN_YES,
    'shouldAllowAccess': RETURN_YES,
    'canProceed': RETURN_YES,
    'isUnlocked': RETURN_YES,
    'isFullVersion': RETURN_YES,
    'isPaid': RETURN_YES,
    'checkCodeSignature': RETURN_YES,
    'verifyCodeSignature': RETURN_YES,
    'checkEntitlements': RETURN_YES,
    'verifyEntitlements': RETURN_YES,
    'isValidSignature': RETURN_YES,
    'verifySignature': RETURN_YES,
    'isSignatureValid': RETURN_YES,
    'isCodeSignatureValid': RETURN_YES,
    'checkSignature': RETURN_YES,
    'verifyAppIntegrity': RETURN_YES,
    'checkAppIntegrity': RETURN_YES,
    'isIntegrityCheckPassed': RETURN_YES,
    'checkReceipt': RETURN_YES,
    'verifyReceipt': RETURN_YES,
    'isReceiptValid': RETURN_YES,
    'validateReceipt': RETURN_YES,
    
    # 返回 NO 的方法
    '_shouldPromptLicense': RETURN_NO,
    'requireVerification': RETURN_NO,
    'requireLinkDevice': RETURN_NO,
    'shouldPresentLicensePrompt': RETURN_NO,
    'needsLicensePrompt': RETURN_NO,
    'shouldShowPurchaseUI': RETURN_NO,
    'needsVerification': RETURN_NO,
    'isVerificationRequired': RETURN_NO,
    'shouldRequireLogin': RETURN_NO,
    'needsAuthentication': RETURN_NO,
    'isRestricted': RETURN_NO,
    'isTrialExpired': RETURN_NO,
    'isLicenseExpired': RETURN_NO,
    'shouldCheckLicense': RETURN_NO,
    'needsLicenseCheck': RETURN_NO,
    'isBlocked': RETURN_NO,
    'isSuspended': RETURN_NO,
    'isRevoked': RETURN_NO,
    
    # 返回 nil 的方法
    'purchaseRequiredToken': RETURN_NIL,
    'licenseToken': RETURN_NIL,
    'apiKey': RETURN_NIL,
    'userToken': RETURN_NIL,
    'authToken': RETURN_NIL,
    'licenseKey': RETURN_NIL,
    'purchaseToken': RETURN_NIL,
}

# 部分匹配的方法名（包含这些关键词的都要处理）
VERIFICATION_PARTIAL_MATCHES = [
    'license', 'verify', 'signature', 'purchase', 'entitlement',
    'receipt', 'codeSign', 'apiKey', 'isPro', 'isPremium',
    'isActivated', 'isPaid', 'isUnlocked', 'isTrial',
    'checkCode', 'checkSig', 'checkEntitle', 'checkReceipt',
    'checkLicense', 'checkIntegrity', 'checkPurchase',
    'validateSig', 'validateLicense', 'validateReceipt',
    'requireVerif', 'requireLink', 'requireAuth',
    'shouldPrompt', 'needsLicense', 'needsVerif',
    'shouldSkip', 'canAccess', 'shouldAllow',
    'hasValid', 'isValid', 'isLicensed',
    'isBlocked', 'isSuspended', 'isRevoked',
    'isRestricted', 'isExpired', 'isTrialExpired',
    'isFeatureEnabled', 'isFeatureAvailable',
    'isModuleEnabled', 'isSignatureValid',
    'isCodeSignatureValid', 'isIntegrityCheckPassed',
    'isReceiptValid', 'isLicenseKeyValid',
    'isUserAuthenticated', 'isDeviceRegistered',
    'hasActiveSubscription', 'isPurchaseValid',
    'checkLicenseStatus', 'verifyLicense', 'validateLicense',
    'checkCodeSignature', 'verifyCodeSignature',
    'checkEntitlements', 'verifyEntitlements',
    'isValidSignature', 'verifySignature',
    'verifyAppIntegrity', 'checkAppIntegrity',
    'checkReceipt', 'verifyReceipt',
    'isValidApiKey', 'isValidLicense',
    'isActivatedDevice', 'isFullVersion',
    'shouldPresentLicense', 'shouldRequireLogin',
    'shouldCheckLicense', 'shouldShowPurchase',
    'needsAuthentication', 'needsLicenseCheck',
    'purchaseRequiredToken', 'licenseToken',
    'apiKey', 'userToken', 'authToken', 'purchaseToken',
]


class MachOPatcher:
    """Mach-O 二进制补丁工具"""
    
    def __init__(self, data: bytes):
        self.data = bytearray(data)
        self.original_data = data
        self.patches: List[Tuple[int, bytes, str]] = []
        
        # 解析 Mach-O
        self.magic = struct.unpack('<I', data[0:4])[0]
        self.is_fat = False
        self.slices: List[Tuple[int, int, int]] = []  # (offset, cputype, cpusubtype)
        
        if self.magic == 0xBEBAFECA:  # FAT binary
            self.is_fat = True
            self._parse_fat()
        elif self.magic == 0xFEEDFACF:  # arm64
            self.slices = [(0, 0x0100000C, 0)]  # 单架构
        elif self.magic == 0xCFFAEDFE:  # arm64 big-endian
            self.slices = [(0, 0x0100000C, 0)]
        else:
            raise ValueError(f"Unknown magic: {hex(self.magic)}")
    
    def _parse_fat(self):
        """解析 FAT 二进制"""
        nfat = struct.unpack('>I', self.data[4:8])[0]
        for i in range(nfat):
            cputype, cpusubtype = struct.unpack('>II', self.data[8+i*20:16+i*20])
            offset, size, align = struct.unpack('>III', self.data[16+i*20:28+i*20])
            self.slices.append((offset, cputype, cpusubtype))
    
    def _read_uleb128(self, offset: int) -> Tuple[int, int]:
        """读取 ULEB128 编码"""
        result = 0
        shift = 0
        while offset < len(self.data):
            byte = self.data[offset]
            result |= (byte & 0x7F) << shift
            offset += 1
            if (byte & 0x80) == 0:
                break
            shift += 7
        return result, offset
    
    def _read_sleb128(self, offset: int) -> Tuple[int, int]:
        """读取 SLEB128 编码"""
        result = 0
        shift = 0
        while offset < len(self.data):
            byte = self.data[offset]
            result |= (byte & 0x7F) << shift
            offset += 1
            shift += 7
            if (byte & 0x80) == 0:
                if (byte & 0x40):
                    result |= -(1 << (shift - 1))
                break
        return result, offset
    
    def _get_slice_data(self, slice_offset: int) -> Tuple[bytes, int, int]:
        """获取单个架构的 Mach-O 数据"""
        # 读取 header
        magic = struct.unpack('<I', self.data[slice_offset:slice_offset+4])[0]
        if magic != 0xFEEDFACF:
            # big-endian
            magic = struct.unpack('>I', self.data[slice_offset:slice_offset+4])[0]
        
        return bytes(self.data[slice_offset:]), slice_offset, len(self.data) - slice_offset
    
    def _parse_macho(self, base: int) -> Dict:
        """解析 Mach-O 结构"""
        result = {
            'sections': {},  # (segname, sectname) -> (addr, offset, size)
            'segments': [],  # list of (name, vmaddr, vmsize, fileoff, filesize)
            'symtab': None,  # (symoff, nsyms, stroff, strsize)
            'dysymtab': None,
            'objc_classlist': None,  # (offset, count)
            'objc_catlist': None,
            'objc_protolist': None,
            'objc_selrefs': None,
            'objc_classrefs': None,
            'objc_superrefs': None,
            'objc_imageinfo': None,
            'objc_const': None,
            'objc_data': None,
            'objc_methname': None,
            'vm_to_file': {},  # vmaddr -> file_offset mapping
        }
        
        header = struct.unpack('<IIIIIIII', self.data[base:base+32])
        ncmds = header[4]
        sizeofcmds = header[5]
        offset = base + 32
        
        for i in range(ncmds):
            if offset + 8 > len(self.data):
                break
            cmd, cmdsize = struct.unpack('<II', self.data[offset:offset+8])
            
            if cmd == 0x19:  # LC_SEGMENT_64
                segname = self.data[offset+8:offset+24].rstrip(b'\x00').decode('utf-8', errors='ignore')
                vmaddr = struct.unpack('<Q', self.data[offset+24:offset+32])[0]
                vmsize = struct.unpack('<Q', self.data[offset+32:offset+40])[0]
                fileoff = struct.unpack('<Q', self.data[offset+40:offset+48])[0]
                filesize = struct.unpack('<Q', self.data[offset+48:offset+56])[0]
                nsects = struct.unpack('<I', self.data[offset+64:offset+68])[0]
                
                result['segments'].append((segname, vmaddr, vmsize, fileoff, filesize))
                
                # 解析 sections
                sect_off = offset + 72
                for j in range(nsects):
                    if sect_off + 80 > len(self.data):
                        break
                    sectname = self.data[sect_off:sect_off+16].rstrip(b'\x00').decode('utf-8', errors='ignore')
                    s_segname = self.data[sect_off+16:sect_off+32].rstrip(b'\x00').decode('utf-8', errors='ignore')
                    s_addr = struct.unpack('<Q', self.data[sect_off+32:sect_off+40])[0]
                    s_size = struct.unpack('<Q', self.data[sect_off+40:sect_off+48])[0]
                    s_offset = struct.unpack('<I', self.data[sect_off+48:sect_off+52])[0]
                    
                    key = (s_segname, sectname)
                    result['sections'][key] = (s_addr, s_offset, s_size)
                    
                    # 特殊 section
                    if sectname == '__objc_classlist':
                        result['objc_classlist'] = (s_offset, s_size // 8)
                    elif sectname == '__objc_catlist':
                        result['objc_catlist'] = (s_offset, s_size // 8)
                    elif sectname == '__objc_protolist':
                        result['objc_protolist'] = (s_offset, s_size // 8)
                    elif sectname == '__objc_selrefs':
                        result['objc_selrefs'] = (s_offset, s_size)
                    elif sectname == '__objc_classrefs':
                        result['objc_classrefs'] = (s_offset, s_size)
                    elif sectname == '__objc_superrefs':
                        result['objc_superrefs'] = (s_offset, s_size)
                    elif sectname == '__objc_imageinfo':
                        result['objc_imageinfo'] = (s_offset, s_size)
                    elif sectname == '__objc_const':
                        result['objc_const'] = (s_addr, s_offset, s_size)
                    elif sectname == '__objc_data':
                        result['objc_data'] = (s_addr, s_offset, s_size)
                    elif sectname == '__objc_methname':
                        result['objc_methname'] = (s_addr, s_offset, s_size)
                    
                    sect_off += 80
            
            elif cmd == 0x2:  # LC_SYMTAB
                symoff = struct.unpack('<I', self.data[offset+8:offset+12])[0]
                nsyms = struct.unpack('<I', self.data[offset+12:offset+16])[0]
                stroff = struct.unpack('<I', self.data[offset+16:offset+20])[0]
                strsize = struct.unpack('<I', self.data[offset+20:offset+24])[0]
                result['symtab'] = (symoff, nsyms, stroff, strsize)
            
            elif cmd == 0xB:  # LC_DYSYMTAB
                result['dysymtab'] = (offset, cmdsize)
            
            elif cmd == 0x2E:  # LC_FUNCTION_STARTS (iOS 10+)
                dataoff = struct.unpack('<I', self.data[offset+8:offset+12])[0]
                datasize = struct.unpack('<I', self.data[offset+12:offset+16])[0]
                result['function_starts'] = (dataoff, datasize)
            
            offset += cmdsize
        
        return result
    
    def _vmaddr_to_fileoff(self, vmaddr: int, info: Dict) -> Optional[int]:
        """将虚拟地址转换为文件偏移"""
        for segname, seg_vmaddr, seg_vmsize, seg_fileoff, seg_filesize in info['segments']:
            if seg_vmaddr <= vmaddr < seg_vmaddr + seg_vmsize:
                return seg_fileoff + (vmaddr - seg_vmaddr)
        return None
    
    def _read_ptr(self, offset: int) -> int:
        """读取 64 位指针"""
        if offset + 8 > len(self.data):
            return 0
        return struct.unpack('<Q', self.data[offset:offset+8])[0]
    
    def _read_ptr_at(self, offset: int) -> int:
        """读取 8 字节指针"""
        return struct.unpack('<Q', self.data[offset:offset+8])[0]
    
    def _get_string_at(self, addr: int, info: Dict) -> Optional[str]:
        """从虚拟地址读取字符串"""
        fileoff = self._vmaddr_to_fileoff(addr, info)
        if fileoff is None:
            return None
        try:
            end = self.data.index(0, fileoff)
            return self.data[fileoff:end].decode('utf-8', errors='ignore')
        except:
            return None
    
    def _find_methods_in_class_ro(self, ro_addr: int, info: Dict) -> List[Tuple[int, str, str]]:
        """在 class_ro_t 中查找方法列表，返回 [(imp_addr, method_name, type_encoding)]"""
        results = []
        ro_fileoff = self._vmaddr_to_fileoff(ro_addr, info)
        if ro_fileoff is None:
            return results
        
        # class_ro_t 结构:
        # flags: uint32_t
        # instanceStart: uint32_t
        # instanceSize: uint32_t
        # reserved: uint32_t (32-bit only, not in 64-bit)
        # ivarLayout: pointer (8 bytes)
        # name: pointer (8 bytes)
        # baseMethodList: pointer (8 bytes)  <-- 我们需要的
        # baseProtocols: pointer (8 bytes)
        # ivars: pointer (8 bytes)
        # weakIvarLayout: pointer (8 bytes)
        # baseProperties: pointer (8 bytes)
        
        # 在 arm64 上，class_ro_t 的布局是:
        # flags (4) + instanceStart (4) + instanceSize (4) + reserved (4) = 16 bytes
        # 然后是指针: ivarLayout (8) + name (8) + baseMethodList (8) = 24 bytes
        # 所以 baseMethodList 在偏移 16 + 8 + 8 = 32 处
        
        # 但不同的 Swift/ObjC 版本可能不同，让我们尝试多种偏移
        for ro_offset_try in [24, 28, 32, 36, 40]:
            method_list_ptr = self._read_ptr_at(ro_fileoff + ro_offset_try)
            if method_list_ptr == 0:
                continue
            
            method_list_fileoff = self._vmaddr_to_fileoff(method_list_ptr, info)
            if method_list_fileoff is None:
                continue
            
            # method_list_t 结构:
            # entsize_and_flags: uint32_t
            # count: uint32_t
            # methods: method_t[count]
            
            entsize_and_flags = struct.unpack('<I', self.data[method_list_fileoff:method_list_fileoff+4])[0]
            count = struct.unpack('<I', self.data[method_list_fileoff+4:method_list_fileoff+8])[0]
            
            # entsize 在低 16 位（对于相对偏移格式）或整个值（对于固定格式）
            # 对于 arm64，常见的是固定格式，entsize = 24
            entsize = entsize_and_flags & 0xFFFF
            
            if entsize == 0 or entsize > 256:
                # 可能是相对偏移格式
                if entsize_and_flags & 0xFFFF0000:
                    entsize = 12  # 相对偏移格式，每个方法 12 字节
                else:
                    continue
            
            if count > 10000:
                continue
            
            method_offset = method_list_fileoff + 8
            
            for j in range(min(count, 1000)):  # 限制最大 1000 个方法
                moff = method_offset + j * entsize
                if moff + entsize > len(self.data):
                    break
                
                if entsize == 24:
                    # 固定格式: name(8) + types(8) + imp(8)
                    name_ptr = self._read_ptr_at(moff)
                    types_ptr = self._read_ptr_at(moff + 8)
                    imp_ptr = self._read_ptr_at(moff + 16)
                elif entsize == 12:
                    # 相对偏移格式: name(4) + types(4) + imp(4)
                    name_rel = struct.unpack('<i', self.data[moff:moff+4])[0]
                    types_rel = struct.unpack('<i', self.data[moff+4:moff+8])[0]
                    imp_rel = struct.unpack('<i', self.data[moff+8:moff+12])[0]
                    name_ptr = moff + name_rel
                    types_ptr = moff + 4 + types_rel
                    imp_ptr = moff + 8 + imp_rel
                else:
                    continue
                
                # 读取方法名
                method_name = self._get_string_at(name_ptr, info)
                types_str = self._get_string_at(types_ptr, info) or ""
                
                if method_name:
                    results.append((imp_ptr, method_name, types_str))
            
            break  # 只处理第一个有效的方法列表
        
        return results
    
    def _get_class_name(self, class_addr: int, info: Dict) -> Optional[str]:
        """获取类名"""
        # objc_class 结构 (arm64):
        # isa: pointer (8)
        # superclass: pointer (8)
        # cache: pointer (8)
        # vtable: pointer (8)
        # data: pointer (8) -> class_ro_t
        
        class_fileoff = self._vmaddr_to_fileoff(class_addr, info)
        if class_fileoff is None:
            return None
        
        # data 在偏移 32 处 (4 * 8 = 32)
        data_ptr = self._read_ptr_at(class_fileoff + 32)
        if data_ptr == 0:
            return None
        
        ro_fileoff = self._vmaddr_to_fileoff(data_ptr, info)
        if ro_fileoff is None:
            return None
        
        # class_ro_t 中 name 在偏移 24 处 (flags(4)+instanceStart(4)+instanceSize(4)+reserved(4)+ivarLayout(8))
        # 但也可能是 32 处
        for name_offset in [24, 28, 32]:
            name_ptr = self._read_ptr_at(ro_fileoff + name_offset)
            if name_ptr > 0:
                name = self._get_string_at(name_ptr, info)
                if name and len(name) > 1 and len(name) < 256:
                    return name
        return None
    
    def find_verification_methods(self) -> List[Tuple[int, str, str, str, str]]:
        """
        查找所有验证相关的方法。
        返回: [(imp_fileoff, imp_vmaddr, class_name, method_name, type_encoding)]
        """
        results = []
        
        for slice_offset, cputype, cpusubtype in self.slices:
            if cputype != 0x0100000C:  # 只处理 arm64
                continue
            
            info = self._parse_macho(slice_offset)
            
            # 获取 __objc_classlist
            classlist = info.get('objc_classlist')
            if classlist is None:
                continue
            
            classlist_off, class_count = classlist
            base = slice_offset
            
            # 获取 __objc_methname section 用于直接扫描方法名
            methname_info = info.get('objc_methname')
            
            for i in range(class_count):
                class_addr = self._read_ptr_at(base + classlist_off + i * 8)
                if class_addr == 0:
                    continue
                
                class_name = self._get_class_name(class_addr, info)
                if class_name is None:
                    continue
                
                # 获取 class_ro_t
                class_fileoff = self._vmaddr_to_fileoff(class_addr, info)
                if class_fileoff is None:
                    continue
                
                data_ptr = self._read_ptr_at(class_fileoff + 32)
                if data_ptr == 0:
                    continue
                
                methods = self._find_methods_in_class_ro(data_ptr, info)
                
                for imp_vmaddr, method_name, type_encoding in methods:
                    # 检查是否是验证相关方法
                    is_verification = False
                    
                    # 精确匹配
                    if method_name in VERIFICATION_METHODS:
                        is_verification = True
                    else:
                        # 部分匹配
                        lower = method_name.lower()
                        for partial in VERIFICATION_PARTIAL_MATCHES:
                            if partial.lower() in lower:
                                is_verification = True
                                break
                    
                    if is_verification:
                        imp_fileoff = self._vmaddr_to_fileoff(imp_vmaddr, info)
                        if imp_fileoff is not None:
                            results.append((imp_fileoff, imp_vmaddr, class_name, method_name, type_encoding))
        
        return results
    
    def patch_method(self, imp_fileoff: int, method_name: str, type_encoding: str) -> bool:
        """
        在指定偏移处修补方法实现。
        根据方法名和类型编码决定返回什么值。
        """
        if imp_fileoff + 8 > len(self.data):
            return False
        
        # 确定使用哪个 stub
        patch_bytes = None
        
        if method_name in VERIFICATION_METHODS:
            patch_bytes = VERIFICATION_METHODS[method_name]
        else:
            # 根据返回类型推断
            # 检查类型编码的第一个字符
            if type_encoding:
                first_char = type_encoding[0] if type_encoding else ''
                if first_char in 'Bc':  # BOOL
                    lower = method_name.lower()
                    if any(kw in lower for kw in ['should', 'require', 'need', 'isblock', 'issuspend', 
                                                     'isrevo', 'isrestri', 'isexpir', 'istrialexp',
                                                     '_should', 'shouldprompt', 'shouldcheck',
                                                     'shouldshow', 'shouldrequire', 'needs', 'need']):
                        patch_bytes = RETURN_NO
                    else:
                        patch_bytes = RETURN_YES
                elif first_char in 'v':  # void
                    patch_bytes = RET_ONLY
                elif first_char in '@':  # id/object
                    patch_bytes = RETURN_NIL
                else:
                    patch_bytes = RETURN_YES  # 默认返回 YES
        
        if patch_bytes is None:
            patch_bytes = RETURN_YES
        
        # 保存原始字节用于日志
        original = bytes(self.data[imp_fileoff:imp_fileoff+len(patch_bytes)])
        
        # 应用补丁
        self.data[imp_fileoff:imp_fileoff+len(patch_bytes)] = patch_bytes
        self.patches.append((imp_fileoff, patch_bytes, method_name))
        
        return True
    
    def patch_all(self, dry_run: bool = False) -> int:
        """修补所有验证方法，返回修补数量"""
        methods = self.find_verification_methods()
        
        if dry_run:
            print(f"Found {len(methods)} verification methods:")
            for imp_fileoff, imp_vmaddr, class_name, method_name, type_encoding in sorted(methods):
                print(f"  0x{imp_fileoff:08X} (0x{imp_vmaddr:09X}) [{class_name}] {method_name} ({type_encoding})")
            return len(methods)
        
        patched = 0
        for imp_fileoff, imp_vmaddr, class_name, method_name, type_encoding in methods:
            if self.patch_method(imp_fileoff, method_name, type_encoding):
                print(f"  PATCHED: 0x{imp_fileoff:08X} [{class_name}] {method_name}")
                patched += 1
            else:
                print(f"  FAILED:  0x{imp_fileoff:08X} [{class_name}] {method_name}")
        
        return patched
    
    def save(self, output_path: str):
        """保存修补后的二进制文件"""
        with open(output_path, 'wb') as f:
            f.write(bytes(self.data))


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 patch_binary.py <binary_path> [--dry-run] [-o output_path]")
        sys.exit(1)
    
    binary_path = sys.argv[1]
    dry_run = '--dry-run' in sys.argv
    
    # 输出路径
    output_path = binary_path
    for i, arg in enumerate(sys.argv):
        if arg == '-o' and i + 1 < len(sys.argv):
            output_path = sys.argv[i+1]
    
    print(f"=== TrollRecorder Binary Patcher ===")
    print(f"Input: {binary_path}")
    print(f"Output: {output_path}")
    
    with open(binary_path, 'rb') as f:
        data = f.read()
    
    print(f"File size: {len(data)} bytes")
    
    patcher = MachOPatcher(data)
    
    if dry_run:
        count = patcher.patch_all(dry_run=True)
        print(f"\nTotal: {count} verification methods found")
    else:
        count = patcher.patch_all(dry_run=False)
        print(f"\nTotal: {count} methods patched")
        patcher.save(output_path)
        print(f"Saved to: {output_path}")
    
    return 0


if __name__ == '__main__':
    sys.exit(main())