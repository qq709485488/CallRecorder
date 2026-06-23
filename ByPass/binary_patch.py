#!/usr/bin/env python3
"""
binary_patch.py - ARM64 指令级静态二进制 Patch
方案1：直接修改 TRApp 主二进制，定位验证函数入口并替换为 MOV X0,#1; RET

策略：
1. 解析 Mach-O FAT/arm64 结构，扫描 __cstring 节定位关键字符串
2. 通过字符串交叉引用（xref）查找引用这些字符串的函数
3. 在函数入口处替换指令序列为 stub（返回 true/成功）
4. 使用 known ARM64 字节码，无需 capstone/keystone 依赖

目标函数：
- checkCodeSignature / _checkCodeSignature → 返回 true
- globalSetupApplication → 返回 void/true
- ExecuteReceipt → 返回 true
"""

import struct
import sys
import os
from collections import defaultdict

# ============================================================
# ARM64 字节码常量
# ============================================================

# MOV X0, #1 ; RET  — 返回 true (适用于返回 BOOL/int 的函数)
STUB_RETURN_TRUE = bytes([
    0x20, 0x00, 0x80, 0xD2,  # MOV X0, #1
    0xC0, 0x03, 0x5F, 0xD6,  # RET
])

# MOV W0, #1 ; RET  — 返回 YES (BOOL 用 W 寄存器)
STUB_RETURN_YES = bytes([
    0x20, 0x00, 0x80, 0x52,  # MOV W0, #1
    0xC0, 0x03, 0x5F, 0xD6,  # RET
])

# MOV X0, #0 ; RET  — 返回 nil/false
STUB_RETURN_FALSE = bytes([
    0x00, 0x00, 0x80, 0xD2,  # MOV X0, #0
    0xC0, 0x03, 0x5F, 0xD6,  # RET
])

# RET only — void 函数直接返回
STUB_RET_VOID = bytes([
    0xC0, 0x03, 0x5F, 0xD6,  # RET
])

# ============================================================
# 函数序言 pattern（用于搜索未导出函数）
# ============================================================

# 常见 ARM64 函数序言模式（编码后的 stp x29, x30, [sp, #-N]!）
# stp x29, x30, [sp, #-16]! = FD 7B BF A9
# stp x29, x30, [sp, #-32]! = FD 7B 01 A9  
# stp x29, x30, [sp, #-48]! = FD 7B 02 A9
# stp x29, x30, [sp, #-64]! = FD 7B 03 A9
# stp x29, x30, [sp, #-80]! = FD 7B 04 A9

PROLOGUE_PATTERNS = [
    bytes([0xFD, 0x7B, 0xBF, 0xA9]),  # stp x29, x30, [sp, #-16]!
    bytes([0xFD, 0x7B, 0x01, 0xA9]),  # stp x29, x30, [sp, #-32]!
    bytes([0xFD, 0x7B, 0x02, 0xA9]),  # stp x29, x30, [sp, #-48]!
    bytes([0xFD, 0x7B, 0x03, 0xA9]),  # stp x29, x30, [sp, #-64]!
    bytes([0xFD, 0x7B, 0x04, 0xA9]),  # stp x29, x30, [sp, #-80]!
]

# 备用序言：stp x28, x29, [sp, #-N]!
PROLOGUE_ALT = [
    bytes([0xFC, 0x6F, 0xBF, 0xA9]),
    bytes([0xFC, 0x6F, 0x01, 0xA9]),
    bytes([0xFC, 0x6F, 0x02, 0xA9]),
]

# ============================================================
# 要 patch 的目标函数名（在 __cstring 或符号表中搜索）
# ============================================================

TARGET_STRING_MARKERS = [
    # 代码签名验证
    "checkCodeSignature",
    "_checkCodeSignature",
    "verifyCodeSignature",
    "checkSignature",
    "verifySignature",
    "isCodeSignatureValid",
    "verifyAppIntegrity",
    "checkAppIntegrity",
    "isIntegrityCheckPassed",
    
    # 应用初始化/验证入口
    "globalSetupApplication",
    "_globalSetupApplication",
    "ExecuteReceipt",
    "_ExecuteReceipt",
    "verifyReceipt",
    "checkReceipt",
    "_checkReceipt",
    
    # 许可证验证
    "checkLicense",
    "verifyLicense",
    "validateLicense",
    "_checkLicense",
    "_verifyLicense",
    "_validateLicense",
    
    # 权限/entitlement
    "checkEntitlements",
    "verifyEntitlements",
    "_checkEntitlements",
    "_verifyEntitlements",
]

