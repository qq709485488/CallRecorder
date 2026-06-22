#!/usr/bin/env python3
"""Inject a dylib load command into a Mach-O binary.
v2: Uses header padding space (no data shifting, no offset updates needed).
This is the same approach as insert_dylib/optool.
"""

import struct
import sys
import os

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x18  # weak link - app won't crash if dylib missing

def inject_dylib(binary_path, dylib_path, output_path=None, weak=True):
    if output_path is None:
        output_path = binary_path
    
    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())
    
    magic = struct.unpack('<I', data[0:4])[0]
    
    if magic == MH_MAGIC_64:
        return inject_macho_64(data, dylib_path, output_path, weak)
    else:
        # Check FAT binary
        magic_be = struct.unpack('>I', data[0:4])[0]
        if magic_be in (0xCAFEBABE, 0xBEBAFECA):
            return inject_fat(data, dylib_path, output_path, weak)
        print(f"Unknown magic: {hex(magic)}")
        return False

def inject_fat(data, dylib_path, output_path, weak):
    """Handle fat binary."""
    magic, nfat_arch = struct.unpack('>II', data[0:8])
    print(f"Fat binary with {nfat_arch} architectures")
    
    for i in range(nfat_arch):
        offset = 8 + i * 20
        cputype, cpusubtype, arch_offset, arch_size, align = struct.unpack('>IIIII', data[offset:offset+20])
        arch_name = {0x0100000C: 'arm64'}.get(cputype, hex(cputype))
        print(f"  Arch {i}: {arch_name} offset={arch_offset} size={arch_size}")
        
        arch_data = bytearray(data[arch_offset:arch_offset+arch_size])
        if inject_macho_64(arch_data, dylib_path, None, weak, verbose=False):
            data[arch_offset:arch_offset+arch_size] = arch_data
            # Update size if changed (shouldn't change with padding approach)
    
    with open(output_path, 'wb') as f:
        f.write(data)
    print(f"Written: {output_path}")
    return True

def inject_macho_64(data, dylib_path, output_path, weak=True, verbose=True):
    """Inject LC_LOAD_DYLIB into a 64-bit Mach-O using header padding."""
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
        struct.unpack('<IIIIIIII', data[0:32])
    
    if magic != MH_MAGIC_64:
        if verbose:
            print(f"  Not a 64-bit Mach-O: {hex(magic)}")
        return False
    
    if verbose:
        print(f"  ncmds={ncmds} sizeofcmds={sizeofcmds}")
    
    # Build the dylib load command
    cmd_type = LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB
    dylib_path_bytes = dylib_path.encode('utf-8') + b'\x00'
    cmd_size = 24 + len(dylib_path_bytes)
    # Align to 8 bytes
    cmd_size = (cmd_size + 7) & ~7
    # Pad dylib path
    padded_path = dylib_path_bytes + b'\x00' * (cmd_size - 24 - len(dylib_path_bytes))
    
    # Build load command: cmd, cmdsize, name_offset, timestamp, current_version, compat_version, path
    dylib_cmd = struct.pack('<II', cmd_type, cmd_size)
    dylib_cmd += struct.pack('<III', 24, 2, 0)  # name offset=24, timestamp=2, current version=0
    dylib_cmd += struct.pack('<I', 0)  # compatibility version
    dylib_cmd += padded_path
    
    # Calculate available padding space
    # Header is 32 bytes (mach_header_64), load commands start at offset 32
    # Padding is between end of load commands and start of first segment data
    header_end = 32 + sizeofcmds
    
    # Find the first segment's file offset (usually __TEXT at offset 0)
    # We need to find the minimum file offset of all segments
    cmd_offset = 32  # After mach_header_64
    min_seg_offset = len(data)  # Default to end of file
    
    LC_SEGMENT_64 = 0x19
    for i in range(ncmds):
        if cmd_offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack('<II', data[cmd_offset:cmd_offset+8])
        if cmd == LC_SEGMENT_64:
            # LC_SEGMENT_64: cmd(4) + cmdsize(4) + segname(16) + vmaddr(8) + vmsize(8) + fileoff(8) + filesize(8) + ...
            if cmdsize >= 48:
                seg_fileoff = struct.unpack('<Q', data[cmd_offset+40:cmd_offset+48])[0]
                if seg_fileoff > 0 and seg_fileoff < min_seg_offset:
                    min_seg_offset = seg_fileoff
        cmd_offset += cmdsize
    
    available_space = min_seg_offset - header_end
    if verbose:
        print(f"  Header ends at: {header_end}")
        print(f"  First segment at: {min_seg_offset}")
        print(f"  Available padding: {available_space} bytes")
        print(f"  Need: {cmd_size} bytes")
    
    if available_space < cmd_size:
        if verbose:
            print(f"  ERROR: Not enough padding space ({available_space} < {cmd_size})")
            print(f"  Trying to use end of file approach...")
        
        # Alternative: append at end of load commands and shift data
        # This is more complex but sometimes necessary
        # For now, just fail
        return False
    
    # Write the new load command in the padding space
    write_offset = header_end
    data[write_offset:write_offset + cmd_size] = dylib_cmd
    
    # Update header: ncmds and sizeofcmds
    new_ncmds = ncmds + 1
    new_sizeofcmds = sizeofcmds + cmd_size
    struct.pack_into('<II', data, 16, new_ncmds, new_sizeofcmds)  # ncmds at offset 16, sizeofcmds at offset 20
    
    if verbose:
        print(f"  Written LC_{'WEAK_' if weak else ''}LOAD_DYLIB at offset {write_offset}")
        print(f"  Updated: ncmds={new_ncmds} sizeofcmds={new_sizeofcmds}")
        print(f"  Dylib path: {dylib_path}")
    
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
    
    # Use weak link by default - app won't crash if dylib is missing
    weak = '--no-weak' not in sys.argv
    
    if inject_dylib(binary, dylib, output, weak=weak):
        print("Success!")
    else:
        print("Failed!")
        sys.exit(1)
