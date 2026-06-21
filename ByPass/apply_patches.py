#!/usr/bin/env python3
"""
apply_patches.py - 将补丁应用到 Mach-O 二进制文件
读取补丁列表文件，找到每个 IMP 地址的文件偏移，覆写为 "return pass" 代码
"""

import struct
import sys
import os

# ARM64 指令
# MOV W0, #1 ; RET  (返回 YES)
RETURN_YES = bytes([0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])
# MOV W0, #0 ; RET  (返回 NO)
RETURN_NO = bytes([0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])
# MOV X0, #0 ; RET  (返回 nil)
RETURN_NIL = bytes([0x00, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6])
# RET only (void 函数)
RETURN_VOID = bytes([0xC0, 0x03, 0x5F, 0xD6])

PATCH_BYTES = {
    'yes': RETURN_YES,
    'no': RETURN_NO,
    'nil': RETURN_NIL,
    'void': RETURN_VOID,
}


def parse_macho_segments(data, base_offset=0):
    """解析 Mach-O 的 segment 和 section 信息"""
    segments = []
    sections = {}
    
    magic = struct.unpack('<I', data[base_offset:base_offset+4])[0]
    if magic == 0xBEBAFECA:  # FAT
        nfat = struct.unpack('>I', data[base_offset+4:base_offset+8])[0]
        for i in range(nfat):
            cputype = struct.unpack('>I', data[base_offset+8+i*20:base_offset+12+i*20])[0]
            arch_offset = struct.unpack('>I', data[base_offset+16+i*20:base_offset+20+i*20])[0]
            if cputype == 0x0100000C:  # arm64
                base_offset = arch_offset
                break
        magic = struct.unpack('<I', data[base_offset:base_offset+4])[0]
    
    if magic not in (0xFEEDFACF, 0xCFFAEDFE):
        raise ValueError(f"Not a valid Mach-O: magic=0x{magic:08X}")
    
    header = struct.unpack('<IIIIIIII', data[base_offset:base_offset+32])
    ncmds = header[4]
    offset = base_offset + 32
    
    for i in range(ncmds):
        if offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[offset:offset+8])
        
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[offset+8:offset+24].rstrip(b'\x00').decode('utf-8', errors='ignore')
            vmaddr = struct.unpack('<Q', data[offset+24:offset+32])[0]
            vmsize = struct.unpack('<Q', data[offset+32:offset+40])[0]
            fileoff = struct.unpack('<Q', data[offset+40:offset+48])[0]
            filesize = struct.unpack('<Q', data[offset+48:offset+56])[0]
            nsects = struct.unpack('<I', data[offset+64:offset+68])[0]
            
            segments.append({
                'name': segname,
                'vmaddr': vmaddr,
                'vmsize': vmsize,
                'fileoff': fileoff,
                'filesize': filesize,
            })
            
            # 解析 sections
            sect_off = offset + 72
            for j in range(nsects):
                if sect_off + 80 > len(data):
                    break
                sectname = data[sect_off:sect_off+16].rstrip(b'\x00').decode('utf-8', errors='ignore')
                s_segname = data[sect_off+16:sect_off+32].rstrip(b'\x00').decode('utf-8', errors='ignore')
                s_addr = struct.unpack('<Q', data[sect_off+32:sect_off+40])[0]
                s_size = struct.unpack('<Q', data[sect_off+40:sect_off+48])[0]
                s_offset = struct.unpack('<I', data[sect_off+48:sect_off+52])[0]
                sections[(s_segname, sectname)] = (s_addr, s_offset, s_size)
                sect_off += 80
        
        offset += cmdsize
    
    return segments, sections


def vmaddr_to_fileoff(vmaddr, segments):
    """将虚拟地址转换为文件偏移"""
    for seg in segments:
        if seg['vmaddr'] <= vmaddr < seg['vmaddr'] + seg['vmsize']:
            return seg['fileoff'] + (vmaddr - seg['vmaddr'])
    return None


def find_function_starts(data, base_offset, segments):
    """从 LC_FUNCTION_STARTS 获取所有函数起始地址"""
    # 解析 LC_FUNCTION_STARTS
    magic = struct.unpack('<I', data[base_offset:base_offset+4])[0]
    if magic == 0xBEBAFECA:
        nfat = struct.unpack('>I', data[base_offset+4:base_offset+8])[0]
        for i in range(nfat):
            cputype = struct.unpack('>I', data[base_offset+8+i*20:base_offset+12+i*20])[0]
            arch_offset = struct.unpack('>I', data[base_offset+16+i*20:base_offset+20+i*20])[0]
            if cputype == 0x0100000C:
                base_offset = arch_offset
                break
    
    header = struct.unpack('<IIIIIIII', data[base_offset:base_offset+32])
    ncmds = header[4]
    offset = base_offset + 32
    
    func_starts_data = None
    func_starts_offset = 0
    
    for i in range(ncmds):
        if offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[offset:offset+8])
        
        if cmd == 0x2E:  # LC_FUNCTION_STARTS
            dataoff = struct.unpack('<I', data[offset+8:offset+12])[0]
            datasize = struct.unpack('<I', data[offset+12:offset+16])[0]
            func_starts_data = data[dataoff:dataoff+datasize]
            func_starts_offset = dataoff
        
        offset += cmdsize
    
    if func_starts_data is None:
        return None
    
    # 解析 ULEB128 编码的函数起始地址
    funcs = []
    addr = 0
    pos = 0
    while pos < len(func_starts_data):
        result = 0
        shift = 0
        while pos < len(func_starts_data):
            byte = func_starts_data[pos]
            result |= (byte & 0x7F) << shift
            pos += 1
            if (byte & 0x80) == 0:
                break
            shift += 7
        addr += result
        funcs.append(addr)
    
    return funcs


