// AxiomaCore-328: I2C/TWI Controller - Fase 4
// Archivo: axioma_i2c.v
// Descripción: Controlador I2C/TWI compatible ATmega328P
//              Master/Slave, registros TWCR, TWSR, TWDR, TWAR, TWBR
`default_nettype none

module axioma_i2c (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Interfaz I2C física
    inout wire sda,                    // Serial Data (PC4)
    inout wire scl,                    // Serial Clock (PC5)
    
    // Interrupciones
    output wire twi_interrupt,         // Interrupción I2C/TWI
    
    // Debug
    output wire [7:0] debug_state,
    output wire [7:0] debug_data
);

    // Direcciones I/O de registros I2C (ATmega328P compatible)
    localparam ADDR_TWBR = 6'h00;      // 0xB8 - TWI Bit Rate Register
    localparam ADDR_TWSR = 6'h01;      // 0xB9 - TWI Status Register
    localparam ADDR_TWAR = 6'h02;      // 0xBA - TWI (Slave) Address Register
    localparam ADDR_TWDR = 6'h03;      // 0xBB - TWI Data Register
    localparam ADDR_TWCR = 6'h36;      // 0xBC - TWI Control Register

    // Estados I2C
    localparam TWI_IDLE           = 5'h00;
    localparam TWI_START          = 5'h08;
    localparam TWI_REP_START      = 5'h10;
    localparam TWI_MT_SLA_ACK     = 5'h18;  // Master Transmit Slave Address ACK
    localparam TWI_MT_SLA_NACK    = 5'h20;  // Master Transmit Slave Address NACK
    localparam TWI_MT_DATA_ACK    = 5'h28;  // Master Transmit Data ACK
    localparam TWI_MT_DATA_NACK   = 5'h30;  // Master Transmit Data NACK
    localparam TWI_MR_SLA_ACK     = 5'h40;  // Master Receive Slave Address ACK
    localparam TWI_MR_SLA_NACK    = 5'h48;  // Master Receive Slave Address NACK
    localparam TWI_MR_DATA_ACK    = 5'h50;  // Master Receive Data ACK
    localparam TWI_MR_DATA_NACK   = 5'h58;  // Master Receive Data NACK
    localparam TWI_SR_SLA_ACK     = 5'h60;  // Slave Receive Own Address ACK
    localparam TWI_ST_SLA_ACK     = 5'hA8;  // Slave Transmit Address ACK
    localparam TWI_BUS_ERROR      = 5'h00;  // Bus Error

    // Registros I2C
    reg [7:0] reg_twbr;               // Bit Rate Register
    reg [7:0] reg_twsr;               // Status Register
    reg [7:0] reg_twar;               // Address Register
    reg [7:0] reg_twdr;               // Data Register
    reg [7:0] reg_twcr;               // Control Register

    // Bits de TWCR
    wire twcr_twint = reg_twcr[7];    // TWI Interrupt Flag
    wire twcr_twea  = reg_twcr[6];    // TWI Enable Acknowledge
    wire twcr_twsta = reg_twcr[5];    // TWI Start Condition
    wire twcr_twsto = reg_twcr[4];    // TWI Stop Condition
    wire twcr_twwc  = reg_twcr[3];    // TWI Write Collision
    wire twcr_twen  = reg_twcr[2];    // TWI Enable
    wire twcr_twie  = reg_twcr[0];    // TWI Interrupt Enable

    // Bits de TWSR
    wire [4:0] twsr_tws = reg_twsr[7:3]; // TWI Status
    wire [1:0] twsr_twps = reg_twsr[1:0]; // TWI Prescaler

    // Generador de clock I2C
    reg [7:0] scl_clock_div;
    reg [7:0] scl_clock_counter;
    reg scl_clock_enable;
    wire scl_tick;

    // Estados internos
    reg [4:0] twi_state;
    reg [7:0] shift_register;
    reg [3:0] bit_counter;
    reg sda_out, scl_out;
    reg sda_oe, scl_oe;              // Output enable
    reg start_condition, stop_condition;
    reg ack_received, ack_to_send;
    reg data_ready;
    reg interrupt_flag;

    // Buffer de datos
    reg [7:0] tx_data, rx_data;

    // Configuración del divisor de clock I2C
    always @(*) begin
        case (twsr_twps)
            2'b00: scl_clock_div = reg_twbr;           // TWBR
            2'b01: scl_clock_div = reg_twbr << 2;      // 4 * TWBR
            2'b10: scl_clock_div = reg_twbr << 4;      // 16 * TWBR
            2'b11: scl_clock_div = reg_twbr << 6;      // 64 * TWBR
        endcase
    end

    // Generador de clock I2C
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            scl_clock_counter <= 8'h00;
            scl_clock_enable <= 1'b0;
        end else if (twcr_twen) begin
            if (scl_clock_counter >= scl_clock_div) begin
                scl_clock_counter <= 8'h00;
                scl_clock_enable <= 1'b1;
            end else begin
                scl_clock_counter <= scl_clock_counter + 8'h01;
                scl_clock_enable <= 1'b0;
            end
        end else begin
            scl_clock_counter <= 8'h00;
            scl_clock_enable <= 1'b0;
        end
    end

    assign scl_tick = scl_clock_enable && twcr_twen;

    // Lógica principal I2C
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_twbr <= 8'h00;
            reg_twsr <= 8'hF8;           // Status inicial
            reg_twar <= 8'hFE;           // Address + General Call disable
            reg_twdr <= 8'h00;
            reg_twcr <= 8'h00;
            
            twi_state <= TWI_IDLE;
            shift_register <= 8'h00;
            bit_counter <= 4'h0;
            sda_out <= 1'b1;
            scl_out <= 1'b1;
            sda_oe <= 1'b0;
            scl_oe <= 1'b0;
            start_condition <= 1'b0;
            stop_condition <= 1'b0;
            ack_received <= 1'b0;
            ack_to_send <= 1'b0;
            data_ready <= 1'b0;
            interrupt_flag <= 1'b0;
            tx_data <= 8'h00;
            rx_data <= 8'h00;
            
        end else begin
            start_condition <= 1'b0;
            stop_condition <= 1'b0;
            interrupt_flag <= 1'b0;
            
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_TWBR: reg_twbr <= io_data_in;
                    ADDR_TWSR: begin
                        // Solo prescaler es escribible
                        reg_twsr[1:0] <= io_data_in[1:0];
                    end
                    ADDR_TWAR: reg_twar <= io_data_in;
                    ADDR_TWDR: begin
                        reg_twdr <= io_data_in;
                        tx_data <= io_data_in;
                        data_ready <= 1'b1;
                    end
                    ADDR_TWCR: begin
                        // Clear TWINT by writing 1
                        if (io_data_in[7]) begin
                            reg_twcr[7] <= 1'b0;
                        end
                        reg_twcr[6:0] <= io_data_in[6:0];
                        
                        // Detect start/stop commands
                        if (io_data_in[5] && twcr_twen) begin
                            start_condition <= 1'b1;
                        end
                        if (io_data_in[4] && twcr_twen) begin
                            stop_condition <= 1'b1;
                        end
                    end
                endcase
            end
            
            // Máquina de estados I2C
            if (twcr_twen) begin
                case (twi_state)
                    TWI_IDLE: begin
                        sda_oe <= 1'b0;
                        scl_oe <= 1'b0;
                        
                        if (start_condition) begin
                            twi_state <= TWI_START;
                            sda_oe <= 1'b1;
                            scl_oe <= 1'b1;
                            sda_out <= 1'b0;        // Start condition
                            scl_out <= 1'b0;
                            reg_twsr[7:3] <= TWI_START;
                            interrupt_flag <= 1'b1;
                        end
                    end
                    
                    TWI_START: begin
                        if (data_ready && scl_tick) begin
                            twi_state <= TWI_MT_SLA_ACK;
                            shift_register <= tx_data;
                            bit_counter <= 4'h0;
                            data_ready <= 1'b0;
                        end
                    end
                    
                    TWI_MT_SLA_ACK: begin
                        if (scl_tick) begin
                            if (bit_counter < 4'h8) begin
                                // Transmit address bits
                                sda_out <= shift_register[7];
                                shift_register <= {shift_register[6:0], 1'b0};
                                bit_counter <= bit_counter + 4'h1;
                                scl_out <= ~scl_out;
                            end else begin
                                // Check ACK
                                sda_oe <= 1'b0;         // Release SDA for ACK
                                if (!sda) begin         // ACK received
                                    ack_received <= 1'b1;
                                    if (tx_data[0]) begin // Read bit set
                                        twi_state <= TWI_MR_SLA_ACK;
                                        reg_twsr[7:3] <= TWI_MR_SLA_ACK;
                                    end else begin       // Write operation
                                        twi_state <= TWI_MT_DATA_ACK;
                                        reg_twsr[7:3] <= TWI_MT_SLA_ACK;
                                    end
                                end else begin          // NACK received
                                    twi_state <= TWI_MT_SLA_NACK;
                                    reg_twsr[7:3] <= TWI_MT_SLA_NACK;
                                end
                                interrupt_flag <= 1'b1;
                                sda_oe <= 1'b1;
                            end
                        end
                    end
                    
                    TWI_MT_DATA_ACK: begin
                        if (data_ready && scl_tick) begin
                            if (bit_counter < 4'h8) begin
                                // Transmit data bits
                                sda_out <= shift_register[7];
                                shift_register <= {shift_register[6:0], 1'b0};
                                bit_counter <= bit_counter + 4'h1;
                                scl_out <= ~scl_out;
                            end else begin
                                // Check ACK
                                sda_oe <= 1'b0;
                                if (!sda) begin
                                    reg_twsr[7:3] <= TWI_MT_DATA_ACK;
                                end else begin
                                    reg_twsr[7:3] <= TWI_MT_DATA_NACK;
                                end
                                interrupt_flag <= 1'b1;
                                data_ready <= 1'b0;
                                bit_counter <= 4'h0;
                                sda_oe <= 1'b1;
                            end
                        end
                    end
                    
                    TWI_MR_DATA_ACK: begin
                        if (scl_tick) begin
                            if (bit_counter < 4'h8) begin
                                // Receive data bits
                                scl_out <= ~scl_out;
                                if (scl_out) begin      // Rising edge
                                    rx_data <= {rx_data[6:0], sda};
                                    bit_counter <= bit_counter + 4'h1;
                                end
                            end else begin
                                // Send ACK/NACK
                                sda_oe <= 1'b1;
                                sda_out <= ~twcr_twea;  // ACK if TWEA=1
                                reg_twdr <= rx_data;
                                reg_twsr[7:3] <= twcr_twea ? TWI_MR_DATA_ACK : TWI_MR_DATA_NACK;
                                interrupt_flag <= 1'b1;
                                bit_counter <= 4'h0;
                            end
                        end
                    end
                    
                    default: begin
                        if (stop_condition) begin
                            twi_state <= TWI_IDLE;
                            sda_oe <= 1'b1;
                            scl_oe <= 1'b1;
                            sda_out <= 1'b0;
                            scl_out <= 1'b1;
                            #1 sda_out <= 1'b1;     // Stop condition
                            reg_twsr[7:3] <= 5'hF8; // No state info
                        end
                    end
                endcase
            end else begin
                // I2C disabled
                twi_state <= TWI_IDLE;
                sda_oe <= 1'b0;
                scl_oe <= 1'b0;
            end
            
            // Update interrupt flag
            if (interrupt_flag) begin
                reg_twcr[7] <= 1'b1;
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_TWBR: io_data_out = reg_twbr;
                ADDR_TWSR: io_data_out = reg_twsr;
                ADDR_TWAR: io_data_out = reg_twar;
                ADDR_TWDR: io_data_out = reg_twdr;
                ADDR_TWCR: io_data_out = reg_twcr;
                default:   io_data_out = 8'h00;
            endcase
        end
    end

    // Salidas I2C (open drain)
    assign sda = sda_oe ? (sda_out ? 1'bz : 1'b0) : 1'bz;
    assign scl = scl_oe ? (scl_out ? 1'bz : 1'b0) : 1'bz;

    // Interrupciones
    assign twi_interrupt = twcr_twint && twcr_twie;

    // Debug
    assign debug_state = {twi_state, sda_oe, scl_oe, sda_out};
    assign debug_data = shift_register;

endmodule

`default_nettype wire