#!/usr/bin/env python3
"""Patch Info.plist to add DYLD_INSERT_LIBRARIES for dylib loading."""
import plistlib, sys

def patch_plist(plist_path, dylib_name="TrollRecorderBypass.dylib"):
    with open(plist_path, 'rb') as f:
        plist = plistlib.load(f)
    
    if 'LSEnvironment' not in plist:
        plist['LSEnvironment'] = {}
    
    plist['LSEnvironment']['DYLD_INSERT_LIBRARIES'] = dylib_name
    
    with open(plist_path, 'wb') as f:
        plistlib.dump(plist, f)
    
    # Verify
    with open(plist_path, 'rb') as f:
        verify = plistlib.load(f)
    if verify.get('LSEnvironment', {}).get('DYLD_INSERT_LIBRARIES') == dylib_name:
        print(f"SUCCESS: Info.plist patched with DYLD_INSERT_LIBRARIES={dylib_name}")
        return True
    print("ERROR: plist verification failed")
    return False

if __name__ == '__main__':
    plist_path = sys.argv[1] if len(sys.argv) > 1 else "Info.plist"
    dylib_name = sys.argv[2] if len(sys.argv) > 2 else "TrollRecorderBypass.dylib"
    sys.exit(0 if patch_plist(plist_path, dylib_name) else 1)