# 也搜索 NSSelectorFromString / sel_registerName 的参数
# 这些通常意味着 ObjC selector 字符串
OBJC_METHOD_PREFIX = [
    "checkCodeSignature",
    "verifyCodeSignature", 
    "checkSignature",
    "globalSetupApplication",
    "ExecuteReceipt",
    "verifyReceipt",
    "checkReceipt",
    "checkLicense",
    "verifyLicense",
]


# ============================================================
# Mach-O 解析
# ============================================================

class MachOParser:
    """解析 arm64 Mach-O 文件"""
    
    MH_MAGIC_64 = 0xFEEDFACF
    MH_CIGAM_64 = 0xCFFAEDFE
    
    LC_SEGMENT_64 = 0x19
    LC_SYMTAB = 0x02
    LC_DYSYMTAB = 0x0B
    LC_FUNCTION_STARTS = 0x26
    
    def __init__(self, data: bytes, base_offset: int = 0):
        self.data = data
        self.base_offset = base_offset  # FAT slice 偏移
        self._parse_header()
        self._parse_commands()
    
    def _parse_header(self):
        """解析 Mach-O header"""
        off = self.base_offset
        self.magic = struct.unpack_from('<I', self.data, off)[0]
        if self.magic not in (self.MH_MAGIC_64, self.MH_CIGAM_64):
            raise ValueError(f"Not arm64 Mach-O at offset 0x{off:X}: magic=0x{self.magic:08X}")
        
        endian = '<' if self.magic == self.MH_MAGIC_64 else '>'
        hdr = struct.unpack_from(f'{endian}IIIIIIII', self.data, off)
        self.cputype = hdr[1]
        self.cpusubtype = hdr[2]
        self.filetype = hdr[3]
        self.ncmds = hdr[4]
        self.sizeofcmds = hdr[5]
        self.flags = hdr[6]
        
        # 代码段起始 (header + load commands)
        self.code_start = off + 32 + self.sizeofcmds
    
    def _parse_commands(self):
        """解析所有 load commands"""
        self.segments = {}      # segname -> (vmaddr, vmsize, fileoff, filesize)
        self.sections = {}      # (segname, sectname) -> (addr, offset, size)
        self.symtab = None
        self.dysymtab = None
        self.function_starts = None
        self.segments_list = []
        
        off = self.base_offset + 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from('<II', self.data, off)
            
            if cmd == self.LC_SEGMENT_64:
                segname = self.data[off+8:off+24].rstrip(b'\x00').decode('ascii', errors='replace')
                vmaddr = struct.unpack_from('<Q', self.data, off+24)[0]
                vmsize = struct.unpack_from('<Q', self.data, off+32)[0]
                fileoff = struct.unpack_from('<Q', self.data, off+40)[0]
                filesize = struct.unpack_from('<Q', self.data, off+48)[0]
                nsects = struct.unpack_from('<I', self.data, off+64)[0]
                
                self.segments[segname] = (vmaddr, vmsize, fileoff, filesize)
                self.segments_list.append((segname, vmaddr, vmsize, fileoff, filesize))
                
                # 解析 sections
                sect_off = off + 72
                for _ in range(nsects):
                    s_name = self.data[sect_off:sect_off+16].rstrip(b'\x00').decode('ascii', errors='replace')
                    s_seg = self.data[sect_off+16:sect_off+32].rstrip(b'\x00').decode('ascii', errors='replace')
                    s_addr = struct.unpack_from('<Q', self.data, sect_off+32)[0]
                    s_size = struct.unpack_from('<Q', self.data, sect_off+48)[0]
                    s_offset = struct.unpack_from('<I', self.data, sect_off+48)[0]
                    
                    self.sections[(s_seg, s_name)] = (s_addr, s_offset, s_size)
                    sect_off += 80
            
            elif cmd == self.LC_SYMTAB:
                symoff = struct.unpack_from('<I', self.data, off+8)[0]
                nsyms = struct.unpack_from('<I', self.data, off+12)[0]
                stroff = struct.unpack_from('<I', self.data, off+16)[0]
                strsize = struct.unpack_from('<I', self.data, off+20)[0]
                self.symtab = (symoff, nsyms, stroff, strsize)
            
            elif cmd == self.LC_DYSYMTAB:
                self.dysymtab = off
            
            elif cmd == self.LC_FUNCTION_STARTS:
                dataoff = struct.unpack_from('<I', self.data, off+8)[0]
                datasize = struct.unpack_from('<I', self.data, off+12)[0]
                self.function_starts = (dataoff, datasize)
            
            off += cmdsize
    
    def vmaddr_to_fileoff(self, vmaddr: int) -> int:
        """虚拟地址 → 文件偏移"""
        for _, seg_vmaddr, seg_vmsize, seg_fileoff, seg_filesize in self.segments_list:
            if seg_vmaddr <= vmaddr < seg_vmaddr + seg_vmsize:
                return seg_fileoff + (vmaddr - seg_vmaddr)
        return -1
    
    def get_section_data(self, segname: str, sectname: str) -> bytes:
        """读取 section 数据"""
        key = (segname, sectname)
        if key not in self.sections:
            return b''
        _, offset, size = self.sections[key]
        if offset + size > len(self.data):
            return b''
        return self.data[offset:offset+size]
    
    def find_strings_in_cstring(self, targets: list) -> dict:
        """在 __TEXT,__cstring 节中搜索目标字符串，返回 {string: [file_offset, ...]}"""
        cstring_data = self.get_section_data('__TEXT', '__cstring')
        if not cstring_data:
            return {}
        
        results = defaultdict(list)
        _, sect_offset, _ = self.sections.get(('__TEXT', '__cstring'), (0, 0, 0))
        
        for target in targets:
            target_bytes = target.encode('utf-8')
            pos = 0
            while True:
                idx = cstring_data.find(target_bytes, pos)
                if idx == -1:
                    break
                file_offset = sect_offset + idx
                results[target].append(file_offset)
                pos = idx + 1
        
        return dict(results)
    
    def find_all_strings_referenced_from(self, addr_vm: int, search_range: int = 0x1000) -> list:
        """给定一个字符串的 VM 地址，搜索代码段中所有引用此地址的指令"""
        text = self.sections.get(('__TEXT', '__text'), None)
        if not text:
            return []
        
        text_addr, text_offset, text_size = text
        code_data = self.data[text_offset:text_offset+text_size]
        
        xrefs = []
        # ARM64 ADRP + ADD 模式引用字符串
        # ADRP: 0x90000000 | (immhi << 5) | Rd, imm:lo 在低 2 位中编码
        # ADD:  0x91000000 | (imm << 10) | Rn | Rd
        
        for i in range(0, len(code_data) - 7, 4):
            instr = struct.unpack_from('<I', code_data, i)[0]
            
            # ADRP: 检查是否是 ADRP Xd, #page
            if (instr & 0x9F000000) == 0x90000000:
                page = (instr & 0x60000000) >> 17 | (instr & 0xFFFFE0) << 9
                rd1 = instr & 0x1F
                
                # 看下一条指令是不是 ADD
                if i + 8 <= len(code_data):
                    next_instr = struct.unpack_from('<I', code_data, i+4)[0]
                    if (next_instr & 0xFF800000) == 0x91000000:
                        rd2 = next_instr & 0x1F
                        rn = (next_instr >> 5) & 0x1F
                        imm12 = (next_instr >> 10) & 0xFFF
                        
                        if rn == rd1:
                            computed_addr = (text_addr + i) & ~0xFFF
                            computed_addr += page
                            computed_addr += imm12
                            
                            if abs(computed_addr - addr_vm) < 0x1000:
                                xrefs.append((text_offset + i, computed_addr))
        
        return xrefs
    
    def scan_function_starts(self) -> list:
        """使用 LC_FUNCTION_STARTS 获取所有函数起始地址"""
        if not self.function_starts:
            return []
        
        dataoff, datasize = self.function_starts
        func_offsets = []
        
        off = dataoff
        end = off + datasize
        prev_addr = 0
        
        while off < end:
            val, off = self._read_uleb128(off)
            if val == 0:
                break
            prev_addr += val
            func_offsets.append(prev_addr)
        
        return func_offsets
    
    def _read_uleb128(self, offset: int) -> tuple:
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
    
    def find_functions_by_prologue(self) -> list:
        """通过序言 pattern 扫描所有函数入口"""
        text = self.sections.get(('__TEXT', '__text'), None)
        if not text:
            return []
        
        _, text_offset, text_size = text
        code_data = self.data[text_offset:text_offset+text_size]
        
        entries = []
        for pattern in PROLOGUE_PATTERNS + PROLOGUE_ALT:
            pos = 0
            while True:
                idx = code_data.find(pattern, pos)
                if idx == -1:
                    break
                entries.append(text_offset + idx)
                pos = idx + 4
        
        # 去重并排序
        return sorted(set(entries))
    
    def read_string_at_offset(self, fileoff: int) -> str:
        """在给定文件偏移处读取 C 字符串"""
        try:
            end = self.data.index(0, fileoff)
            return self.data[fileoff:end].decode('utf-8', errors='replace')
        except (ValueError, IndexError):
            return ''


