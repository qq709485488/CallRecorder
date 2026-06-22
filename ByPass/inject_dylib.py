#!/usr/bin/env python3
"""Inject a dylib load command into a Mach-O binary.
v4: Remove old code signature before injection, then ldid -S will re-sign.
    Use LC_LOAD_WEAK_DYLIB (weak link) - app won't crash if dylib fails to load.
    This is the safest combination: clean signature + weak link.
"""

import struct
import sys
import os

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_WEAK_DYLIB = 0x18  # weak link - app won't crash if dylib missing
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19

def remove_code_signature(data, verbose=True):
    """Remove LC_CODE_SIGNATURE load command and signature data."""
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
        struct.unpack('<IIIIIIII', data[0:32])
    
    cmd_offset = 32
    sig_cmd_offset = None
    sig_cmdsize = 0
    sig_dataoff = 0
    sig_datasize = 0
    
    for i in range(ncmds):
        if cmd_offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[cmd_offset:cmd_offset+8])
        if cmd == LC_CODE_SIGNATURE:
            sig_cmd_offset = cmd_offset
            sig_cmdsize = cmdsize
            sig_dataoff, sig_datasize = struct.unpack('<II', data[cmd_offset+8:cmd_offset+16])
            if verbose:
                print(f"  Found LC_CODE_SIGNATURE at offset {cmd_offset}: dataoff={sig_dataoff} datasize={sig_datasize}")
        cmd_offset += cmdsize
    
    if sig_cmd_offset is None:
        if verbose:
            print("  No LC_CODE_SIGNATURE found")
        return data
    
    # Remove LC_CODE_SIGNATURE from load commands (shift subsequent bytes left)
    next_offset = sig_cmd_offset + sig_cmdsize
    data[sig_cmd_offset:next_offset] = b''
    
    # Truncate signature data (it's at the end of file)
    if sig_dataoff > 0 and sig_dataoff < len(data):
        data = data[:sig_dataoff]
        if verbose:
            print(f"  Truncated to {sig_dataoff} bytes (removed {sig_datasize} bytes of signature)")
    
    # Update header
    new_ncmds = ncmds - 1
    new_sizeofcmds = sizeofcmds - sig_cmdsize
    struct.pack_into('<II', data, 16, new_ncmds, new_sizeofcmds)
    if verbose:
        print(f"  Updated: ncmds={new_ncmds} sizeofcmds={new_sizeofcmds}")
    
    return data

def inject_dylib(binary_path, dylib_path, output_path=None):
    if output_path is None:
        output_path = binary_path
    
    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())
    
    magic = struct.unpack('<I', data[0:4])[0]
    
    if magic == MH_MAGIC_64:
        return inject_macho_64(data, dylib_path, output_path)
    else:
        magic_be = struct.unpack('>I', data[0:4])[0]
        if magic_be in (0xCAFEBABE, 0xBEBAFECA):
            return inject_fat(data, dylib_path, output_path)
        print(f"Unknown magic: {hex(magic)}")
        return False

def inject_fat(data, dylib_path, output_path):
    magic, nfat_arch = struct.unpack('>II', data[0:8])
    print(f"Fat binary with {nfat_arch} architectures")
    
    for i in range(nfat_arch):
        offset = 8 + i * 20
        cputype, cpusubtype, arch_offset, arch_size, align = struct.unpack('>IIIII', data[offset:offset+20])
        arch_name = {0x0100000C: 'arm64'}.get(cputype, hex(cputype))
        print(f"  Arch {i}: {arch_name} offset={arch_offset} size={arch_size}")
        
        arch_data = bytearray(data[arch_offset:arch_offset+arch_size])
        if inject_macho_64(arch_data, dylib_path, None, verbose=False):
            data[arch_offset:arch_offset+arch_size] = arch_data
    
    with open(output_path, 'wb') as f:
        f.write(data)
    print(f"Written: {output_path}")
    return True

def inject_macho_64(data, dylib_path, output_path, verbose=True):
    """Remove old signature, inject LC_LOAD_DYLIB in padding space."""
    # Step 1: Remove old code signature
    if verbose:
        print("  Step 1: Removing old code signature")
    data = remove_code_signature(data, verbose)
    
    # Step 2: Parse header
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
        struct.unpack('<IIIIIIII', data[0:32])
    
    if magic != MH_MAGIC_64:
        if verbose:
            print(f"  Not a 64-bit Mach-O: {hex(magic)}")
        return False
    
    if verbose:
        print(f"  Step 2: ncmds={ncmds} sizeofcmds={sizeofcmds}")
    
    # Step 3: Build LC_LOAD_WEAK_DYLIB command
    dylib_path_bytes = dylib_path.encode('utf-8') + b'\x00'
    cmd_size = 24 + len(dylib_path_bytes)
    cmd_size = (cmd_size + 7) & ~7  # Align to 8 bytes
    padded_path = dylib_path_bytes + b'\x00' * (cmd_size - 24 - len(dylib_path_bytes))
    
    dylib_cmd = struct.pack('<II', LC_LOAD_WEAK_DYLIB, cmd_size)
    dylib_cmd += struct.pack('<III', 24, 2, 0)  # name offset, timestamp, current version
    dylib_cmd += struct.pack('<I', 0)  # compatibility version
    dylib_cmd += padded_path
    
    # Step 4: Find padding space
    header_end = 32 + sizeofcmds
    cmd_offset = 32
    min_seg_offset = len(data)
    
    for i in range(ncmds):
        if cmd_offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[cmd_offset:cmd_offset+8])
        if cmd == LC_SEGMENT_64 and cmdsize >= 48:
            seg_fileoff = struct.unpack('<Q', data[cmd_offset+40:cmd_offset+48])[0]
            if seg_fileoff > 0 and seg_fileoff < min_seg_offset:
                min_seg_offset = seg_fileoff
        cmd_offset += cmdsize
    
    available_space = min_seg_offset - header_end
    if verbose:
        print(f"  Step 3: Available padding: {available_space} bytes, need: {cmd_size} bytes")
    
    if available_space < cmd_size:
        if verbose:
            print(f"  ERROR: Not enough padding space")
        return False
    
    # Step 5: Write LC_LOAD_DYLIB in padding space
    write_offset = header_end
    data[write_offset:write_offset + cmd_size] = dylib_cmd
    
    # Update header
    new_ncmds = ncmds + 1
    new_sizeofcmds = sizeofcmds + cmd_size
    struct.pack_into('<II', data, 16, new_ncmds, new_sizeofcmds)
    
    if verbose:
        print(f"  Step 4: Written LC_LOAD_WEAK_DYLIB at offset {write_offset}")
        print(f"  Updated: ncmds={new_ncmds} sizeofcmds={new_sizeofcmds}")
    
    if output_path:
        with open(output_path, 'wb') as f:
            f.write(data)
        if verbose:
            print(f"  Written: {output_path}")
    
    return True

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <binary> <dylib_path> [output]")
        sys.exit(1)
    
    binary = sys.argv[1]
    dylib = sys.argv[2]
    output = sys.argv[3] if len(sys.argv) > 3 else None
    
    if inject_dylib(binary, dylib, output):
        print("Success!")
    else:
        print("Failed!")
        sys.exit(1)