def find_nearest_function(func_starts, target_addr):
    """找到最接近目标地址的函数起始地址"""
    if func_starts is None:
        return None
    
    best = None
    for addr in func_starts:
        if addr <= target_addr:
            best = addr
        else:
            break
    
    return best


def apply_patches(binary_path, patches_file, output_path):
    """应用补丁到二进制文件"""
    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())
    
    # 解析 Mach-O 结构
    segments, sections = parse_macho_segments(data)
    
    # 获取函数起始地址
    func_starts = find_function_starts(data, 0, segments)
    if func_starts:
        print(f"  Found {len(func_starts)} function start addresses")
    
    # 读取补丁列表
    with open(patches_file, 'r') as f:
        patches = [line.strip() for line in f if line.strip()]
    
    print(f"  Loaded {len(patches)} patches")
    
    patched_count = 0
    failed_count = 0
    
    for patch_line in patches:
        parts = patch_line.split('|')
        if len(parts) < 3:
            continue
        
        imp_addr_str = parts[0]
        method_name = parts[1]
        return_type = parts[2]
        class_name = parts[3] if len(parts) > 3 else 'Unknown'
        
        # 解析 IMP 地址
        imp_addr = int(imp_addr_str, 16)
        
        # 转换为文件偏移
        fileoff = vmaddr_to_fileoff(imp_addr, segments)
        if fileoff is None:
            print(f"  FAILED: Cannot find file offset for 0x{imp_addr:09X} [{class_name}] {method_name}")
            failed_count += 1
            continue
        
        # 如果函数起始地址可用，使用精确的函数起始地址
        if func_starts:
            nearest = find_nearest_function(func_starts, imp_addr)
            if nearest is not None and nearest != imp_addr:
                # 如果 nearest 距离 imp_addr 不超过 32 字节，使用 nearest
                # （otool 可能报告的是方法入口，但函数可能从稍早的地址开始）
                if imp_addr - nearest <= 32:
                    fileoff = vmaddr_to_fileoff(nearest, segments)
                    if fileoff is not None:
                        imp_addr = nearest
        
        # 选择补丁字节
        patch_bytes = PATCH_BYTES.get(return_type, RETURN_YES)
        
        if fileoff + len(patch_bytes) > len(data):
            print(f"  FAILED: File offset 0x{fileoff:X} out of bounds [{class_name}] {method_name}")
            failed_count += 1
            continue
        
        # 验证目标地址有合理的代码（不是全零）
        original = bytes(data[fileoff:fileoff+len(patch_bytes)])
        if original == b'\x00' * len(patch_bytes):
            print(f"  WARNING: Target is all zeros at 0x{fileoff:X} [{class_name}] {method_name}")
        
        # 应用补丁
        data[fileoff:fileoff+len(patch_bytes)] = patch_bytes
        print(f"  PATCHED: 0x{fileoff:08X} (0x{imp_addr:09X}) [{class_name}] {method_name} -> return {return_type}")
        patched_count += 1
    
    print(f"\n  Results: {patched_count} patched, {failed_count} failed")
    
    if patched_count > 0:
        with open(output_path, 'wb') as f:
            f.write(bytes(data))
        print(f"  Saved to: {output_path}")
        return True
    else:
        print(f"  No patches applied, not creating output file")
        return False


def main():
    if len(sys.argv) < 4:
        print("Usage: python3 apply_patches.py <binary> <patches.txt> <output>")
        sys.exit(1)
    
    binary_path = sys.argv[1]
    patches_file = sys.argv[2]
    output_path = sys.argv[3]
    
    print(f"=== Apply Patches ===")
    print(f"Binary: {binary_path}")
    print(f"Patches: {patches_file}")
    print(f"Output: {output_path}")
    
    if not os.path.exists(patches_file):
        print("ERROR: Patches file not found")
        sys.exit(1)
    
    success = apply_patches(binary_path, patches_file, output_path)
    
    if not success:
        # 即使没有补丁，也创建一个副本（确保输出文件存在）
        import shutil
        shutil.copy(binary_path, output_path)
        print("No patches needed, copied original")
    
    return 0


if __name__ == '__main__':
    sys.exit(main())