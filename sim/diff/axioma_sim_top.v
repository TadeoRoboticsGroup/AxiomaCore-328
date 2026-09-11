// AxiomaCore-328 - top de simulación para la co-simulación diferencial
// SPDX-License-Identifier: Apache-2.0
//
// NO forma parte del diseño. Cablea el núcleo con el bus, las memorias y los
// periféricos que ya existen, y añade un puerto de carga de programa que sólo
// existe en simulación.
//
// CÓMO CRECE ESTE FICHERO. Cada periférico que aterriza se enchufa aquí y deja
// de estar cubierto por el array de I/O plano. Ese array es el relleno: modela
// como memoria normal todo lo que todavía no tiene periférico de verdad, para
// que los programas de prueba puedan usar direcciones libres —los GPIOR— sin
// que el contraste contra simavr se rompa.
//
// Los programas de prueba deben seguir EVITANDO los periféricos que simavr
// modela y aquí todavía no existen. Ahora mismo ya existen de verdad los tres
// puertos de E/S, el Timer0 con su prescaler y el controlador de
// interrupciones; SPL, SPH y SREG los intercepta axioma_core antes del bus.
//
// EL TIMER0 NO SE COMPARA CONTRA EL DE simavr, y es deliberado. simavr no
// cuenta ciclo a ciclo: interpola TCNT0 desde `avr->cycle` y ancla su base en
// el ciclo en que se escribe TCCR0B, con lo que su cuenta va desfasada
// respecto de un prescaler libre de verdad. Aquí el reparto es el de la
// estrategia por capas: CUÁNDO salta la interrupción lo decide el RTL y lo
// verifica el banco propio contra la hoja de datos; QUÉ hace el núcleo al
// saltar lo verifica simavr, al que el arnés le levanta el mismo vector.
//
// MODELO DE PAD. Sin nada conectado por fuera:
//   - un pin de SALIDA se lee a sí mismo;
//   - uno de ENTRADA con el pull-up activado (su bit de PORTx a 1) se lee 1,
//     que es lo que hace un chip real;
//   - uno de entrada sin pull-up queda flotando y se modela como 0.
// Las tres cosas juntas equivalen a que el pad siga a PORTx, pero se escriben
// por separado porque el motivo de cada una es distinto y en la FPGA se
// traducen a bits distintos del bloque de E/S.

