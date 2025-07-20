// AxiomaCore-328: SPI Controller - Fase 4
// Archivo: axioma_spi.v
// Descripción: Controlador SPI compatible ATmega328P
//              Master/Slave, registros SPCR, SPSR, SPDR
`default_nettype none

module axioma_spi (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Interfaz SPI física
    input wire spi_miso,               // Master In Slave Out (PB4)
    output wire spi_mosi,              // Master Out Slave In (PB3)
    output wire spi_sck,               // Serial Clock (PB5)
    output wire spi_ss,                // Slave Select (PB2)
    
    // Interrupciones
    output wire spi_interrupt,         // Interrupción SPI
    
    // Debug
    output wire [7:0] debug_state,
    output wire [7:0] debug_shift_reg
);

    // Direcciones I/O de registros SPI (ATmega328P compatible)
    localparam ADDR_SPCR = 6'h2C;      // 0x4C - SPI Control Register
    localparam ADDR_SPSR = 6'h2D;      // 0x4D - SPI Status Register
    localparam ADDR_SPDR = 6'h2E;      // 0x4E - SPI Data Register

    // Estados de la máquina SPI
    localparam SPI_IDLE      = 3'b000;
    localparam SPI_START     = 3'b001;
    localparam SPI_TRANSFER  = 3'b010;
    localparam SPI_COMPLETE  = 3'b011;

    // Registros SPI
    reg [7:0] reg_spcr;               // SPI Control Register
    reg [7:0] reg_spsr;               // SPI Status Register
    reg [7:0] reg_spdr;               // SPI Data Register

    // Bits de SPCR
    wire spcr_spie  = reg_spcr[7];    // SPI Interrupt Enable
    wire spcr_spe   = reg_spcr[6];    // SPI Enable
    wire spcr_dord  = reg_spcr[5];    // Data Order (1=LSB first, 0=MSB first)
    wire spcr_mstr  = reg_spcr[4];    // Master/Slave Select (1=Master, 0=Slave)
    wire spcr_cpol  = reg_spcr[3];    // Clock Polarity
    wire spcr_cpha  = reg_spcr[2];    // Clock Phase
    wire [1:0] spcr_spr = reg_spcr[1:0]; // SPI Clock Rate Select

    // Bits de SPSR
    wire spsr_spif  = reg_spsr[7];    // SPI Interrupt Flag
    wire spsr_wcol  = reg_spsr[6];    // Write Collision Flag
    wire spsr_spi2x = reg_spsr[0];    // Double SPI Speed Bit

    // Generador de clock SPI
    reg [7:0] spi_clock_div;
    reg [7:0] spi_clock_counter;
    reg spi_clock_enable;
    wire spi_clock_tick;

    // Máquina de estados SPI
    reg [2:0] spi_state;
    reg [7:0] shift_register;
    reg [3:0] bit_counter;
    reg spi_clock_out;
    reg spi_mosi_out;
    reg spi_ss_out;
    reg transfer_complete;
    reg write_collision;

    // Buffer de datos
    reg [7:0] tx_data;
    reg [7:0] rx_data;
    reg data_ready;
    
    // Slave mode edge detection
    reg spi_sck_prev, spi_ss_prev;
    wire spi_sck_edge, spi_ss_falling;
    
    // Edge detection logic
    assign spi_sck_edge = (spi_sck != spi_sck_prev);
    assign spi_ss_falling = (spi_ss_prev && !spi_ss);

    // Configuración del divisor de clock
    always @(*) begin
        case ({spsr_spi2x, spcr_spr})
            3'b000: spi_clock_div = 8'd4;     // fosc/4
            3'b001: spi_clock_div = 8'd16;    // fosc/16
            3'b010: spi_clock_div = 8'd64;    // fosc/64
            3'b011: spi_clock_div = 8'd128;   // fosc/128
            3'b100: spi_clock_div = 8'd2;     // fosc/2 (2X)
            3'b101: spi_clock_div = 8'd8;     // fosc/8 (2X)
            3'b110: spi_clock_div = 8'd32;    // fosc/32 (2X)
            3'b111: spi_clock_div = 8'd64;    // fosc/64 (2X)
        endcase
    end

    // Generador de clock SPI
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            spi_clock_counter <= 8'h00;
            spi_clock_enable <= 1'b0;
        end else if (spcr_spe && spcr_mstr) begin
            if (spi_clock_counter >= (spi_clock_div - 1)) begin
                spi_clock_counter <= 8'h00;
                spi_clock_enable <= 1'b1;
            end else begin
                spi_clock_counter <= spi_clock_counter + 8'h01;
                spi_clock_enable <= 1'b0;
            end
        end else begin
            spi_clock_counter <= 8'h00;
            spi_clock_enable <= 1'b0;
        end
    end

    assign spi_clock_tick = spi_clock_enable && spcr_spe;

    // Lógica principal SPI
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_spcr <= 8'h00;
            reg_spsr <= 8'h00;
            reg_spdr <= 8'h00;
            
            spi_state <= SPI_IDLE;
            shift_register <= 8'h00;
            bit_counter <= 4'h0;
            spi_clock_out <= 1'b0;
            spi_mosi_out <= 1'b0;
            spi_ss_out <= 1'b1;     // SS idle high
            transfer_complete <= 1'b0;
            write_collision <= 1'b0;
            tx_data <= 8'h00;
            rx_data <= 8'h00;
            data_ready <= 1'b0;
            
        end else begin
            transfer_complete <= 1'b0;
            write_collision <= 1'b0;
            
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_SPCR: begin
                        reg_spcr <= io_data_in;
                    end
                    ADDR_SPSR: begin
                        // Solo algunos bits son escribibles
                        reg_spsr[0] <= io_data_in[0]; // SPI2X
                        // SPIF se limpia leyendo SPSR y luego SPDR
                    end
                    ADDR_SPDR: begin
                        if (spi_state != SPI_IDLE && spcr_spe) begin
                            write_collision <= 1'b1;
                            reg_spsr[6] <= 1'b1; // Set WCOL
                        end else if (spcr_spe) begin
                            reg_spdr <= io_data_in;
                            tx_data <= io_data_in;
                            data_ready <= 1'b1;
                        end
                    end
                endcase
            end
            
            // Lectura de SPDR limpia el flag SPIF
            if (io_read && io_addr == ADDR_SPDR) begin
                reg_spsr[7] <= 1'b0; // Clear SPIF
            end
            
            // Máquina de estados SPI Master/Slave mode
            if (spcr_spe) begin
                if (spcr_mstr) begin
                    // ===== MASTER MODE =====
                    case (spi_state)
                        SPI_IDLE: begin
                            spi_clock_out <= spcr_cpol; // Clock idle state
                            spi_ss_out <= 1'b1;         // SS idle high
                            
                            if (data_ready) begin
                                spi_state <= SPI_START;
                                shift_register <= tx_data;
                                bit_counter <= 4'h0;
                                data_ready <= 1'b0;
                                spi_ss_out <= 1'b0;     // Assert SS
                            end
                        end
                    
                    SPI_START: begin
                        if (spi_clock_tick) begin
                            spi_state <= SPI_TRANSFER;
                            // Setup first bit
                            if (spcr_dord) begin
                                spi_mosi_out <= shift_register[0]; // LSB first
                            end else begin
                                spi_mosi_out <= shift_register[7]; // MSB first
                            end
                        end
                    end
                    
                    SPI_TRANSFER: begin
                        if (spi_clock_tick) begin
                            // Clock phase logic
                            if (!spcr_cpha) begin
                                // CPHA = 0: Sample on first edge, setup on second
                                if (spi_clock_out == spcr_cpol) begin
                                    // First edge - sample MISO
                                    if (spcr_dord) begin
                                        rx_data <= {spi_miso, rx_data[7:1]};
                                    end else begin
                                        rx_data <= {rx_data[6:0], spi_miso};
                                    end
                                    spi_clock_out <= ~spcr_cpol;
                                end else begin
                                    // Second edge - setup MOSI
                                    bit_counter <= bit_counter + 4'h1;
                                    if (bit_counter == 4'h7) begin
                                        spi_state <= SPI_COMPLETE;
                                    end else begin
                                        if (spcr_dord) begin
                                            shift_register <= {1'b0, shift_register[7:1]};
                                            spi_mosi_out <= shift_register[1];
                                        end else begin
                                            shift_register <= {shift_register[6:0], 1'b0};
                                            spi_mosi_out <= shift_register[6];
                                        end
                                    end
                                    spi_clock_out <= spcr_cpol;
                                end
                            end else begin
                                // CPHA = 1: Setup on first edge, sample on second
                                if (spi_clock_out == spcr_cpol) begin
                                    // First edge - setup MOSI
                                    if (bit_counter < 4'h8) begin
                                        if (spcr_dord) begin
                                            spi_mosi_out <= shift_register[0];
                                            shift_register <= {1'b0, shift_register[7:1]};
                                        end else begin
                                            spi_mosi_out <= shift_register[7];
                                            shift_register <= {shift_register[6:0], 1'b0};
                                        end
                                    end
                                    spi_clock_out <= ~spcr_cpol;
                                end else begin
                                    // Second edge - sample MISO
                                    if (spcr_dord) begin
                                        rx_data <= {spi_miso, rx_data[7:1]};
                                    end else begin
                                        rx_data <= {rx_data[6:0], spi_miso};
                                    end
                                    bit_counter <= bit_counter + 4'h1;
                                    if (bit_counter == 4'h7) begin
                                        spi_state <= SPI_COMPLETE;
                                    end
                                    spi_clock_out <= spcr_cpol;
                                end
                            end
                        end
                    end
                    
                        SPI_COMPLETE: begin
                            spi_state <= SPI_IDLE;
                            spi_ss_out <= 1'b1;         // Deassert SS
                            reg_spdr <= rx_data;         // Update data register
                            reg_spsr[7] <= 1'b1;        // Set SPIF
                            transfer_complete <= 1'b1;
                        end
                    endcase
                end else begin
                    // ===== SLAVE MODE =====
                    // Edge detection for slave mode
                    spi_sck_prev <= spi_sck;
                    spi_ss_prev <= spi_ss;
                    
                    case (spi_state)
                        SPI_IDLE: begin
                            if (spi_ss_falling) begin
                                // SS asserted, start transfer
                                spi_state <= SPI_TRANSFER;
                                shift_register <= reg_spdr;  // Load tx data
                                bit_counter <= 4'h0;
                                // Setup first bit immediately (slave outputs on MISO)
                                if (spcr_dord) begin
                                    spi_mosi_out <= reg_spdr[0]; // LSB first
                                end else begin
                                    spi_mosi_out <= reg_spdr[7]; // MSB first
                                end
                            end
                        end
                        
                        SPI_TRANSFER: begin
                            if (spi_ss) begin
                                // SS deasserted, abort transfer
                                spi_state <= SPI_IDLE;
                            end else if (spi_sck_edge) begin
                                // Clock edge detected
                                if (!spcr_cpha) begin
                                    // CPHA = 0: Sample on first edge, setup on second
                                    if ((spi_sck && !spcr_cpol) || (!spi_sck && spcr_cpol)) begin
                                        // Sample edge - read MOSI
                                        if (spcr_dord) begin
                                            rx_data <= {spi_mosi, rx_data[7:1]};
                                        end else begin
                                            rx_data <= {rx_data[6:0], spi_mosi};
                                        end
                                        bit_counter <= bit_counter + 4'h1;
                                        if (bit_counter == 4'h7) begin
                                            spi_state <= SPI_COMPLETE;
                                        end
                                    end else begin
                                        // Setup edge - output next MISO bit
                                        if (bit_counter < 4'h8) begin
                                            if (spcr_dord) begin
                                                shift_register <= {1'b0, shift_register[7:1]};
                                                spi_mosi_out <= shift_register[1];
                                            end else begin
                                                shift_register <= {shift_register[6:0], 1'b0};
                                                spi_mosi_out <= shift_register[6];
                                            end
                                        end
                                    end
                                end else begin
                                    // CPHA = 1: Setup on first edge, sample on second
                                    if ((spi_sck && !spcr_cpol) || (!spi_sck && spcr_cpol)) begin
                                        // Setup edge - output MISO bit
                                        if (bit_counter < 4'h8) begin
                                            if (spcr_dord) begin
                                                spi_mosi_out <= shift_register[0];
                                                shift_register <= {1'b0, shift_register[7:1]};
                                            end else begin
                                                spi_mosi_out <= shift_register[7];
                                                shift_register <= {shift_register[6:0], 1'b0};
                                            end
                                        end
                                    end else begin
                                        // Sample edge - read MOSI
                                        if (spcr_dord) begin
                                            rx_data <= {spi_mosi, rx_data[7:1]};
                                        end else begin
                                            rx_data <= {rx_data[6:0], spi_mosi};
                                        end
                                        bit_counter <= bit_counter + 4'h1;
                                        if (bit_counter == 4'h7) begin
                                            spi_state <= SPI_COMPLETE;
                                        end
                                    end
                                end
                            end
                        end
                        
                        SPI_COMPLETE: begin
                            spi_state <= SPI_IDLE;
                            reg_spdr <= rx_data;         // Update data register
                            reg_spsr[7] <= 1'b1;        // Set SPIF
                            transfer_complete <= 1'b1;
                        end
                    endcase
                end
            end else begin
                // SPI disabled
                spi_state <= SPI_IDLE;
                spi_clock_out <= spcr_cpol;
                spi_ss_out <= 1'b1;
            end
            
            // Update status flags
            if (write_collision) begin
                reg_spsr[6] <= 1'b1; // Set WCOL
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_SPCR: io_data_out = reg_spcr;
                ADDR_SPSR: io_data_out = reg_spsr;
                ADDR_SPDR: io_data_out = reg_spdr;
                default:   io_data_out = 8'h00;
            endcase
        end
    end

    // Salidas SPI
    assign spi_mosi = (spcr_spe && spcr_mstr) ? spi_mosi_out : 1'bz;  // Master outputs on MOSI
    assign spi_sck = (spcr_spe && spcr_mstr) ? spi_clock_out : 1'bz;  // Master controls clock
    assign spi_ss = (spcr_spe && spcr_mstr) ? spi_ss_out : 1'bz;      // Master controls SS
    
    // Note: In slave mode, device should output on MISO pin
    // This requires additional pin mapping in the top-level module

    // Interrupciones
    assign spi_interrupt = spsr_spif && spcr_spie;

    // Debug
    assign debug_state = {spi_state, spcr_spe, spcr_mstr, transfer_complete, write_collision, data_ready};
    assign debug_shift_reg = shift_register;

endmodule

`default_nettype wire