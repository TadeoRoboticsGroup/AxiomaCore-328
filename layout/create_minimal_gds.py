#!/usr/bin/env python3
"""
Minimal GDS layout generator for AxiomaCore-328
Creates the simplest possible valid GDSII file
"""

import struct
import datetime

def create_minimal_gds(filename):
    """Create minimal valid GDS file"""
    with open(filename, 'wb') as f:
        
        # 1. HEADER (6 bytes total)
        f.write(struct.pack('>HHH', 6, 0x0002, 600))
        
        # 2. BGNLIB (28 bytes total)
        f.write(struct.pack('>HH', 28, 0x0102))
        now = datetime.datetime.now()
        times = [now.year, now.month, now.day, now.hour, now.minute, now.second] * 2
        for t in times:
            f.write(struct.pack('>H', t))
        
        # 3. LIBNAME
        lib_name = b'AXIOMA'
        f.write(struct.pack('>HH', 4 + len(lib_name), 0x0206))
        f.write(lib_name)
        
        # 4. UNITS (20 bytes total)
        f.write(struct.pack('>HH', 20, 0x0305))
        f.write(struct.pack('>dd', 0.001, 1e-9))
        
        # 5. BGNSTR (28 bytes total)
        f.write(struct.pack('>HH', 28, 0x0502))
        for t in times:
            f.write(struct.pack('>H', t))
        
        # 6. STRNAME
        str_name = b'CHIP'
        f.write(struct.pack('>HH', 4 + len(str_name), 0x0606))
        f.write(str_name)
        
        # 7. Simple rectangle
        # BOUNDARY
        f.write(struct.pack('>HH', 4, 0x0800))
        # LAYER
        f.write(struct.pack('>HH', 6, 0x0D02))
        f.write(struct.pack('>H', 1))
        # DATATYPE
        f.write(struct.pack('>HH', 6, 0x0E02))
        f.write(struct.pack('>H', 0))
        # XY
        coords = [0, 0, 100000, 0, 100000, 100000, 0, 100000, 0, 0]
        f.write(struct.pack('>HH', 4 + 4*len(coords), 0x1003))
        for coord in coords:
            f.write(struct.pack('>l', coord))
        # ENDEL
        f.write(struct.pack('>HH', 4, 0x1100))
        
        # 8. ENDSTR
        f.write(struct.pack('>HH', 4, 0x0700))
        
        # 9. ENDLIB
        f.write(struct.pack('>HH', 4, 0x0400))

def hex_dump(filename, max_bytes=200):
    """Show hex dump of file"""
    try:
        with open(filename, 'rb') as f:
            data = f.read(max_bytes)
        
        print(f"📋 Hex dump of {filename} (first {len(data)} bytes):")
        for i in range(0, len(data), 16):
            chunk = data[i:i+16]
            hex_str = ' '.join(f'{b:02X}' for b in chunk)
            ascii_str = ''.join(chr(b) if 32 <= b <= 126 else '.' for b in chunk)
            print(f"{i:04X}: {hex_str:<48} |{ascii_str}|")
    except Exception as e:
        print(f"❌ Error reading file: {e}")

if __name__ == "__main__":
    filename = "axioma_minimal.gds"
    create_minimal_gds(filename)
    print(f"✅ Minimal GDS created: {filename}")
    
    # Show file info
    import os
    size = os.path.getsize(filename)
    print(f"📏 File size: {size} bytes")
    
    # Hex dump for debugging
    hex_dump(filename)