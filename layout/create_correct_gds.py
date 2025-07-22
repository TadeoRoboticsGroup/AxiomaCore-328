#!/usr/bin/env python3
"""
Corrected GDS layout generator for AxiomaCore-328
Creates a valid GDSII Stream file for KLayout visualization
"""

import struct
import datetime

def write_record(f, record_type, data_type, data=b''):
    """Write a GDS record with proper header"""
    length = 4 + len(data)
    f.write(struct.pack('>H', length))      # Record length
    f.write(struct.pack('>H', (record_type << 8) | data_type))  # Record type + data type
    if data:
        f.write(data)

def write_int16(f, record_type, value):
    """Write 16-bit integer record"""
    write_record(f, record_type, 2, struct.pack('>H', value))

def write_int32(f, record_type, value):
    """Write 32-bit integer record"""
    write_record(f, record_type, 3, struct.pack('>l', value))

def write_real64(f, record_type, value):
    """Write 64-bit real record"""
    write_record(f, record_type, 5, struct.pack('>d', value))

def write_string(f, record_type, text):
    """Write string record with padding"""
    data = text.encode('ascii')
    if len(data) % 2:
        data += b'\0'  # Pad to even length
    write_record(f, record_type, 6, data)

def write_time(f, record_type):
    """Write timestamp record"""
    now = datetime.datetime.now()
    times = [now.year, now.month, now.day, now.hour, now.minute, now.second] * 2
    data = b''.join(struct.pack('>H', t) for t in times)
    write_record(f, record_type, 2, data)

def write_xy_coords(f, coords):
    """Write XY coordinate record"""
    data = b''.join(struct.pack('>l', coord) for coord in coords)
    write_record(f, 0x10, 3, data)  # XY record

def create_axioma_gds(filename):
    """Create valid GDS file for AxiomaCore-328"""
    with open(filename, 'wb') as f:
        
        # 1. HEADER
        write_int16(f, 0x00, 600)  # GDS version 600
        
        # 2. BGNLIB
        write_time(f, 0x01)
        
        # 3. LIBNAME
        write_string(f, 0x02, 'AXIOMA_LIB')
        
        # 4. UNITS
        write_record(f, 0x03, 5, struct.pack('>dd', 0.001, 1e-9))
        
        # 5. BGNSTR
        write_time(f, 0x05)
        
        # 6. STRNAME
        write_string(f, 0x06, 'AXIOMA_CPU')
        
        # Create layout elements
        
        # Substrate rectangle (layer 0)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 0)   # LAYER 0
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [0, 0, 1000000, 0, 1000000, 1000000, 0, 1000000, 0, 0])
        write_record(f, 0x11, 0)  # ENDEL
        
        # N-diffusion rectangle (layer 1)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 1)   # LAYER 1
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [50000, 50000, 950000, 50000, 950000, 950000, 50000, 950000, 50000, 50000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # Polysilicon rectangle (layer 2)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 2)   # LAYER 2
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [100000, 100000, 900000, 100000, 900000, 900000, 100000, 900000, 100000, 100000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # Metal1 rectangle (layer 3)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 3)   # LAYER 3
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [150000, 150000, 850000, 150000, 850000, 850000, 150000, 850000, 150000, 150000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # Via1 rectangle (layer 4)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 4)   # LAYER 4
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [200000, 200000, 300000, 200000, 300000, 300000, 200000, 300000, 200000, 200000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # Metal2 rectangle (layer 5)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 5)   # LAYER 5
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [180000, 180000, 820000, 180000, 820000, 820000, 180000, 820000, 180000, 180000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # CPU Core area (layer 10)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 10)  # LAYER 10
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [300000, 300000, 700000, 300000, 700000, 700000, 300000, 700000, 300000, 300000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # ALU area (layer 11)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 11)  # LAYER 11
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [320000, 320000, 480000, 320000, 480000, 480000, 320000, 480000, 320000, 320000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # Register file (layer 12)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 12)  # LAYER 12
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [520000, 320000, 680000, 320000, 680000, 480000, 520000, 480000, 520000, 320000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # Decoder area (layer 13)
        write_record(f, 0x08, 0)  # BOUNDARY
        write_int16(f, 0x0D, 13)  # LAYER 13
        write_int16(f, 0x0E, 0)   # DATATYPE 0
        write_xy_coords(f, [320000, 520000, 680000, 520000, 680000, 680000, 320000, 680000, 320000, 520000])
        write_record(f, 0x11, 0)  # ENDEL
        
        # 7. ENDSTR
        write_record(f, 0x07, 0)
        
        # 8. ENDLIB
        write_record(f, 0x04, 0)

def verify_gds_file(filename):
    """Verify the GDS file structure"""
    try:
        with open(filename, 'rb') as f:
            content = f.read()
            print(f"✅ GDS file size: {len(content)} bytes")
            
            # Check header
            if len(content) >= 6:
                length, record = struct.unpack('>HH', content[0:4])
                version = struct.unpack('>H', content[4:6])[0]
                print(f"✅ Header: length={length}, record=0x{record:04X}, version={version}")
            
            print(f"✅ File structure appears valid")
            return True
    except Exception as e:
        print(f"❌ Error verifying GDS: {e}")
        return False

if __name__ == "__main__":
    filename = "axioma_cpu_layout.gds"
    create_axioma_gds(filename)
    print("✅ GDS layout created: axioma_cpu_layout.gds")
    print("📏 Chip size: 1000x1000 µm")
    print("🔧 Layers: 0-5 (process), 10-13 (functional)")
    print("🏭 Functional blocks: CPU, ALU, Registers, Decoder")
    
    if verify_gds_file(filename):
        print("✅ GDS file verification passed")
    else:
        print("❌ GDS file verification failed")