class BinaryPatcher:
    """ARM64 二进制指令级 Patcher"""
    
    def __init__(self, filepath: str):
        self.filepath = filepath
        with open(filepath, 'rb') as f:
            self.data = bytearray(f.read())
        
        self.parsers = []  # [(parser, base_offset)]
        self._detect_and_parse()
    
    def _detect_and_parse(self):
        """检测 FAT/单架构并解析"""
        magic = struct.unpack_from('<I', self.data, 0)[0]
        
        if magic == 0xBEBAFECA:  # FAT
            self._parse_fat()
        elif magic in (0xFEEDFACF, 0xCFFAEDFE):
            self.parsers.append((MachOParser(self.data, 0), 0))
        else:
            # 可能是从头开始的 arm64
            try:
                p = MachOParser(self.data, 0)
                self.parsers.append((p, 0))
            except:
                raise ValueError(f"Unknown binary format: 0x{magic:08X}")
    
    def _parse_fat(self):
        """解析 FAT 二进制"""
        nfat = struct.unpack_from('>I', self.data, 4)[0]
        for i in range(nfat):
            off = 8 + i * 20
            cputype = struct.unpack_from('>I', self.data, off)[0]
            cpusubtype = struct.unpack_from('>I', self.data, off+4)[0]
            arch_offset = struct.unpack_from('>I', self.data, off+8)[0]
            arch_size = struct.unpack_from('>I', self.data, off+12)[0]
            
            # 只处理 arm64
            if cputype == 0x0100000C:
                slice_data = self.data[arch_offset:arch_offset+arch_size]
                p = MachOParser(slice_data, 0)
                self.parsers.append((p, arch_offset))
    
    def find_target_functions(self) -> list:
        """通过字符串交叉引用查找目标函数入口"""
        results = []
        
        for parser, base in self.parsers:
            # 1. 在 __cstring 中搜索目标字符串
            cstring_hits = parser.find_strings_in_cstring(TARGET_STRING_MARKERS + OBJC_METHOD_PREFIX)
            
            cstring_sect = parser.sections.get(('__TEXT', '__cstring'))
            if not cstring_sect:
                continue
            cstring_addr, cstring_offset, _ = cstring_sect
            
            # 2. 对每个命中的字符串，找到引用它的位置
            for target_str, offsets in cstring_hits.items():
                for str_fileoff in offsets:
                    # 计算字符串在 VM 中的地址
                    str_vmaddr = cstring_addr + (str_fileoff - cstring_offset)
                    # 在代码段中搜索交叉引用
                    xrefs = parser.find_all_strings_referenced_from(str_vmaddr)
                    
                    for xref_code_off, _ in xrefs:
                        # 回溯找到包含此 xref 的函数入口
                        func_entry = self._find_function_entry(parser, xref_code_off)
                        if func_entry >= 0:
                            results.append({
                                'parser': parser,
                                'base': base,
                                'target_str': target_str,
                                'str_offset': str_fileoff,
                                'xref_offset': xref_code_off,
                                'func_entry': func_entry,
                            })
            
            # 3. 通过符号表搜索导出的目标函数
            if parser.symtab:
                sym_entries = self._find_exported_functions_by_symtab(parser)
                results.extend(sym_entries)
        
        return results
    
    def _find_function_entry(self, parser: MachOParser, code_offset: int) -> int:
        """找到包含给定代码偏移的函数入口（向前回溯搜索序言）"""
        # 确定代码所在的 segment
        text_sect = parser.sections.get(('__TEXT', '__text'))
        if not text_sect:
            return -1
        text_addr, text_offset, text_size = text_sect
        
        if code_offset < text_offset or code_offset >= text_offset + text_size:
            return -1
        
        # 从 code_offset 向前搜索最近的函数序言
        search_start = max(text_offset, code_offset - 4096)
        search_data = self.data[search_start:code_offset]
        
        best_entry = -1
        for pattern in PROLOGUE_PATTERNS + PROLOGUE_ALT:
            pos = len(search_data) - 4
            while pos >= 0:
                if search_data[pos:pos+4] == pattern:
                    actual_offset = search_start + pos
                    if actual_offset > best_entry:
                        best_entry = actual_offset
                    break  # 找到最近的
                pos -= 4
        
        return best_entry
    
    def _find_exported_functions_by_symtab(self, parser: MachOParser) -> list:
        """通过符号表查找导出函数"""
        results = []
        symoff, nsyms, stroff, strsize = parser.symtab
        
        entry_size = 16  # nlist_64
        want_names = set(TARGET_STRING_MARKERS)
        
        for i in range(nsyms):
            sym_offset = symoff + i * entry_size
            n_strx = struct.unpack_from('<I', self.data, sym_offset)[0]
            n_type = self.data[sym_offset + 4]
            
            # 只关心函数符号 (N_SECT 且 section 非 NO_SECT)
            if (n_type & 0x0E) != 0x0E:
                continue
            
            if n_strx == 0 or n_strx >= strsize:
                continue
            
            name_offset = stroff + n_strx
            try:
                end = self.data.index(0, name_offset)
                sym_name = self.data[name_offset:end].decode('utf-8', errors='replace')
            except:
                continue
            
            # 检查是否匹配目标名称
            if sym_name in want_names or sym_name.lstrip('_') in want_names:
                n_value = struct.unpack_from('<Q', self.data, sym_offset+8)[0]
                func_fileoff = parser.vmaddr_to_fileoff(n_value)
                if func_fileoff >= 0:
                    results.append({
                        'parser': parser,
                        'base': 0,
                        'target_str': sym_name,
                        'str_offset': 0,
                        'xref_offset': func_fileoff,
                        'func_entry': func_fileoff,
                        'from_symtab': True,
                    })
        
        return results
    
    def patch_functions(self, targets: list, dry_run: bool = False) -> dict:
        """对找到的函数入口应用 patch"""
        patched = {}
        applied = set()
        
        for t in targets:
            entry = t['func_entry']
            name = t['target_str']
            
            if entry in applied:
                continue
            
            # 读取现有指令
            if entry + 8 > len(self.data):
                continue
            
            existing = bytes(self.data[entry:entry+8])
            
            # 决定使用哪种 stub
            lower_name = name.lower()
            if 'setup' in lower_name or 'setup' in name:
                stub = STUB_RET_VOID  # setup 函数可能返回 void
            elif any(kw in lower_name for kw in ['verify', 'check', 'isvalid', 'islicensed', 'execute']):
                stub = STUB_RETURN_TRUE
            else:
                stub = STUB_RETURN_TRUE
            
            if dry_run:
                patched[hex(entry)] = {
                    'name': name,
                    'entry': hex(entry),
                    'existing_bytes': existing.hex(),
                    'stub': stub.hex(),
                }
            else:
                self.data[entry:entry+len(stub)] = stub
                patched[hex(entry)] = {
                    'name': name,
                    'entry': hex(entry),
                    'existing_bytes': existing.hex(),
                    'stub': stub.hex(),
                }
            
            applied.add(entry)
        
        return patched
    
    def patch_by_string_search(self, target_names: list, dry_run: bool = False) -> dict:
        """通过字符串引用定位并 patch 函数"""
        patched = {}
        
        for parser, base in self.parsers:
            cstring_hits = parser.find_strings_in_cstring(target_names)
            if not cstring_hits:
                continue
            
            cstring_sect = parser.sections.get(('__TEXT', '__cstring'))
            if not cstring_sect:
                continue
            cstring_addr, cstring_offset, _ = cstring_sect
            
            for target_str, offsets in cstring_hits.items():
                for str_fileoff in offsets:
                    str_vmaddr = cstring_addr + (str_fileoff - cstring_offset)
                    xrefs = parser.find_all_strings_referenced_from(str_vmaddr)
                    
                    for xref_code_off, _ in xrefs:
                        func_entry = self._find_function_entry(parser, xref_code_off)
                        if func_entry < 0:
                            continue
                        
                        key = base + func_entry
                        if key in patched:
                            continue
                        
                        stub = STUB_RETURN_TRUE
                        existing = bytes(self.data[base+func_entry:base+func_entry+8])
                        
                        if dry_run:
                            patched[key] = {
                                'name': target_str,
                                'entry': hex(base + func_entry),
                                'xref': hex(xref_code_off),
                                'existing_bytes': existing.hex(),
                                'stub': stub.hex(),
                            }
                        else:
                            actual_offset = base + func_entry
                            self.data[actual_offset:actual_offset+len(stub)] = stub
                            patched[key] = {
                                'name': target_str,
                                'entry': hex(actual_offset),
                                'xref': hex(xref_code_off),
                                'existing_bytes': existing.hex(),
                                'stub': stub.hex(),
                            }
        
        return patched
    
    def save(self, output_path: str):
        """保存 patch 后的二进制"""
        with open(output_path, 'wb') as f:
            f.write(self.data)
        print(f"\nSaved patched binary to: {output_path}")


