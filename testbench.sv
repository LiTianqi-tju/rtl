`timescale 1ns / 100ps

module tb_ldo_ctrl;

    //==========================================================================
    // 1. Signals & Parameters 
    //==========================================================================
    // System Interface
    logic        clk;           
    logic        rst_n;         
    logic        start_trig_n;  
    logic        status;        

    // SPI Interface
    logic        spi_cs_n;      
    logic        spi_sclk;      
    logic        spi_mosi;      
    logic        spi_miso;      

    // Analog Controls (Outputs from DUT)
    logic [63:0] dldo0_en_n;    
    logic [63:0] dldo1_en_n;
    logic [14:0] aldo_en;
    logic [15:0] vref_trim;
    logic [7:0]  ks0_trim;
    logic [7:0]  ks1_trim;
    logic [15:0] r2r_dac_in;
    logic [2:0]  spare_out;

    // Clock Periods
    parameter CLK_PERIOD = 10;   // 100MHz Core Clock
    parameter SPI_PERIOD = 100;  // 10MHz SPI Clock

    // Register Map Addresses
    parameter ADDR_CTRL   = 8'h00;
    parameter ADDR_INIT   = 8'h04;
    parameter ADDR_STATIC = 8'h08;

    //==========================================================================
    // 2. DUT Instantiation
    //==========================================================================
    ldo_ctrl u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start_trig_n  (start_trig_n),
        .status        (status),
        .spi_cs_n      (spi_cs_n),
        .spi_sclk      (spi_sclk),
        .spi_mosi      (spi_mosi),
        .spi_miso      (spi_miso),
        .dldo0_en_n    (dldo0_en_n),
        .dldo1_en_n    (dldo1_en_n),
        .aldo_en       (aldo_en),
        .vref_trim     (vref_trim),
        .ks0_trim      (ks0_trim),
        .ks1_trim      (ks1_trim),
        .r2r_dac_in    (r2r_dac_in),
        .spare_out     (spare_out)
    );

    //==========================================================================
    // 3. Clock Generation
    //==========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    //==========================================================================
    // 4. SPI Master Model (Tasks using logic)
    //==========================================================================
    
    // Task: SPI Write
    task spi_write(input logic [7:0] addr, input logic [31:0] data);
        integer i;
        logic [39:0] tx_frame; 
        begin
            // 1-bit Write (0) + 7-bit Addr + 32-bit Data
            tx_frame = {1'b0, addr[6:0], data}; 
            
            @(negedge clk); 
            spi_cs_n = 0;
            #(SPI_PERIOD/2); // Setup time

            for(i=39; i>=0; i=i-1) begin
                spi_mosi = tx_frame[i];
                #(SPI_PERIOD/2); 
                spi_sclk = 1; // Rising Edge (DUT Samples)
                #(SPI_PERIOD/2); 
                spi_sclk = 0; // Falling Edge (Shift)
            end
            
            #(SPI_PERIOD/2);
            spi_cs_n = 1;
            spi_mosi = 0;
            repeat(5) @(posedge clk);
        end
    endtask

    // Task: SPI Read
    task spi_read(input logic [7:0] addr, output logic [31:0] data);
        integer i;
        logic [7:0] cmd_byte; 
        begin
            // 1-bit Read (1) + 7-bit Addr
            cmd_byte = {1'b1, addr[6:0]};
            
            spi_cs_n = 0;
            #(SPI_PERIOD/2);

            // Shift Out Command
            for(i=7; i>=0; i=i-1) begin
                spi_mosi = cmd_byte[i];
                #(SPI_PERIOD/2); spi_sclk = 1; 
                #(SPI_PERIOD/2); spi_sclk = 0; 
            end
            
            spi_mosi = 0; // Release MOSI

            // Shift In Data
            for(i=31; i>=0; i=i-1) begin
                #(SPI_PERIOD/2); spi_sclk = 1; // Sample MISO
                data[i] = spi_miso;
                #(SPI_PERIOD/2); spi_sclk = 0; 
            end

            #(SPI_PERIOD/2);
            spi_cs_n = 1;
        end
    endtask

    //==========================================================================
    // 5. Main Test Sequence
    //==========================================================================
    logic [31:0] read_val; 

    initial begin
        $fsdbDumpfile("tb_ldo_ctrl.fsdb");
        $fsdbDumpvars(0, tb_ldo_ctrl);
        $fsdbDumpMDA();
        // Setup Waveform Dump
        $dumpfile("ldo_ctrl_test.vcd");
        $dumpvars(0, tb_ldo_ctrl);

        // ------------------------------------------------------------
        // CASE 0: Initialization
        // ------------------------------------------------------------
        $display("\n=== [TEST START] Initializing... ===");
        rst_n = 0;
        start_trig_n = 1;
        spi_cs_n = 1;
        spi_sclk = 0;
        spi_mosi = 0;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);

        // ------------------------------------------------------------
        // CASE 1: Register R/W & Address Decoding
        // ------------------------------------------------------------
        $display("=== [CASE 1] SPI Register Read/Write Test ===");
        
        // Write to ANALOG_STATIC (0x08)
        spi_write(ADDR_STATIC, 32'h0000_0425);
        $display("Write 0x08 Done.");

        // Read Back
        spi_read(ADDR_STATIC, read_val);
        if (read_val === 32'h0000_0425) 
            $display(">> PASS: Reg 0x08 Readback Match: %h", read_val);
        else 
            $error(">> FAIL: Reg 0x08 Readback Mismatch! Exp: 0425, Got: %h", read_val);

        // Check Static Output Pins (Thermometer Decoding)
        #100;
        if (vref_trim === 16'h001F) $display(">> PASS: VREF_TRIM Decoding Correct.");
        else $error(">> FAIL: VREF_TRIM Decoding Error. Got %b", vref_trim);


        // ------------------------------------------------------------
        // CASE 2: Handover Configuration (IDLE State)
        // ------------------------------------------------------------
        $display("\n=== [CASE 2] Configuring for Handover ===");
        
        // 1. Configure Init Vals (0x04)
        spi_write(ADDR_INIT, 32'h0000_8A1E);

        // 2. Configure Control (0x00)
        spi_write(ADDR_CTRL, 32'h0000_0193);

        #200;
        // Check IDLE Outputs
        if (dldo0_en_n[0] == 0 && dldo0_en_n[29] == 0 && dldo0_en_n[30] == 1) 
            $display(">> PASS: DLDO0 Idle State Correct (Active Low).");
        else 
            $error(">> FAIL: DLDO0 Idle State Incorrect.");

        if (status == 1'b1) $display(">> PASS: System Ready (Status=1).");

        // ------------------------------------------------------------
        // CASE 3: Execute Handover (Normal)
        // ------------------------------------------------------------
        $display("\n=== [CASE 3] Triggering Handover Sequence ===");
        
        start_trig_n = 0;
        repeat(5) @(posedge clk);
        
        if (status == 1'b0) $display(">> PASS: Status changed to BUSY.");
        else $error(">> FAIL: Status did not indicate BUSY.");

        repeat(20) @(posedge clk);
        
        // Check ALDO turned ON immediately (Step Jump)
        if (aldo_en === 15'h03FF) $display(">> PASS: ALDO turned ON to Target.");
        else $error(">> FAIL: ALDO State Error. Got %h", aldo_en);

        repeat(100) @(posedge clk);

        // Check Final State
        if (status == 1'b1) $display(">> PASS: Handover Complete (Status=1).");
        else $error(">> FAIL: Handover Timeout/Stuck.");

        if (dldo0_en_n === {64{1'b1}}) $display(">> PASS: DLDO0 Fully OFF.");
        else $error(">> FAIL: DLDO0 not fully OFF.");

        start_trig_n = 1;
        repeat(10) @(posedge clk);


        // ------------------------------------------------------------
        // CASE 4: Interruption / Abort Test
        // ------------------------------------------------------------
        $display("\n=== [CASE 4] Interruption Test ===");
        
        start_trig_n = 0;
        repeat(10) @(posedge clk); // Enter Active
        if (status == 0) $display(">> PASS: Re-entered Active State.");

        $display(">> Action: Aborting Trigger...");
        start_trig_n = 1;
        
        repeat(5) @(posedge clk);
        
        if (status == 1) $display(">> PASS: Status returned to Ready immediately.");
        else $error(">> FAIL: System stuck in Busy.");

        if (dldo0_en_n[0] == 0) $display(">> PASS: DLDO outputs restored to IDLE settings.");

        // ------------------------------------------------------------
        // End of Test
        // ------------------------------------------------------------
        #500;
        $display("\n=== All Tests Completed ===");
        $finish;
    end

endmodule