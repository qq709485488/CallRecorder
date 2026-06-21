#!/usr/bin/env python3
"""诊断脚本：分析 Mach-O 二进制结构，帮助调试 patch_binary.py"""

import struct
import sys

def diagnose(binary_path):
    with open(binary_path, 'rb') as f:
        data = f.read()
    
    print(f"File: {binary_path}")
    print(f"Size: {len(data)} bytes")
    
    # 检查架构
    magic = struct.unpack('<I', data[0:4])[0]
    print(f"Magic: 0x{magic:08X}")
    
    offset = 0
    if magic == 0xBEBAFECA:  # FAT
        nfat = struct.unpack('>I', data[4:8])[0]
        print(f"FAT binary with {nfat} architectures")
        for i in range(nfat):
            cputype, cpusubtype = struct.unpack('>II', data[8+i*20:16+i*20])
            arch_offset, size, align = struct.unpack('>III', data[16+i*20:28+i*20])
            print(f"  arch {i}: cpu={cputype}/{cpusubtype} offset={arch_offset} size={size}")
        offset = struct.unpack('>I', data[16:20])[0]
        magic = struct.unpack('<I', data[offset:offset+4])[0]
    
    if magic == 0xFEEDFACF:
        print("arm64 slice detected")
    elif magic == 0xCFFAEDFE:
        print("arm64 big-endian slice detected")
    else:
        print(f"Unknown magic at offset {offset}: 0x{magic:08X}")
        return
    
    # 解析 header
    header = struct.unpack('<IIIIIIII', data[offset:offset+32])
    print(f"Header: cputype={header[0]}, cpusubtype={header[1]}, filetype={header[2]}")
    print(f"  ncmds={header[3]}, sizeofcmds={header[4]}, flags={header[5]:08X}")
    
    ncmds = header[4]
    cmd_offset = offset + 32
    
    sections_found = {}
    
    for i in range(ncmds):
        if cmd_offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[cmd_offset:cmd_offset+8])
        
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[cmd_offset+8:cmd_offset+24].rstrip(b'\x00').decode('utf-8', errors='ignore')
            vmaddr = struct.unpack('<Q', data[cmd_offset+24:cmd_offset+32])[0]
            vmsize = struct.unpack('<Q', data[cmd_offset+32:cmd_offset+40])[0]
            fileoff = struct.unpack('<Q', data[cmd_offset+40:cmd_offset+48])[0]
            filesize = struct.unpack('<Q', data[cmd_offset+48:cmd_offset+56])[0]
            nsects = struct.unpack('<I', data[cmd_offset+64:cmd_offset+68])[0]
            
            print(f"\nSegment: {segname} vmaddr=0x{vmaddr:09X} vmsize=0x{vmsize:X} fileoff=0x{fileoff:X} filesize=0x{filesize:X} nsects={nsects}")
            
            # 解析 sections
            sect_off = cmd_offset + 72
            for j in range(nsects):
                if sect_off + 80 > len(data):
                    break
                sectname = data[sect_off:sect_off+16].rstrip(b'\x00').decode('utf-8', errors='ignore')
                s_segname = data[sect_off+16:sect_off+32].rstrip(b'\x00').decode('utf-8', errors='ignore')
                s_addr = struct.unpack('<Q', data[sect_off+32:sect_off+40])[0]
                s_size = struct.unpack('<Q', data[sect_off+40:sect_off+48])[0]
                s_offset = struct.unpack('<I', data[sect_off+48:sect_off+52])[0]
                
                key = (s_segname, sectname)
                sections_found[key] = (s_addr, s_offset, s_size)
                
                if sectname.startswith('__objc_'):
                    print(f"  Section: {s_segname}.{sectname} addr=0x{s_addr:09X} size=0x{s_size:X} offset=0x{s_offset:X}")
                
                sect_off += 80
        
        elif cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack('<IIII', data[cmd_offset+8:cmd_offset+24])
            print(f"\nLC_SYMTAB: symoff=0x{symoff:X} nsyms={nsyms} stroff=0x{stroff:X} strsize={strsize}")
        
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            sigoff, sigsize = struct.unpack('<II', data[cmd_offset+8:cmd_offset+16])
            print(f"\nLC_CODE_SIGNATURE: dataoff=0x{sigoff:X} datasize={sigsize}")
        
        cmd_offset += cmdsize
    
    # 检查关键 section
    print("\n=== Key sections ===")
    for key_name in ['__objc_classlist', '__objc_catlist', '__objc_protolist', 
                      '__objc_const', '__objc_data', '__objc_methname',
                      '__objc_selrefs', '__objc_classrefs', '__objc_superrefs',
                      '__objc_imageinfo']:
        for (seg, sect), (addr, off, size) in sections_found.items():
            if sect == key_name:
                print(f"  {key_name}: addr=0x{addr:09X} offset=0x{off:X} size=0x{size:X}")
    
    # 如果找到了 __objc_classlist，读取前几个类
    for (seg, sect), (addr, off, size) in sections_found.items():
        if sect == '__objc_classlist':
            print(f"\n=== First 10 classes in __objc_classlist ===")
            count = size // 8
            print(f"Total classes: {count}")
            for i in range(min(10, count)):
                class_ptr = struct.unpack('<Q', data[off + i*8:off + i*8 + 8])[0]
                print(f"  [{i}] class_ptr = 0x{class_ptr:09X}")
                
                # 尝试读取类结构
                # 需要找到 class_ptr 对应的段
                class_fileoff = None
                for (seg2, sect2), (saddr, soff, ssize) in sections_found.items():
                    if saddr <= class_ptr < saddr + ssize:
                        class_fileoff = soff + (class_ptr - saddr)
                        break
                
                if class_fileoff is None:
                    for (segname, seg_vmaddr, seg_vmsize, seg_fileoff, seg_filesize) in []:
                        pass
                    # 从 segments 查找
                    # 重新解析 segments
                    cmd_offset2 = offset + 32
                    for j in range(ncmds):
                        cmd2, cmdsize2 = struct.unpack('<II', data[cmd_offset2:cmd_offset2+8])
                        if cmd2 == 0x19:
                            seg_vmaddr = struct.unpack('<Q', data[cmd_offset2+24:cmd_offset2+32])[0]
                            seg_vmsize = struct.unpack('<Q', data[cmd_offset2+32:cmd_offset2+40])[0]
                            seg_fileoff = struct.unpack('<Q', data[cmd_offset2+40:cmd_offset2+48])[0]
                            if seg_vmaddr <= class_ptr < seg_vmaddr + seg_vmsize:
                                class_fileoff = seg_fileoff + (class_ptr - seg_vmaddr)
                                break
                        cmd_offset2 += cmdsize2
                
                if class_fileoff is None:
                    print(f"    -> Cannot find file offset for class_ptr")
                    continue
                
                # objc_class 结构:
                # isa (8), superclass (8), cache (8), vtable (8), data (8)
                isa = struct.unpack('<Q', data[class_fileoff:class_fileoff+8])[0]
                superclass = struct.unpack('<Q', data[class_fileoff+8:class_fileoff+16])[0]
                data_ptr = struct.unpack('<Q', data[class_fileoff+32:class_fileoff+40])[0]
                print(f"    isa=0x{isa:09X} super=0x{superclass:09X} data=0x{data_ptr:09X}")
                
                # 读取 class_ro_t
                if data_ptr > 0:
                    # 找到 data_ptr 的文件偏移
                    ro_fileoff = None
                    cmd_offset3 = offset + 32
                    for j in range(ncmds):
                        cmd3, cmdsize3 = struct.unpack('<II', data[cmd_offset3:cmd_offset3+8])
                        if cmd3 == 0x19:
                            seg_vmaddr = struct.unpack('<Q', data[cmd_offset3+24:cmd_offset3+32])[0]
                            seg_vmsize = struct.unpack('<Q', data[cmd_offset3+32:cmd_offset3+40])[0]
                            seg_fileoff = struct.unpack('<Q', data[cmd_offset3+40:cmd_offset3+48])[0]
                            if seg_vmaddr <= data_ptr < seg_vmaddr + seg_vmsize:
                                ro_fileoff = seg_fileoff + (data_ptr - seg_vmaddr)
                                break
                        cmd_offset3 += cmdsize3
                    
                    if ro_fileoff:
                        # class_ro_t 结构
                        flags = struct.unpack('<I', data[ro_fileoff:ro_fileoff+4])[0]
                        inst_start = struct.unpack('<I', data[ro_fileoff+4:ro_fileoff+8])[0]
                        inst_size = struct.unpack('<I', data[ro_fileoff+8:ro_fileoff+12])[0]
                        reserved = struct.unpack('<I', data[ro_fileoff+12:ro_fileoff+16])[0]
                        
                        # 尝试多种偏移读取 name 和 methodList
                        for name_off in [24, 28, 32, 36, 40]:
                            name_ptr = struct.unpack('<Q', data[ro_fileoff+name_off:ro_fileoff+name_off+8])[0]
                            if name_ptr > 0 and name_ptr < len(data):
                                try:
                                    end = data.index(0, name_ptr)
                                    name = data[name_ptr:end].decode('utf-8', errors='ignore')
                                    if name and len(name) > 1 and len(name) < 200:
                                        print(f"    name_off={name_off}: name='{name}'")
                                        
                                        # 方法列表在 name 之后 8 字节
                                        method_list_ptr = struct.unpack('<Q', data[ro_fileoff+name_off+8:ro_fileoff+name_off+16])[0]
                                        if method_list_ptr > 0:
                                            # 找到方法列表的文件偏移
                                            ml_fileoff = None
                                            cmd_offset4 = offset + 32
                                            for j in range(ncmds):
                                                cmd4, cmdsize4 = struct.unpack('<II', data[cmd_offset4:cmd_offset4+8])
                                                if cmd4 == 0x19:
                                                    seg_vmaddr = struct.unpack('<Q', data[cmd_offset4+24:cmd_offset4+32])[0]
                                                    seg_vmsize = struct.unpack('<Q', data[cmd_offset4+32:cmd_offset4+40])[0]
                                                    seg_fileoff = struct.unpack('<Q', data[cmd_offset4+40:cmd_offset4+48])[0]
                                                    if seg_vmaddr <= method_list_ptr < seg_vmaddr + seg_vmsize:
                                                        ml_fileoff = seg_fileoff + (method_list_ptr - seg_vmaddr)
                                                        break
                                                cmd_offset4 += cmdsize4
                                            
                                            if ml_fileoff:
                                                entsize_flags = struct.unpack('<I', data[ml_fileoff:ml_fileoff+4])[0]
                                                count = struct.unpack('<I', data[ml_fileoff+4:ml_fileoff+8])[0]
                                                entsize = entsize_flags & 0xFFFF
                                                print(f"      method_list: entsize_flags=0x{entsize_flags:08X} entsize={entsize} count={count}")
                                                
                                                # 读取前几个方法
                                                method_off = ml_fileoff + 8
                                                for k in range(min(3, count)):
                                                    moff = method_off + k * entsize
                                                    if entsize == 24:
                                                        mname_ptr = struct.unpack('<Q', data[moff:moff+8])[0]
                                                        mtypes_ptr = struct.unpack('<Q', data[moff+8:moff+16])[0]
                                                        mimp = struct.unpack('<Q', data[moff+16:moff+24])[0]
                                                    elif entsize == 12:
                                                        name_rel = struct.unpack('<i', data[moff:moff+4])[0]
                                                        types_rel = struct.unpack('<i', data[moff+4:moff+8])[0]
                                                        imp_rel = struct.unpack('<i', data[moff+8:moff+12])[0]
                                                        mname_ptr = moff + name_rel
                                                        mimp = moff + 8 + imp_rel
                                                    else:
                                                        continue
                                                    
                                                    try:
                                                        end = data.index(0, mname_ptr)
                                                        mname = data[mname_ptr:end].decode('utf-8', errors='ignore')
                                                        print(f"        [{k}] {mname} @ IMP=0x{mimp:09X}")
                                                    except:
                                                        print(f"        [{k}] <error reading name>")
                                        break
                                except:
                                    pass
            break


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python diagnose_macho.py <binary_path>")
        sys.exit(1)
    diagnose(sys.argv[1])