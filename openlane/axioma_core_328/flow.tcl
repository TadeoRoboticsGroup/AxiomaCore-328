#!/usr/bin/env tclsh
# AxiomaCore-328 OpenLane Flow Script
# Compatible with OpenLane 2.0+

set script_dir [file dirname [file normalize [info script]]]

# Try to load OpenLane package, fallback to basic flow if not available
if {[catch {package require openlane 2.0} err]} {
    puts "OpenLane package not found, using basic flow approach..."
    set openlane_available 0
} else {
    set openlane_available 1
}

# Check for interactive mode
if {[lsearch $argv "-interactive"] != -1} {
    puts "Starting OpenLane interactive session for AxiomaCore-328..."
    
    # Load design configuration
    set config_file "$script_dir/config/config.json"
    if {![file exists $config_file]} {
        puts "ERROR: Configuration file not found: $config_file"
        exit 1
    }
    
    # Start interactive session
    puts "Loading configuration: $config_file"
    puts "Design: axioma_cpu"
    puts "Process: Sky130A 130nm"
    puts ""
    puts "Available commands:"
    puts "  run_synthesis     - Run logic synthesis"
    puts "  run_floorplan     - Run floorplanning"
    puts "  run_placement     - Run placement"
    puts "  run_cts           - Run clock tree synthesis"
    puts "  run_routing       - Run routing"
    puts "  run_magic         - Run DRC/LVS checks"
    puts "  run_klayout       - Run additional verification"
    puts "  save_views        - Save final outputs"
    puts ""
    puts "Type 'help' for more OpenLane commands"
    
    # Load the design and enter interactive mode
    exec openlane -config $config_file -interactive
    
} else {
    puts "Running complete AxiomaCore-328 RTL-to-GDSII flow..."
    
    # Set configuration file
    set config_file "$script_dir/config/config.json"
    
    if {![file exists $config_file]} {
        puts "ERROR: Configuration file not found: $config_file"
        exit 1
    }
    
    # Check if source files exist
    set src_dir "$script_dir/src"
    if {![file exists "$src_dir/axioma_cpu.v"]} {
        puts "ERROR: Source files not found in $src_dir"
        puts "Please run 'make openlane-setup' first to copy RTL files"
        exit 1
    }
    
    puts "Configuration: $config_file"
    puts "Source directory: $src_dir"
    puts "Target process: Sky130A 130nm"
    puts "Design frequency: 25MHz (40ns period)"
    puts ""
    
    # Run the complete flow
    puts "Starting OpenLane flow..."
    
    # Execute OpenLane with the configuration
    if {[catch {exec openlane -config $config_file} result]} {
        puts "ERROR: OpenLane flow failed!"
        puts $result
        exit 1
    } else {
        puts "SUCCESS: OpenLane flow completed!"
        puts $result
        
        # Show results location
        set runs_dir "$script_dir/runs"
        puts ""
        puts "Results available in: $runs_dir"
        puts "GDSII file: [glob -nocomplain $runs_dir/*/results/final/gds/*.gds]"
        puts "LEF file: [glob -nocomplain $runs_dir/*/results/final/lef/*.lef]"
        puts "Reports: [glob -nocomplain $runs_dir/*/reports]"
    }
}