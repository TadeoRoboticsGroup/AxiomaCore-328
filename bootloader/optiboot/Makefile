# Makefile for Optiboot bootloader for AxiomaCore-328
# Based on original Optiboot by Peter Knight and others
# Modified for AxiomaCore-328 compatibility

PROGRAM    = optiboot
OPTIMIZE   = -Os -fno-inline-small-functions -fno-split-wide-types -mshort-calls
DEFS       = 
LIBS       =

CC         = avr-gcc

# Override is only needed by avr-lib build system.
override CFLAGS        = -g -Wall $(OPTIMIZE) -mmcu=$(TARGET) -DF_CPU=$(AVR_FREQ) $(DEFS)
override LDFLAGS       = $(LDSECTIONS) -Wl,--relax -nostartfiles

OBJCOPY        = avr-objcopy
OBJDUMP        = avr-objdump
SIZE           = avr-size

# AxiomaCore-328 variants

# Standard AxiomaCore-328 @ 16MHz
axioma328: TARGET = atmega328p
axioma328: AVR_FREQ = 16000000L
axioma328: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328: $(PROGRAM)_axioma328.hex
axioma328: $(PROGRAM)_axioma328.lst

# AxiomaCore-328 Uno R4 @ 16MHz
axioma328_uno: TARGET = atmega328p
axioma328_uno: AVR_FREQ = 16000000L
axioma328_uno: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328_uno: $(PROGRAM)_axioma328_uno.hex
axioma328_uno: $(PROGRAM)_axioma328_uno.lst

# AxiomaCore-328 Nano Plus @ 16MHz
axioma328_nano: TARGET = atmega328p
axioma328_nano: AVR_FREQ = 16000000L
axioma328_nano: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328_nano: $(PROGRAM)_axioma328_nano.hex
axioma328_nano: $(PROGRAM)_axioma328_nano.lst

# AxiomaCore-328 Pro @ 16MHz
axioma328_16mhz: TARGET = atmega328p
axioma328_16mhz: AVR_FREQ = 16000000L
axioma328_16mhz: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328_16mhz: $(PROGRAM)_axioma328_16mhz.hex
axioma328_16mhz: $(PROGRAM)_axioma328_16mhz.lst

# AxiomaCore-328 Pro @ 20MHz
axioma328_20mhz: TARGET = atmega328p
axioma328_20mhz: AVR_FREQ = 20000000L
axioma328_20mhz: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328_20mhz: $(PROGRAM)_axioma328_20mhz.hex
axioma328_20mhz: $(PROGRAM)_axioma328_20mhz.lst

# AxiomaCore-328 Pro @ 25MHz (High Performance)
axioma328_25mhz: TARGET = atmega328p
axioma328_25mhz: AVR_FREQ = 25000000L
axioma328_25mhz: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328_25mhz: $(PROGRAM)_axioma328_25mhz.hex
axioma328_25mhz: $(PROGRAM)_axioma328_25mhz.lst

# AxiomaCore-328 Pro @ 8MHz Internal
axioma328_8mhz: TARGET = atmega328p
axioma328_8mhz: AVR_FREQ = 8000000L
axioma328_8mhz: LDSECTIONS = -Wl,--section-start=.text=0x7e00 -Wl,--section-start=.version=0x7ffe
axioma328_8mhz: $(PROGRAM)_axioma328_8mhz.hex
axioma328_8mhz: $(PROGRAM)_axioma328_8mhz.lst

# Build all AxiomaCore-328 variants
all_axioma: axioma328 axioma328_uno axioma328_nano axioma328_16mhz axioma328_20mhz axioma328_25mhz axioma328_8mhz

HELPTEXT = "Build targets:"\\n\\
" all_axioma    - Build all AxiomaCore-328 bootloader variants"\\n\\
" axioma328     - Standard AxiomaCore-328"\\n\\
" axioma328_uno - AxiomaCore-328 Uno R4"\\n\\
" axioma328_nano - AxiomaCore-328 Nano Plus"\\n\\
" axioma328_16mhz - AxiomaCore-328 Pro @ 16MHz"\\n\\
" axioma328_20mhz - AxiomaCore-328 Pro @ 20MHz"\\n\\
" axioma328_25mhz - AxiomaCore-328 Pro @ 25MHz"\\n\\
" axioma328_8mhz - AxiomaCore-328 Pro @ 8MHz"\\n\\

help:
	@echo $(HELPTEXT)

$(PROGRAM).elf: $(PROGRAM).c 
	@echo "Building $(TARGET) @ $(AVR_FREQ) Hz"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBS)
	$(SIZE) $@

clean:
	rm -rf *.o *.elf *.lst *.map *.sym *.lss *.eep *.srec *.bin *.hex

%.lst: %.elf
	$(OBJDUMP) -h -S $< > $@

%.hex: %.elf
	$(OBJCOPY) -j .text -j .data -j .version --set-section-flags .version=alloc,load -O ihex $< $@

%.srec: %.elf
	$(OBJCOPY) -j .text -j .data -j .version --set-section-flags .version=alloc,load -O srec $< $@

%.bin: %.elf
	$(OBJCOPY) -j .text -j .data -j .version --set-section-flags .version=alloc,load -O binary $< $@

# Versions with different names
$(PROGRAM)_%.elf: $(PROGRAM).c
	@echo "Building $* variant"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBS)
	$(SIZE) $@

# Programming commands (for development)
program: $(PROGRAM).hex
	avrdude -p $(TARGET) -c usbasp -U flash:w:$(PROGRAM).hex

program_fuseH: 
	avrdude -p $(TARGET) -c usbasp -U hfuse:w:0xDE:m

program_fuseL: 
	avrdude -p $(TARGET) -c usbasp -U lfuse:w:0xFF:m

program_fuseE: 
	avrdude -p $(TARGET) -c usbasp -U efuse:w:0xFD:m

program_fuses: program_fuseL program_fuseH program_fuseE

program_lock:
	avrdude -p $(TARGET) -c usbasp -U lock:w:0x0F:m