# Magic layout script for AxiomaCore-328
gds read synthesis/axioma_cpu.edif -tech sky130A
save axioma_cpu_layout.mag
gds write axioma_cpu_layout.gds
quit
