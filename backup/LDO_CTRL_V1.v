/*
 * Module: LDO_CTRL
 * Version: 4.2 (Final)
 * Description: Digital Controller for Mixed-Signal Power Handover
 */

module ldo_ctrl (
    // System Interface
    input  wire        clk,           // 100MHz System Clock (Core Domain)
    input  wire        rst_n,         // Async Reset, Active Low
    input  wire        start_trig_n,  // Handover Trigger (Active Low)
    output reg         status,        // 0: Busy, 1: Ready/Done

    // SPI Interface (10MHz Domain)
    input  wire        spi_cs_n,
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    output wire        spi_miso,

    // Analog Dynamic Controls
    output reg  [63:0] dldo0_en_n,    // Active Low (0:ON, 1:OFF), Thermometer
    output reg  [63:0] dldo1_en_n,    // Active Low (0:ON, 1:OFF), Thermometer
    output reg  [14:0] aldo_en,       // Active High (Bias Control), Thermometer

    // Analog Static Controls
    output wire [15:0] vref_trim,
    output wire [7:0]  ks0_trim,
    output wire [7:0]  ks1_trim,
    output wire [15:0] r2r_dac_in,
    output wire [2:0]  spare_out
);

    //==========================================================================
    // 1. Clock Domain Crossing (CDC)
    //==========================================================================
    
    // --- 1.1 Trigger Sync (Async -> 100MHz) ---
    reg [1:0] trig_sync;
    reg       trig_debounced;
    reg       trig_debounced_d;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trig_sync <= 2'b11;
            trig_debounced <= 1'b1;
            trig_debounced_d <= 1'b1;
        end else begin
            trig_sync <= {trig_sync[0], start_trig_n};
            // Simple Debounce: Stable for 2 cycles
            if (trig_sync[1] == trig_sync[0]) 
                trig_debounced <= trig_sync[1];
            
            trig_debounced_d <= trig_debounced;
        end
    end
    
    wire trig_falling_edge = (trig_debounced_d == 1'b1) && (trig_debounced == 1'b0);
    wire trig_rising_edge  = (trig_debounced_d == 1'b0) && (trig_debounced == 1'b1);

    // --- 1.2 SPI CDC (10MHz <-> 100MHz) ---
    wire [7:0]  spi_addr_raw;
    wire [31:0] spi_wdata_raw;
    wire        spi_wr_valid_raw;
    reg  [31:0] core_rdata; // Data from Register File to SPI

    spi_slave_interface u_spi_slave (
        .spi_sclk   (spi_sclk),
        .spi_cs_n   (spi_cs_n),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .o_addr     (spi_addr_raw),
        .o_wdata    (spi_wdata_raw),
        .o_wr_valid (spi_wr_valid_raw),
        .i_rdata    (core_rdata)
    );

    // Sync Write Pulse to Core Clock
    reg [2:0] spi_wr_sync;
    wire      reg_write_en;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) spi_wr_sync <= 3'b000;
        else        spi_wr_sync <= {spi_wr_sync[1:0], spi_wr_valid_raw};
    end
    // Rising edge of the synced valid signal triggers write
    assign reg_write_en = spi_wr_sync[1] && !spi_wr_sync[2];

    // Latch Data on Write Enable
    reg [7:0]  reg_addr;
    reg [31:0] reg_wdata;
    always @(posedge clk) begin
        if (reg_write_en) begin
            reg_addr  <= spi_addr_raw;
            reg_wdata <= spi_wdata_raw;
        end
    end

    //==========================================================================
    // 2. Register Map
    //==========================================================================
    // 0x00: HANDOVER_CTRL
    reg [15:0] reg_timer_val;
    reg [1:0]  reg_step_rate;
    reg        reg_fsm_en;

    // 0x04: LDO_INIT_CFG
    reg [1:0]  reg_aldo_target_sel; 
    reg [6:0]  reg_dldo1_init;
    reg [6:0]  reg_dldo0_init;

    // 0x08: ANALOG_STATIC
    reg [2:0]  reg_spare_out;
    reg [15:0] reg_r2r_dac_val;
    reg [3:0]  reg_ks1_trim;
    reg [3:0]  reg_ks0_trim;
    reg [4:0]  reg_vref_trim;

    // Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_timer_val       <= 16'hFFFF;
            reg_step_rate       <= 2'b00;
            reg_fsm_en          <= 1'b0;
            reg_aldo_target_sel <= 2'b00;
            reg_dldo1_init      <= 7'h00;
            reg_dldo0_init      <= 7'h00;
            reg_spare_out       <= 3'h0;
            reg_r2r_dac_val     <= 16'h0;
            reg_ks1_trim        <= 4'h0;
            reg_ks0_trim        <= 4'h0;
            reg_vref_trim       <= 5'h0;
        end else if (reg_write_en) begin
            case (reg_addr)
                8'h00: begin
                    reg_timer_val <= reg_wdata[18:3];
                    reg_step_rate <= reg_wdata[2:1];
                    reg_fsm_en    <= reg_wdata[0];
                end
                8'h04: begin
                    reg_aldo_target_sel <= reg_wdata[15:14];
                    reg_dldo1_init      <= reg_wdata[13:7];
                    reg_dldo0_init      <= reg_wdata[6:0];
                end
                8'h08: begin
                    reg_spare_out   <= reg_wdata[31:29];
                    reg_r2r_dac_val <= reg_wdata[28:13];
                    reg_ks1_trim    <= reg_wdata[12:9];
                    reg_ks0_trim    <= reg_wdata[8:5];
                    reg_vref_trim   <= reg_wdata[4:0];
                end
            endcase
        end
    end

    // Read Logic (Asynchronous Mux to be sampled by SPI domain)
    always @(*) begin
        case (spi_addr_raw) // Use raw addr for faster read access setup
            8'h00: core_rdata = {13'b0, reg_timer_val, reg_step_rate, reg_fsm_en};
            8'h04: core_rdata = {16'b0, reg_aldo_target_sel, reg_dldo1_init, reg_dldo0_init};
            8'h08: core_rdata = {reg_spare_out, reg_r2r_dac_val, reg_ks1_trim, reg_ks0_trim, reg_vref_trim};
            default: core_rdata = 32'h0;
        endcase
    end

    //==========================================================================
    // 3. Static Output Logic
    //==========================================================================
    assign spare_out  = reg_spare_out;
    assign r2r_dac_in = reg_r2r_dac_val;

    // Helper Functions for Thermometer Decoding
    function [15:0] bin2therm_16 (input [4:0] bin);
        integer i;
        begin
            for (i=0; i<16; i=i+1) bin2therm_16[i] = (bin > i);
        end
    endfunction
    
    function [7:0] bin2therm_8 (input [3:0] bin);
        integer i;
        begin
            for (i=0; i<8; i=i+1) bin2therm_8[i] = (bin > i);
        end
    endfunction

    assign ks0_trim  = bin2therm_8(reg_ks0_trim);
    assign ks1_trim  = bin2therm_8(reg_ks1_trim);
    assign vref_trim = bin2therm_16(reg_vref_trim);

    //==========================================================================
    // 4. FSM & Handover Logic
    //==========================================================================
    localparam S_IDLE   = 1'b0;
    localparam S_ACTIVE = 1'b1;
    
    reg current_state;
    reg [15:0] timer_cnt;
    
    // Decode Step Rate
    reg [3:0] step_val;
    always @(*) begin
        case (reg_step_rate)
            2'b00: step_val = 4'd1;
            2'b01: step_val = 4'd2;
            2'b10: step_val = 4'd4;
            2'b11: step_val = 4'd8;
        endcase
    end

    // Decode ALDO Target
    reg [3:0] aldo_target_num;
    always @(*) begin
        case (reg_aldo_target_sel)
            2'b00: aldo_target_num = 4'd0;
            2'b01: aldo_target_num = 4'd5;
            2'b10: aldo_target_num = 4'd10;
            2'b11: aldo_target_num = 4'd15;
        endcase
    end

    // Internal Counters
    reg [6:0] dldo0_int_cnt; 
    reg [6:0] dldo1_int_cnt;
    reg [3:0] aldo_int_cnt;

    // Main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= S_IDLE;
            timer_cnt     <= 16'd0;
            dldo0_int_cnt <= 7'd0;
            dldo1_int_cnt <= 7'd0;
            aldo_int_cnt  <= 4'd0;
            status        <= 1'b1; // Ready
        end else begin
            // Override Conditions
            if (reg_fsm_en == 1'b0 || trig_debounced == 1'b1) begin
                current_state <= S_IDLE;
            end else begin
                case (current_state)
                    S_IDLE: begin
                        // Status: Busy if Trig is Low
                        status <= (trig_debounced == 1'b0) ? 1'b0 : 1'b1;

                        // IDLE Outputs
                        dldo0_int_cnt <= reg_dldo0_init;
                        dldo1_int_cnt <= reg_dldo1_init;
                        aldo_int_cnt  <= 4'd0; // ALDO Bias OFF
                        
                        // Transition to ACTIVE on Falling Edge
                        if (trig_falling_edge && reg_fsm_en) begin
                            timer_cnt     <= reg_timer_val;
                            current_state <= S_ACTIVE;
                            status        <= 1'b0; // Busy
                        end
                    end

                    S_ACTIVE: begin
                        // Exit on Rising Edge
                        if (trig_rising_edge) begin
                             current_state <= S_IDLE;
                        end else begin
                            // Phase 1: Ramping (Timer > 0)
                            if (timer_cnt > 0) begin
                                timer_cnt <= timer_cnt - 1'b1;
                                status    <= 1'b0; // Busy
                                
                                // DLDO Ramp Down
                                if (dldo0_int_cnt > step_val) dldo0_int_cnt <= dldo0_int_cnt - step_val;
                                else dldo0_int_cnt <= 7'd0;

                                if (dldo1_int_cnt > step_val) dldo1_int_cnt <= dldo1_int_cnt - step_val;
                                else dldo1_int_cnt <= 7'd0;

                                // ALDO Bias Control: Direct Set (As per Spec 91 & User Clarification)
                                aldo_int_cnt <= aldo_target_num; 
                            end 
                            // Phase 2: Holding (Timer == 0)
                            else begin
                                timer_cnt <= 16'd0;
                                status    <= 1'b1; // Done/Ready
                                
                                // Force Final State
                                dldo0_int_cnt <= 7'd0;
                                dldo1_int_cnt <= 7'd0;
                                aldo_int_cnt  <= aldo_target_num;
                            end
                        end
                    end
                endcase
            end
        end
    end

    //==========================================================================
    // 5. Dynamic Output Decoding
    //==========================================================================
    
    function [63:0] bin2therm_64 (input [6:0] bin);
        integer i;
        begin
            for (i=0; i<64; i=i+1) bin2therm_64[i] = (bin > i);
        end
    endfunction

    function [14:0] bin2therm_15 (input [3:0] bin);
        integer i;
        begin
            for (i=0; i<15; i=i+1) bin2therm_15[i] = (bin > i);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dldo0_en_n <= {64{1'b1}}; // All OFF (Active Low)
            dldo1_en_n <= {64{1'b1}}; // All OFF (Active Low)
            aldo_en    <= {15{1'b0}}; // All OFF (Active High)
        end else begin
            // DLDO: 0 = ON, 1 = OFF. 
            // Thermometer gives 1s for count. So we Invert.
            dldo0_en_n <= ~bin2therm_64(dldo0_int_cnt);
            dldo1_en_n <= ~bin2therm_64(dldo1_int_cnt);
            
            // ALDO: Active High Bias Control
            aldo_en    <= bin2therm_15(aldo_int_cnt);
        end
    end

endmodule