`default_nettype none

module axioma_sim_top (
    input  wire        clk,
    input  wire        rst_n,

    // Carga de programa, solo simulación
    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    // Observación
    output wire [13:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire        dbg_retire,
    output wire        dbg_illegal,
    output wire        dbg_irq_entry,
    output wire [4:0]  dbg_irq_vector,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_sreg,
    input  wire [4:0]  dbg_reg_addr,
    output wire [7:0]  dbg_reg_data,
    input  wire [15:0] dbg_mem_addr,
    output wire [7:0]  dbg_mem_data
);

    localparam [15:0] IO_BASE   = 16'h0020;
    localparam [15:0] SRAM_BASE = 16'h0100;
    localparam [15:0] SRAM_END  = 16'h08FF;

    // ----------------------------------------------------- memoria de programa
    wire [13:0] c_pm_if_addr, c_pm_d_addr;
    wire        c_pm_if_en, c_pm_d_en, c_pm_d_we;
    wire [15:0] c_pm_d_wdata, pm_if_data, pm_d_rdata;

    axioma_progmem pm (
        .clk(clk),
        .if_addr(c_pm_if_addr), .if_en(c_pm_if_en), .if_data(pm_if_data),
        .d_addr(prog_we ? prog_addr : c_pm_d_addr),
        .d_en(prog_we | c_pm_d_en),
        .d_we(prog_we | c_pm_d_we),
        .d_wdata(prog_we ? prog_data : c_pm_d_wdata),
        .d_rdata(pm_d_rdata)
    );

    // ------------------------------------------------------ núcleo y bus
    wire [15:0] dm_addr;
    wire        dm_re, dm_we;
    wire [7:0]  dm_wdata, dm_rdata;

    wire [10:0] sram_addr;
    wire        sram_en, sram_we;
    wire [7:0]  sram_wdata, sram_rdata;

    wire [7:0]  io_addr;
    wire        io_re, io_we;
    wire [7:0]  io_wdata, io_rdata;
    wire        io_sel;

    axioma_dbus bus (
        .clk(clk), .rst_n(rst_n),
        .addr(dm_addr), .re(dm_re), .we(dm_we), .wdata(dm_wdata), .rdata(dm_rdata),
        .sram_addr(sram_addr), .sram_en(sram_en), .sram_we(sram_we),
        .sram_wdata(sram_wdata), .sram_rdata(sram_rdata),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_sel(io_sel)
    );

    axioma_dmem dm (
        .clk(clk), .addr(sram_addr), .en(sram_en), .we(sram_we),
        .wdata(sram_wdata), .rdata(sram_rdata)
    );

    // ------------------------------------------------------ puertos de E/S
    wire [7:0] gb_rd, gc_rd, gd_rd;
    wire       gb_sel, gc_sel, gd_sel;
    wire [7:0] gb_out, gb_oe, gb_pu, gc_out, gc_oe, gc_pu, gd_out, gd_oe, gd_pu;

    wire [7:0] pb_in = (gb_out & gb_oe) | (gb_pu & ~gb_oe);
    wire [7:0] pc_in = (gc_out & gc_oe) | (gc_pu & ~gc_oe);
    wire [7:0] pd_in = (gd_out & gd_oe) | (gd_pu & ~gd_oe);

    axioma_gpio #(.IO_PIN(8'h03), .BITS(8'hFF)) gpio_b (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gb_rd), .io_sel(gb_sel),
        .pad_in(pb_in), .pad_out(gb_out), .pad_oe(gb_oe), .pad_pullup(gb_pu)
    );
    // El puerto C sólo tiene siete bits: PC7 no existe en el encapsulado.
    axioma_gpio #(.IO_PIN(8'h06), .BITS(8'h7F)) gpio_c (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gc_rd), .io_sel(gc_sel),
        .pad_in(pc_in), .pad_out(gc_out), .pad_oe(gc_oe), .pad_pullup(gc_pu)
    );
    axioma_gpio #(.IO_PIN(8'h09), .BITS(8'hFF)) gpio_d (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gd_rd), .io_sel(gd_sel),
        .pad_in(pd_in), .pad_out(gd_out), .pad_oe(gd_oe), .pad_pullup(gd_pu)
    );

    // ------------------------------------------ Timer0 y su prescaler
    // El prescaler es compartido —trampa nº 12— y por eso es un módulo aparte:
    // en la fase 3 el Timer1 se engancha al MISMO contador.
    wire tick_1, tick_8, tick_64, tick_256, tick_1024;
    wire [7:0] ps_rd, tm_rd;
    wire       ps_sel, tm_sel;
    wire       tm_ovf, tm_compa, tm_compb;
    wire       ack_ovf, ack_compa, ack_compb;

    axioma_prescaler presc (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ps_rd), .io_sel(ps_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        /* verilator lint_off PINCONNECTEMPTY */
        .count()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // OC0A (PD6) y OC0B (PD5) se quedan sin encaminar hasta la fase 3, que es
    // donde el plan pone los seis canales PWM: para llevarlos al pad hay que
    // tocar axioma_gpio y darle una entrada de anulación. Lo que SÍ está
    // verificado ya es la lógica que los genera, en sim/periph/tb_timer0.cpp.
    axioma_timer0 timer0 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(tm_rd), .io_sel(tm_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        .t0_pin(pd_in[4]),                       // T0 es PD4
        /* verilator lint_off PINCONNECTEMPTY */
        .oc0a(), .oc0a_en(), .oc0b(), .oc0b_en(),
        /* verilator lint_on PINCONNECTEMPTY */
        .irq_ovf(tm_ovf), .irq_compa(tm_compa), .irq_compb(tm_compb),
        .ack_ovf(ack_ovf), .ack_compa(ack_compa), .ack_compb(ack_compb)
    );

    // ------------------------------------------ controlador de interrupciones
    // Los vectores cuyo periférico todavía no existe van atados a cero. El
    // controlador no los distingue: se verifican los 26 en su banco propio.
    wire [25:0] irq_src;
    wire [25:0] irq_ack_v;
    wire        core_irq_req, core_irq_ack;
    wire [4:0]  core_irq_vector;

    // Los anchos de esta concatenación SON el mapa de vectores: 9 + 3 + 14 = 26.
    // Con un bit de más abajo, TIMER0_COMPA se convierte en TIMER1_OVF y el
    // núcleo salta a un vector que no es. Lo destapó irq_timer0.S en su primera
    // ejecución, saltando a la palabra 0x1A en vez de a la 0x1C.
    assign irq_src = { 9'b0,          // 25..17: SPI en adelante, sin periférico
                       tm_ovf,        // 16 TIMER0_OVF
                       tm_compb,      // 15 TIMER0_COMPB
                       tm_compa,      // 14 TIMER0_COMPA
                       14'b0 };       // 13..0: Timer1, Timer2, PCINT, INT, RESET

    // Los reconocimientos de los vectores sin periférico no van a ninguna
    // parte, igual que sus peticiones: se declaran sin usar a propósito.
    wire unused_ack = &{1'b0, irq_ack_v[25:17], irq_ack_v[13:0]};

    assign ack_compa = irq_ack_v[14];
    assign ack_compb = irq_ack_v[15];
    assign ack_ovf   = irq_ack_v[16];

    axioma_irq irqc (
        .src(irq_src),
        .irq_req(core_irq_req), .irq_vector(core_irq_vector),
        .irq_ack(core_irq_ack), .ack(irq_ack_v)
    );

    // El vector que se atendió, retenido para el arnés: durante los cuatro
    // ciclos de la entrada la petición ya ha desaparecido, porque el
    // reconocimiento limpia la bandera en el primero.
    reg [4:0] irq_vec_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             irq_vec_q <= 5'd0;
        else if (core_irq_ack)  irq_vec_q <= core_irq_vector;
    end
    assign dbg_irq_vector = irq_vec_q;

    wire periph_sel = gb_sel | gc_sel | gd_sel | ps_sel | tm_sel;

    // ------------------------------------------ relleno: I/O plana, 224 bytes
    // Sólo responde donde no hay periférico de verdad.
    reg  [7:0] io [0:223];
    reg  [7:0] flat_rdata;
    reg        flat_sel_q;
    integer i;
    initial for (i = 0; i < 224; i = i + 1) io[i] = 8'h00;

    wire flat_hit = ~periph_sel;

    always @(negedge clk) begin
        if (flat_hit && (io_re || io_we)) begin
            if (io_we) begin
                io[io_addr] <= io_wdata;
                flat_rdata  <= io_wdata;
            end else begin
                flat_rdata <= io[io_addr];
            end
        end
    end
    always @(negedge clk) if (io_re) flat_sel_q <= flat_hit;

    // Cada fuente deja su lectura a cero cuando no le toca, y se combinan.
    assign io_rdata = (periph_sel ? (gb_rd | gc_rd | gd_rd | ps_rd | tm_rd) : 8'h00)
                    | (flat_sel_q ? flat_rdata : 8'h00);
    // El relleno reclama todo lo que no reclama un periférico, de modo que en
    // la fase 2 el espacio de I/O sigue estando completo.
    assign io_sel = 1'b1;

    // ------------------------------------------------------------- núcleo
    axioma_core core (
        .clk(clk), .rst_n(rst_n),
        .pm_if_addr(c_pm_if_addr), .pm_if_en(c_pm_if_en), .pm_if_data(pm_if_data),
        .pm_d_addr(c_pm_d_addr), .pm_d_en(c_pm_d_en), .pm_d_we(c_pm_d_we),
        .pm_d_wdata(c_pm_d_wdata), .pm_d_rdata(pm_d_rdata),
        .dm_addr(dm_addr), .dm_re(dm_re), .dm_we(dm_we),
        .dm_wdata(dm_wdata), .dm_rdata(dm_rdata),
        .irq_req(core_irq_req), .irq_vector(core_irq_vector), .irq_ack(core_irq_ack),
        .dbg_pc(dbg_pc), .dbg_ir(dbg_ir), .dbg_retire(dbg_retire),
        .dbg_illegal(dbg_illegal), .dbg_irq_entry(dbg_irq_entry),
        .dbg_sp(dbg_sp), .dbg_sreg(dbg_sreg),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data)
    );

    // ---------------- lectura de observación, sin perturbar al núcleo -------
    wire [7:0] dbg_io_index = dbg_mem_addr[7:0] - IO_BASE[7:0];
    wire       dbg_in_io    = (dbg_mem_addr >= IO_BASE) && (dbg_mem_addr < SRAM_BASE);

    // Los registros de los tres puertos hay que leerlos de su periférico, no
    // del relleno: ahí ya no está su estado.
    reg [7:0] dbg_periph;
    always @(*) begin
        case (dbg_io_index)
            8'h03:   dbg_periph = gpio_b.sync1;
            8'h04:   dbg_periph = gpio_b.ddr_q;
            8'h05:   dbg_periph = gpio_b.port_q;
            8'h06:   dbg_periph = gpio_c.sync1;
            8'h07:   dbg_periph = gpio_c.ddr_q;
            8'h08:   dbg_periph = gpio_c.port_q;
            8'h09:   dbg_periph = gpio_d.sync1;
            8'h0A:   dbg_periph = gpio_d.ddr_q;
            8'h0B:   dbg_periph = gpio_d.port_q;
            8'h15:   dbg_periph = {5'b0, timer0.tifr_q};
            8'h23:   dbg_periph = {presc.tsm_q, 5'b0, presc.psrasy_q, presc.psrsync_q};
            8'h24:   dbg_periph = {timer0.com_q, 2'b00, timer0.wgm_q[1:0]};
            8'h25:   dbg_periph = {4'b0000, timer0.wgm_q[2], timer0.cs_q};
            8'h26:   dbg_periph = timer0.tcnt_q;
            8'h27:   dbg_periph = timer0.ocra_buf;
            8'h28:   dbg_periph = timer0.ocrb_buf;
            8'h4E:   dbg_periph = {5'b0, timer0.timsk_q};
            default: dbg_periph = io[dbg_io_index];
        endcase
    end

    assign dbg_mem_data =
        (dbg_mem_addr >= SRAM_BASE && dbg_mem_addr <= SRAM_END)
            ? dm.mem[dbg_mem_addr[10:0] - SRAM_BASE[10:0]]
        : dbg_in_io ? dbg_periph
        : 8'h00;

endmodule

`default_nettype wire