# ============================================================
# Main
# ============================================================

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 binary_patch.py <binary_path> [--dry-run] [-o output_path]")
        print("")
        print("ARM64 instruction-level static binary patcher")
        print("Locates verification functions by string xref and patches")
        print("entry points to return true/success stubs.")
        sys.exit(1)
    
    binary_path = sys.argv[1]
    dry_run = '--dry-run' in sys.argv
    
    output_path = binary_path
    for i, arg in enumerate(sys.argv):
        if arg == '-o' and i + 1 < len(sys.argv):
            output_path = sys.argv[i + 1]
    
    print(f"=== ARM64 Binary Patcher (instruction-level) ===")
    print(f"Input:  {binary_path}")
    print(f"Output: {output_path}")
    print(f"Mode:   {'DRY RUN' if dry_run else 'PATCH'}")
    print()
    
    patcher = BinaryPatcher(binary_path)
    
    print(f"Detected {len(patcher.parsers)} arm64 slice(s)")
    for parser, base in patcher.parsers:
        text = parser.sections.get(('__TEXT', '__text'))
        if text:
            print(f"  Slice at 0x{base:X}: __text @ 0x{text[0]:X} (offset 0x{text[1]:X}, size {text[2]})")
    
    print()
    
    # Phase 1: 通过字符串交叉引用定位
    print("[Phase 1] Searching __cstring for verification function names...")
    string_hits = patcher.find_target_functions()
    print(f"  Found {len(string_hits)} candidate function entries")
    
    if string_hits:
        print()
        print("  Candidates:")
        for t in string_hits:
            from_sym = " (symtab)" if t.get('from_symtab') else ""
            print(f"    [{t['target_str']}] entry=0x{t['func_entry']:X}" + 
                  (f" xref=0x{t['xref_offset']:X}" if t.get('xref_offset') else "") + from_sym)
    
    # Phase 2: Patch
    print()
    print("[Phase 2] Applying patches...")
    results = patcher.patch_functions(string_hits, dry_run=dry_run)
    
    if not results and not dry_run:
        # Fallback: 尝试直接通过字符串引用 patch（另一种搜索方式）
        print("  No results from function search, trying direct string reference patching...")
        results = patcher.patch_by_string_search(TARGET_STRING_MARKERS + OBJC_METHOD_PREFIX, dry_run=dry_run)
    
    if results:
        print(f"\n  {'Would patch' if dry_run else 'Patched'} {len(results)} function(s):")
        for key, info in sorted(results.items()):
            print(f"    [{info['name']}] @ {info['entry']}")
            print(f"      original: {info['existing_bytes']} -> stub: {info['stub']}")
    else:
        print("\n  No patchable functions found.")
    
    if not dry_run:
        patcher.save(output_path)
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
