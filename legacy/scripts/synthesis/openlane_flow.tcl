# AxiomaCore-328 OpenLane Flow Script
# Automated RTL-to-GDSII flow para Fase 9

package require openlane 2.0

# Set design configuration
set ::env(DESIGN_NAME) "axioma_cpu_v5"
set ::env(DESIGN_DIR) "/home/axioma/silicluster_projects/axioma_core_328/openlane/axioma_core_328"

# Load configuration from JSON
load_config $::env(DESIGN_DIR)/config/config.json

# Design sources
set ::env(VERILOG_FILES) [glob $::env(DESIGN_DIR)/src/*.v]

# Clock configuration
set ::env(CLOCK_PERIOD) 40.0
set ::env(CLOCK_PORT) "clk_ext"
set ::env(CLOCK_NET) "clk_ext"

# Floorplan configuration
set ::env(FP_SIZING) "absolute"
set ::env(DIE_AREA) "0 0 3000 3000"
set ::env(CORE_AREA) "14 14 2986 2986"

# Pin configuration
set ::env(FP_PIN_ORDER_CFG) $::env(DESIGN_DIR)/config/pin_order.cfg

# Timing constraints
set ::env(BASE_SDC_FILE) $::env(DESIGN_DIR)/config/constraints.sdc

# Target density for placement
set ::env(PL_TARGET_DENSITY) 0.40

# Power configuration
set ::env(VDD_NETS) "vccd1"
set ::env(GND_NETS) "vssd1"
set ::env(VDD_PIN) "vccd1"
set ::env(GND_PIN) "vssd1"

# PDK configuration
set ::env(PDK) "sky130A"
set ::env(STD_CELL_LIBRARY) "sky130_fd_sc_hd"

# Synthesis configuration
set ::env(SYNTH_STRATEGY) "AREA 0"
set ::env(SYNTH_BUFFERING) 1
set ::env(SYNTH_SIZING) 1
set ::env(SYNTH_SHARE_RESOURCES) 1
set ::env(SYNTH_MAX_FANOUT) 8

# CTS configuration  
set ::env(CTS_TARGET_SKEW) 50
set ::env(CTS_ROOT_BUFFER) "sky130_fd_sc_hd__buf_12"

# Routing configuration
set ::env(RT_MAX_LAYER) "met4"
set ::env(GLB_RT_MAXLAYER) 5

# DRC/LVS configuration
set ::env(RUN_KLAYOUT) 1
set ::env(RUN_KLAYOUT_DRC) 1
set ::env(RUN_KLAYOUT_XOR) 1
set ::env(RUN_MAGIC_DRC) 1
set ::env(RUN_NETGEN_LVS) 1

# Quality control
set ::env(QUIT_ON_TIMING_VIOLATIONS) 0
set ::env(QUIT_ON_MAGIC_DRC) 0
set ::env(QUIT_ON_LVS_ERROR) 0

# Flow execution
prep -design $::env(DESIGN_NAME) -tag "axioma_phase9_tapeout" -init_design_config

# Run synthesis
run_synthesis

# Check synthesis results
if {[info exists ::env(SYNTH_CELL_COUNT)]} {
    puts "Synthesis successful: $::env(SYNTH_CELL_COUNT) cells"
} else {
    puts "ERROR: Synthesis failed"
    exit 1
}

# Run floorplan
run_floorplan

# Check floorplan
puts "Floorplan area: [expr $::env(DIE_AREA_UMS2)] um^2"

# Run placement
run_placement

# Check placement
if {[info exists ::env(PLACE_UTIL)]} {
    puts "Placement utilization: $::env(PLACE_UTIL)%"
}

# Run CTS (Clock Tree Synthesis)
run_cts

# Check timing after CTS
check_timing_violations

# Run routing
run_routing

# Final timing analysis
run_sta

# Physical verification
run_magic_drc

# LVS verification
run_netgen_lvs

# Generate final GDSII
run_magic

# Generate reports
generate_final_summary

puts "AxiomaCore-328 Tape-out Flow Complete!"
puts "GDSII file: $::env(DESIGN_DIR)/runs/axioma_phase9_tapeout/results/final/gds/$::env(DESIGN_NAME).gds"
puts "LEF file: $::env(DESIGN_DIR)/runs/axioma_phase9_tapeout/results/final/lef/$::env(DESIGN_NAME).lef"
puts "Netlist: $::env(DESIGN_DIR)/runs/axioma_phase9_tapeout/results/final/verilog/gl/$::env(DESIGN_NAME).nl.v"

exit 0