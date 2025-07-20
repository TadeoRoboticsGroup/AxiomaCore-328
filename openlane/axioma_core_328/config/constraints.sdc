# AxiomaCore-328 SDC Constraints para Tape-out
# Timing constraints para 25MHz operation (40ns period)

set_units -time ns -resistance kOhm -capacitance pF -voltage V -current mA

# Clock definition
create_clock [get_ports clk_ext] -name clk_ext -period 40.0 -waveform {0 20}
create_clock [get_ports clk_32khz] -name clk_32khz -period 31250.0 -waveform {0 15625}

# Clock groups (asynchronous)
set_clock_groups -asynchronous -group {clk_ext} -group {clk_32khz}

# Input delays (relative to clk_ext)
set_input_delay -clock clk_ext -max 8.0 [get_ports {reset_ext_n power_on_reset_n vcc_voltage_ok}]
set_input_delay -clock clk_ext -min 2.0 [get_ports {reset_ext_n power_on_reset_n vcc_voltage_ok}]

# GPIO input delays
set_input_delay -clock clk_ext -max 10.0 [get_ports {portb_pin[*] portc_pin[*] portd_pin[*]}]
set_input_delay -clock clk_ext -min 2.0 [get_ports {portb_pin[*] portc_pin[*] portd_pin[*]}]

# Communication interface input delays
set_input_delay -clock clk_ext -max 8.0 [get_ports {uart_rx spi_miso sda scl}]
set_input_delay -clock clk_ext -min 2.0 [get_ports {uart_rx spi_miso sda scl}]

# ADC input delays
set_input_delay -clock clk_ext -max 15.0 [get_ports {adc_channels[*] aref_voltage avcc_voltage}]
set_input_delay -clock clk_ext -min 2.0 [get_ports {adc_channels[*] aref_voltage avcc_voltage}]

# Interrupt input delays (critical timing)
set_input_delay -clock clk_ext -max 5.0 [get_ports {int0_pin int1_pin icp1_pin}]
set_input_delay -clock clk_ext -min 1.0 [get_ports {int0_pin int1_pin icp1_pin}]

# Configuration input delays
set_input_delay -clock clk_ext -max 20.0 [get_ports {clock_select[*] clock_prescaler[*] bootloader_enable}]
set_input_delay -clock clk_ext -min 5.0 [get_ports {clock_select[*] clock_prescaler[*] bootloader_enable}]

# Output delays
set_output_delay -clock clk_ext -max 12.0 [get_ports {portb_out[*] portb_ddr[*]}]
set_output_delay -clock clk_ext -min 3.0 [get_ports {portb_out[*] portb_ddr[*]}]

set_output_delay -clock clk_ext -max 12.0 [get_ports {portc_out[*] portc_ddr[*]}]
set_output_delay -clock clk_ext -min 3.0 [get_ports {portc_out[*] portc_ddr[*]}]

set_output_delay -clock clk_ext -max 12.0 [get_ports {portd_out[*] portd_ddr[*]}]
set_output_delay -clock clk_ext -min 3.0 [get_ports {portd_out[*] portd_ddr[*]}]

# Communication interface output delays  
set_output_delay -clock clk_ext -max 10.0 [get_ports {uart_tx spi_mosi spi_sck spi_ss}]
set_output_delay -clock clk_ext -min 2.0 [get_ports {uart_tx spi_mosi spi_sck spi_ss}]

# PWM output delays (high precision required)
set_output_delay -clock clk_ext -max 8.0 [get_ports {oc0a_pin oc0b_pin oc1a_pin oc1b_pin oc2a_pin oc2b_pin}]
set_output_delay -clock clk_ext -min 2.0 [get_ports {oc0a_pin oc0b_pin oc1a_pin oc1b_pin oc2a_pin oc2b_pin}]

# Status output delays
set_output_delay -clock clk_ext -max 15.0 [get_ports {cpu_halted status_reg[*] system_clock_ready mcusr_reg[*]}]
set_output_delay -clock clk_ext -min 3.0 [get_ports {cpu_halted status_reg[*] system_clock_ready mcusr_reg[*]}]

# Load constraints (typical Arduino board loading)
set_load 5.0 [get_ports {portb_out[*] portc_out[*] portd_out[*]}]
set_load 2.0 [get_ports {uart_tx spi_mosi spi_sck spi_ss}]
set_load 3.0 [get_ports {oc0a_pin oc0b_pin oc1a_pin oc1b_pin oc2a_pin oc2b_pin}]
set_load 1.0 [get_ports {cpu_halted status_reg[*] system_clock_ready mcusr_reg[*]}]

# Drive strength constraints
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_4 [get_ports {reset_ext_n power_on_reset_n}]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [get_ports {portb_pin[*] portc_pin[*] portd_pin[*]}]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [get_ports {uart_rx spi_miso int0_pin int1_pin}]

# False paths for configuration signals
set_false_path -from [get_ports {clock_select[*] clock_prescaler[*] bootloader_enable}]

# Multicycle paths for memory operations
set_multicycle_path 2 -setup -from [get_pins {*flash_controller_inst/*}] -to [get_pins {*instruction_reg*}]
set_multicycle_path 1 -hold -from [get_pins {*flash_controller_inst/*}] -to [get_pins {*instruction_reg*}]

# Multicycle paths for multiplication (2 cycles)
set_multicycle_path 2 -setup -from [get_pins {*alu_inst/multiply*}] -to [get_pins {*multiply_result*}]
set_multicycle_path 1 -hold -from [get_pins {*alu_inst/multiply*}] -to [get_pins {*multiply_result*}]

# Maximum transition constraints
set_max_transition 2.0 [current_design]

# Maximum fanout constraints
set_max_fanout 10 [current_design]

# Maximum capacitance constraints
set_max_capacitance 50.0 [current_design]

# Area constraint (soft)
set_max_area 25000

# Power optimization
set_power_optimization true

# Clock uncertainty (jitter + skew)
set_clock_uncertainty 0.5 [get_clocks clk_ext]
set_clock_uncertainty 2.0 [get_clocks clk_32khz]

# Clock latency (insertion delay)
set_clock_latency 2.0 [get_clocks clk_ext]
set_clock_latency 5.0 [get_clocks clk_32khz]

# Input/Output transition constraints
set_input_transition 1.0 [all_inputs]
set_output_transition 2.0 [all_outputs]

# DFT constraints (if scan chains added)
# set_scan_configuration -style multiplexed_flip_flop

# Group paths for analysis
group_path -name INPUTS -from [all_inputs]
group_path -name OUTPUTS -to [all_outputs]
group_path -name COMBO -from [all_inputs] -to [all_outputs]
group_path -name REGS -from [all_registers] -to [all_registers]