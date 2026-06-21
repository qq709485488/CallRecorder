#!/usr/bin/env python3
"""Inject a dylib load command into a Mach-O binary."""

import struct
import sys
import os

MH_MAGIC_64 = 0xFEEDFACF  # little-endian
MH_CIGAM_64 = 0xCFFAEDFE  # big-endian
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
LC_LOAD_DYLIB = 0xC
LC_CODE_SIGNATURE = 0x1D

def inject_dylib(binary_path, dylib_path, output_path=None):
    """Inject LC_LOAD_DYLIB into a Mach-O binary."""
    if output_path is None:
        output_path = binary_path
    
    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())
    
    # Check magic (try both big-endian and little-endian)
    magic_be = struct.unpack('>I', data[0:4])[0]
    magic_le = struct.unpack('<I', data[0:4])[0]
    
    if magic_be == FAT_MAGIC or magic_be == FAT_CIGAM:
        return inject_fat(data, dylib_path, output_path)
    elif magic_le == MH_MAGIC_64 or magic_le == MH_CIGAM_64:
        return inject_macho(data, dylib_path, output_path)
    else:
        print(f"Unknown magic: BE={hex(magic_be)} LE={hex(magic_le)}")
        return False

def inject_fat(data, dylib_path, output_path):
    """Handle fat binary."""
    magic, nfat_arch = struct.unpack('>II', data[0:8])
    print(f"Fat binary with {nfat_arch} architectures")
    
    offset = 8
    modified = False
    for i in range(nfat_arch):
        cputype, cpusubtype, arch_offset, arch_size, align = struct.unpack('>IIIII', data[offset:offset+20])
        arch_name = {0x0100000C: 'arm64', 0x01000007: 'x86_64', 0x00000007: 'i386', 0x0000000C: 'armv7'}.get(cputype, hex(cputype))
        print(f"  Arch {i}: {arch_name} offset={arch_offset} size={arch_size}")
        
        arch_data = data[arch_offset:arch_offset+arch_size]
        new_arch_data = inject_macho_return(arch_data, dylib_path)
        if new_arch_data is not None:
            size_diff = len(new_arch_data) - arch_size
            data[arch_offset:arch_offset+arch_size] = new_arch_data
            # Update size in fat header
            struct.pack_into('>I', data, offset + 12, len(new_arch_data))
            modified = True
    
    if modified:
        with open(output_path, 'wb') as f:
            f.write(data)
        print(f"Written: {output_path}")
        return True
    return False

def inject_macho_return(data, dylib_path):
    """Modify a single Mach-O slice and return the new data."""
    try:
        inject_macho_inplace(data, dylib_path)
        return data
    except Exception as e:
        print(f"  Error: {e}")
        return None

def inject_macho_inplace(data, dylib_path):
    """Modify a single Mach-O slice in place."""
    magic = struct.unpack('<I', data[0:4])[0]
    if magic != MH_MAGIC_64 and magic != MH_CIGAM_64:
        print(f"  Not a 64-bit Mach-O: {hex(magic)}")
        return
    
    cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack('<IIIIII', data[4:28])
    print(f"  ncmds={ncmds} sizeofcmds={sizeofcmds}")
    
    # Build the dylib load command
    dylib_path_bytes = dylib_path.encode('utf-8') + b'\x00'
    # Pad to 8-byte alignment
    cmd_size = 24 + len(dylib_path_bytes)
    # Align to 8 bytes
    cmd_size = (cmd_size + 7) & ~7
    # Pad dylib path
    dylib_path_bytes = dylib_path_bytes + b'\x00' * (cmd_size - 24 - len(dylib_path_bytes))
    
    # Build the command
    dylib_cmd = struct.pack('<II', LC_LOAD_DYLIB, cmd_size)
    dylib_cmd += struct.pack('<III', 24, 2, 0)  # name offset, timestamp, current version
    dylib_cmd += struct.pack('<I', 0)  # compatibility version
    dylib_cmd += dylib_path_bytes
    
    # Find the end of load commands and check for LC_CODE_SIGNATURE
    cmd_offset = 28  # After mach_header_64
    code_sig_offset = None
    code_sig_size = 0
    
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', data[cmd_offset:cmd_offset+8])
        if cmd == LC_CODE_SIGNATURE:
            code_sig_offset = cmd_offset
            code_sig_size = cmdsize
        cmd_offset += cmdsize
    
    end_of_cmds = cmd_offset  # Should equal 28 + sizeofcmds
    
    if code_sig_offset is not None:
        print(f"  Removing LC_CODE_SIGNATURE at offset {code_sig_offset}")
        # Remove code signature load command
        del data[code_sig_offset:code_sig_offset + code_sig_size]
        ncmds -= 1
        sizeofcmds -= code_sig_size
        end_of_cmds = code_sig_offset
    
    # Insert the new load command at the end of load commands
    insert_pos = end_of_cmds
    data[insert_pos:insert_pos] = dylib_cmd
    ncmds += 1
    sizeofcmds += cmd_size
    
    # Update the Mach-O header
    struct.pack_into('<IIIIII', data, 4, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags)
    print(f"  Updated: ncmds={ncmds} sizeofcmds={sizeofcmds}")

def inject_macho(data, dylib_path, output_path):
    """Handle single Mach-O binary."""
    inject_macho_inplace(data, dylib_path)
    with open(output_path, 'wb') as f:
        f.write(data)
    print(f"Written: {output_path}")
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