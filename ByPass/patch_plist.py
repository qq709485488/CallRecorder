#!/usr/bin/env python3
"""
patch_plist.py - 向 Info.plist 注入 LSEnvironment → DYLD_INSERT_LIBRARIES
用于 TrollStore 环境：让 launchd 在启动 App 时自动加载指定 dylib
"""
import plistlib
import sys
import os

def patch_plist(plist_path, dylib_name):
    """向二进制 plist 添加 LSEnvironment 字典"""
    if not os.path.exists(plist_path):
        print(f"ERROR: {plist_path} not found")
        sys.exit(1)
    
    # 读取现有 plist（支持 XML 和 binary）
    with open(plist_path, 'rb') as f:
        plist = plistlib.load(f)
    
    # 检查或创建 LSEnvironment
    ls_env = plist.get('LSEnvironment', {})
    if not isinstance(ls_env, dict):
        ls_env = {}
    
    current = ls_env.get('DYLD_INSERT_LIBRARIES', '')
    if dylib_name in current:
        print(f"LSEnvironment already contains {dylib_name}, skipping")
        return
    
    # 追加 dylib（用冒号分隔多个 dylib）
    if current:
        ls_env['DYLD_INSERT_LIBRARIES'] = f"{current}:{dylib_name}"
    else:
        ls_env['DYLD_INSERT_LIBRARIES'] = dylib_name
    
    plist['LSEnvironment'] = ls_env
    
    # 写回（binary 格式，节省空间）
    with open(plist_path, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    
    print(f"Patched {plist_path}: LSEnvironment → DYLD_INSERT_LIBRARIES = {ls_env['DYLD_INSERT_LIBRARIES']}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python3 patch_plist.py <Info.plist> <dylib_name>")
        sys.exit(1)
    
    patch_plist(sys.argv[1], sys.argv[2])
