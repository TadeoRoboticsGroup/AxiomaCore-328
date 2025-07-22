# Magic script for AxiomaCore-328 physical layout
tech load minimum
box 0 0 1000 1000
paint ndiffusion
box 20 20 980 980
paint polysilicon
box 40 40 960 960
paint metal1
box 100 100 200 200
paint via1
box 80 80 920 920
paint metal2
save axioma_cpu_layout
writeall force axioma_cpu_layout
gds write axioma_cpu_layout.gds
quit
