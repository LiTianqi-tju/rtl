module spi_slave_interface (
    // SPI Domain Signals (10MHz)
    input  wire        spi_sclk,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    output reg         spi_miso,

    // Backend Interface (To CDC/Core)
    output reg  [7:0]  o_addr,
    output reg  [31:0] o_wdata,
    output reg         o_wr_valid, // Pulse when write data is ready
    input  wire [31:0] i_rdata     // Data from Core
);

    // SPI Mode 0: CPOL=0, CPHA=0
    // Format: 1-bit R/W (1=Read, 0=Write) + 7-bit Addr + 32-bit Data
    // Shift Order: MSB First

    reg [2:0]  bit_cnt;
    reg [5:0]  byte_cnt;
    reg [39:0] shift_reg; // 8-bit cmd + 32-bit data
    reg        frame_active;
    
    // Read Data Capture (Simplified for slow SPI relative to Core)
    reg [31:0] rdata_latch;

    always @(posedge spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            bit_cnt      <= 3'd7;
            byte_cnt     <= 6'd0;
            frame_active <= 1'b0;
            o_wr_valid   <= 1'b0;
            spi_miso     <= 1'bZ;
            //rdata_latch  <= 32'd0;
            o_addr       <= 8'd0;
            o_wdata      <= 32'd0;
            shift_reg    <= 40'd0;
        end else begin
            frame_active <= 1'b1;
            
            // 1. Shift In (Sample MOSI on Rising Edge)
            shift_reg <= {shift_reg[38:0], spi_mosi};
            
            // 2. Counter Logic
            if (bit_cnt == 0) begin
                bit_cnt  <= 3'd7;
                byte_cnt <= byte_cnt + 1'b1;
            end else begin
                bit_cnt  <= bit_cnt - 1'b1;
            end

            // 3. Command Parsing & Write Strobe
            // End of 1st byte (Command/Addr)
            if (byte_cnt == 0 && bit_cnt == 0) begin
                o_addr <= {shift_reg[5:0], spi_mosi}; // Capture Address
                // If Read Command (Bit 7 is 1), Latch data
                if (shift_reg[6] == 1'b1) begin // R/W bit is currently on MOSI
                    rdata_latch <= i_rdata; 
                end
            end
            
            // End of Frame (40th bit) - Write Execution
            if (byte_cnt == 4 && bit_cnt == 0) begin
                if (shift_reg[38] == 1'b0) begin // Write Command
                   o_wdata    <= {shift_reg[30:0], spi_mosi};
                   o_wr_valid <= 1'b1;
                end
            end else begin
                o_wr_valid <= 1'b0;
            end
        end
    end

    // MISO Generation (Launch on Falling Edge)
    always @(negedge spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            spi_miso <= 1'bZ;
        end else begin
            // If Read Command detected (Byte 0 processed), shift out rdata_latch
            // First bit of data corresponds to shift_reg[31] position logically
            if (byte_cnt >= 1) begin
                // Simple serializer for read data
                // Note: bit_cnt and byte_cnt logic needs careful alignment for MISO
                // This is a behavioral simplification. 
                // In exact timing: Byte 1, Bit 7 corresponds to rdata_latch[31]
                case (bit_cnt)
                    3'd7: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 7 ];
                    3'd6: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 6 ];
                    3'd5: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 5 ];
                    3'd4: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 4 ];
                    3'd3: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 3 ];
                    3'd2: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 2 ];
                    3'd1: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 1 ];
                    3'd0: spi_miso <= rdata_latch[ (4-byte_cnt)*8 + 0 ];
                endcase
            end else begin
                spi_miso <= 1'b0; // Default when not reading data
            end
        end
    end

endmodule