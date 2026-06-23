//SHAKE random stream
  //      ↓
   // FIFO buffer
     //   ↓
//Address generation
  //      ↓
//Virtual permutation swap
   //     ↓
//Output P and v*/
///////// 

module shake_fifo #(
    parameter WIDTH = 32,      //each stored number is 32 bits
    parameter DEPTH = 84,      // FIFO can store 48 random numbers
  parameter ADDR_WIDTH = $clog2(DEPTH)   // log2(DEPTH),Need 5 bits to count addresses
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // WRITE SIDE (FROM SHAKE256 CORE)

    input  logic                 wr_en,
    input  logic [WIDTH-1:0]     wr_data,

    output logic                 full,

    
    // READ SIDE (TO SAMPLER FSM)
    

    input  logic                 rd_en,

    output logic [WIDTH-1:0]     rd_data,
    output logic                 empty,

    
    // OPTIONAL STATUS

    output logic [ADDR_WIDTH:0]  count
);

    // FIFO MEMORY
    

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    // POINTERS

    logic [ADDR_WIDTH-1:0] wr_ptr;
    logic [ADDR_WIDTH-1:0] rd_ptr;

    // FULL / EMPTY
    

    assign empty = (count == 0);
    assign full  = (count == DEPTH);

    // READ DATA

    assign rd_data = mem[rd_ptr];

    // MAIN FIFO LOGIC

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr <= 0;
        rd_ptr <= 0;
        count  <= 0;
      
    end else begin
        if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;
          
          if (wr_ptr == ADDR_WIDTH'(DEPTH - 1)) // If at 83
                    wr_ptr <= 0;                      // Reset to 0
                else
                    wr_ptr <= wr_ptr + 1'b1;
              end
      
        if (rd_en && !empty) begin
				if (rd_ptr == ADDR_WIDTH'(DEPTH - 1)) // If at 83
                    rd_ptr <= 0;                      // Reset to 0
                else
                    rd_ptr <= rd_ptr + 1'b1;  
        end
        
        // Count update logic
        case ({ (wr_en && !full), (rd_en && !empty) })
            2'b10: count <= count + 1; // Write only
            2'b01: count <= count - 1; // Read only
            default: count <= count;   // Both or neither
        endcase
    end
end

endmodule

//*****************************************************************************
// goal is to produce a randomized index j in a range [i, N)
module address_generator #(
  
 parameter parameter_set = "hqc128",

    // HQC PARAMETERS
    

    parameter N = (parameter_set == "hqc128") ? 17_669 :
                  (parameter_set == "hqc192") ? 35_851 :
                  (parameter_set == "hqc256") ? 57_637 :
                                                17_669,
// Bit-width needed to represent N
    parameter M = (parameter_set == "hqc128") ? 15 :
                  (parameter_set == "hqc192") ? 16 :
                  (parameter_set == "hqc256") ? 16 :
                                                15
)(
    input  logic              clk,
    input  logic              rst_n,
    
    // Interface to  FSM
    input  logic              enable,      // Only generate when FSM is in ST_SAMPLE
    output logic              j_valid,     // Tells FSM: "J is ready!"
    input  logic              ack,         // FSM tells Gen: "I used this J, give me next"
    
    // Interface to FIFO
    input  logic [31:0]       rand_word,   // From shake_fifo
    input  logic              fifo_empty,
    output logic              fifo_rd_en,
    
    input  logic [M-1:0]      i,           // Current loop counter
    output logic [M-1:0]      j            // Resulting random index
);

    logic [M-1:0]  range;
    logic [31+M:0] mult_result;
    logic [M-1:0]  offset;

    // 1. Calculate the available range: [0, N-1-i]
    assign range = N - 1 - i;

    // 2. Perform the Scaling (Multiply-High)
    // mult_result = 32-bit random * 15-bit range = 47 bits
    assign mult_result = rand_word * range;
    
    // The top M bits are the "scaled" version of the random number
    assign offset = mult_result[31+M : 32];

    // 3. State Control for the Generator
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            j       <= '0;
            j_valid <= 1'b0;
        end else if (enable) begin
            // If the FIFO has data and we don't have a valid J yet
            if (!fifo_empty && !j_valid) begin
                j       <= i + offset; // The actual index in the vector
                j_valid <= 1'b1;
            end 
            // Once the FSM 'acks' the J, we clear valid and wait for next
            else if (ack) begin
                j_valid <= 1'b0;
            end
        end else begin
            j_valid <= 1'b0;
        end
    end

    // 4. FIFO Read Control
    // Request a new random word only when we are active and current J is being cleared
    assign fifo_rd_en = enable && !fifo_empty && (!j_valid || ack);

endmodule

// *******************************************************************************
//The goal of the Bitset is to track which positions have been modified so we don't have to waste space storing 17,669 numbers.

`default_nettype none

module hqc_bitset #(
    parameter  string     parameter_set = "hqc128",

    parameter  int        N = (parameter_set == "hqc128") ? 17_669 :
                              (parameter_set == "hqc192") ? 35_851 :
                              (parameter_set == "hqc256") ? 57_637 :
                                                            17_669,

    parameter  int        M = (parameter_set == "hqc128") ? 15 :
                              (parameter_set == "hqc192") ? 16 :
                              (parameter_set == "hqc256") ? 16 :
                                                            15

//     parameter  int        WEIGHT = (parameter_set == "hqc128") ?  75 :
//                                    (parameter_set == "hqc192") ? 114 :
//                                    (parameter_set == "hqc256") ? 149 :
//                                                                    75
)(
    input  logic         clk,
    input  logic         rst_n,

    // Pulse high for 1 cycle to start clearing all N bits
    input  logic         init_start,
    // Goes high the cycle after the last bit is cleared, stays high
    output logic         init_done,

    // Read port I — combinational, zero latency
    input  logic [M-1:0] addr_i,
    output logic         bit_i_out,

    // Read port J — combinational, zero latency
    input  logic [M-1:0] addr_j,
    output logic         bit_j_out,

    // Write port — marks both addr_i and addr_j as swapped (sets to 1)
    // Ignored while init is running
    input  logic         we,
    input  logic [M-1:0] wr_addr_i,
    input  logic [M-1:0] wr_addr_j
);

    // Packed storage — synthesizes to LUT-RAM on Xilinx/Intel.
    // (* ram_style = "distributed" *) tells Vivado explicitly.
    (* ram_style = "distributed" *)
    logic [N-1:0] bitset;

    // Init state
    logic [M-1:0] clear_ptr;
    logic         is_init;

    // Sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_init   <= 1'b0;
            init_done <= 1'b0;
            clear_ptr <= '0;
            // NOTE: 'bitset' itself is NOT reset here.
            // It is cleared via the init_start sequential sweep below.
            // Resetting [N-1:0] in one cycle would require N flip-flops
            // with synchronous reset — extremely wasteful for N=57637.
        end

        else if (init_start) begin
            is_init   <= 1'b1;
            init_done <= 1'b0;
            clear_ptr <= '0;
        end

        else if (is_init) begin
            bitset[clear_ptr] <= 1'b0;

            if (clear_ptr == M'(N - 1)) begin
                is_init   <= 1'b0;
                init_done <= 1'b1;
            end else begin
                clear_ptr <= clear_ptr + 1'b1;
            end
        end

        else begin
            // Normal operation
            if (we) begin
                bitset[wr_addr_i] <= 1'b1;
                bitset[wr_addr_j] <= 1'b1;
            end
        end
    end

    // Combinational read — async dual port, zero latency
    assign bit_i_out = bitset[addr_i];
    assign bit_j_out = bitset[addr_j];


endmodule

`default_nettype wire

//*******************************************************************

module hqc_swap_mux #(
    parameter  string     parameter_set = "hqc128",

    parameter  int        N = (parameter_set == "hqc128") ? 17_669 :
                              (parameter_set == "hqc192") ? 35_851 :
                              (parameter_set == "hqc256") ? 57_637 :
                                                            17_669,

    parameter  int        M = (parameter_set == "hqc128") ? 15 :
                              (parameter_set == "hqc192") ? 16 :
                              (parameter_set == "hqc256") ? 16 :
                                                            15
)(
    // Current loop counter (i) and generated random index (j)
    input  logic [M-1:0] i_idx,
    input  logic [M-1:0] j_idx,

    // Status bits from the Bitset Array
    input  logic         bit_i,
    input  logic         bit_j,

    // Values currently stored in the Sparse BRAM
    input  logic [M-1:0] ram_val_i,
    input  logic [M-1:0] ram_val_j,

    // SWAPPED VALUES: To be written back into Sparse BRAM
    output logic [M-1:0] new_val_i,
    output logic [M-1:0] new_val_j,
    
    // THE SAMPLED INDEX: This is the final result of this iteration
    output logic [M-1:0] sampled_val
);

    // Internal wires to hold the "resolved" values before swapping
    logic [M-1:0] resolved_i;
    logic [M-1:0] resolved_j;

    // --- STEP 1: RESOLVE IDENTITY vs RAM ---
    // If bit is 0, the value is the index itself (Identity Mapping)
    // If bit is 1, the value must be pulled from the Sparse RAM
    //This is a hardware multiplexer.
    
    assign resolved_i = (bit_i == 1'b0) ? i_idx : ram_val_i;
    assign resolved_j = (bit_j == 1'b0) ? j_idx : ram_val_j;

    // --- STEP 2: THE SWAP ---
    // In Fisher-Yates: Position [i] gets the value that was at [j]
    //                  Position [j] gets the value that was at [i]
    
    assign new_val_i = resolved_j;
    assign new_val_j = resolved_i;

    // --- STEP 3: OUTPUT ---
    // The result of the HQC sampling for index 'i' is the value 
    // that was originally at 'j'.
    assign sampled_val = resolved_j;

endmodule

//***************************************************************

module hqc_sparse_bram #(
  parameter  string     parameter_set = "hqc128",

    parameter  int        M = (parameter_set == "hqc128") ? 15 :
                              (parameter_set == "hqc192") ? 16 :
                              (parameter_set == "hqc256") ? 16 :
                                                            15,

    parameter  int        WEIGHT = (parameter_set == "hqc128") ?  75 :
                                   (parameter_set == "hqc192") ? 114 :
                                   (parameter_set == "hqc256") ? 149 :
                                                                   75,
  
    localparam int AW    = $clog2(WEIGHT) // Internal address width
)(
    input  logic          clk,
    
    // Port I (Linked to loop counter i)
    input  logic [M-1:0]  addr_i,
    input  logic [M-1:0]  din_i,
    input  logic          we_i,
    output logic [M-1:0]  dout_i,

    // Port J (Linked to random index j)
    input  logic [M-1:0]  addr_j,
    input  logic [M-1:0]  din_j,
    input  logic          we_j,
    output logic [M-1:0]  dout_j
);

    // The actual memory array
  // (* ram_style = "block" *)   //  for BRAM or "distributed" for LUTRAM
    (* ram_style = "distributed" *) 
  logic [M-1:0] mem [0:WEIGHT-1];

    // --- WRITE LOGIC (Sequential) ---
    always_ff @(posedge clk) begin
        if (we_i) begin
            mem[addr_i[AW-1:0]] <= din_i;
        end
        if (we_j) begin
            mem[addr_j[AW-1:0]] <= din_j;
        end
    end

    // --- READ LOGIC (Asynchronous/Combinational) ---
    // We use async reads so the MUXes can see the data immediately 
    // in the same cycle the Address Generator produces j.
    assign dout_i = mem[addr_i[AW-1:0]];
    assign dout_j = mem[addr_j[AW-1:0]];
  

endmodule

//****************************************************************
// FSM top module
`default_nettype none

module hqc_fsm #(
    parameter string parameter_set = "hqc128",

    parameter int M = (parameter_set == "hqc128") ? 15 :
                      (parameter_set == "hqc192") ? 16 :
                      (parameter_set == "hqc256") ? 16 : 15,

    parameter int WEIGHT = (parameter_set == "hqc128") ?  75 :
                           (parameter_set == "hqc192") ? 114 :
                           (parameter_set == "hqc256") ? 149 : 75
)(
    input  logic          clk,
    input  logic          rst_n,

    // Top-level control
    input  logic          start,
    output logic          ready,
    output logic          done,

    // --- address_generator ---
    output logic          ag_enable,
    input  logic          ag_j_valid,
    output logic          ag_ack,
    output logic [M-1:0]  ag_i,
    input  logic [M-1:0]  ag_j,

    // --- hqc_bitset ---
    output logic          bs_init_start,
    input  logic          bs_init_done,
    output logic [M-1:0]  bs_addr_i,
    output logic [M-1:0]  bs_addr_j,
    input  logic          bs_bit_i,
    input  logic          bs_bit_j,
    output logic          bs_we,
    output logic [M-1:0]  bs_wr_addr_i,
    output logic [M-1:0]  bs_wr_addr_j,

    // --- hqc_swap_mux ---
    output logic [M-1:0]  mux_i_idx,
    output logic [M-1:0]  mux_j_idx,
    output logic          mux_bit_i,
    output logic          mux_bit_j,
    input  logic [M-1:0]  mux_new_val_i,
    input  logic [M-1:0]  mux_new_val_j,
    input  logic [M-1:0]  mux_sampled_val,

    // --- hqc_sparse_bram ---
    output logic [M-1:0]  bram_addr_i,
    output logic [M-1:0]  bram_addr_j,
    output logic [M-1:0]  bram_din_i,
    output logic [M-1:0]  bram_din_j,
    output logic          bram_we_i,
    output logic          bram_we_j,

    // --- External Outputs to P Buffer ---
    output logic [M-1:0]  val_j_out,
    output logic          val_j_valid,
    output logic [M-1:0]  p_index
);

    // ----------------------------------------------------------------
    // States
    // ----------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE = 2'b00,
        ST_INIT = 2'b01,
        ST_SWAP = 2'b10,
        ST_DONE = 2'b11
    } state_t;

    state_t state, next_state;

    // ----------------------------------------------------------------
    // Core datapath registers
    // ----------------------------------------------------------------
    logic [M-1:0]              i_reg;
    logic [$clog2(WEIGHT)-1:0] swap_cnt;
    logic                      init_pulsed;

    // ----------------------------------------------------------------
    // Pipeline stage registers
    // Cycle N  : ag_j_valid fires — capture everything settled
    // Cycle N+1: write_strobe fires — commit to BRAM + bitset
    // ----------------------------------------------------------------
    logic [M-1:0] j_reg;            // captured ag_j
    logic [M-1:0] i_reg_delayed;    // captured i_reg
    logic [M-1:0] new_val_i_reg;    // captured mux_new_val_i
    logic [M-1:0] new_val_j_reg;    // captured mux_new_val_j
    logic [M-1:0] sampled_val_reg;  // captured mux_sampled_val
    logic         write_strobe;     // delayed ag_j_valid — triggers writes

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            j_reg           <= '0;
            i_reg_delayed   <= '0;
            new_val_i_reg   <= '0;
            new_val_j_reg   <= '0;
            sampled_val_reg <= '0;
            write_strobe    <= 1'b0;
        end else begin
            // write_strobe is ag_j_valid delayed by 1 cycle
            write_strobe <= (state == ST_SWAP) && ag_j_valid;

            // Capture everything on ag_j_valid — MUX outputs are settled
            if ((state == ST_SWAP) && ag_j_valid) begin
                j_reg           <= ag_j;
                i_reg_delayed   <= i_reg;
                new_val_i_reg   <= mux_new_val_i;   
                new_val_j_reg   <= mux_new_val_j;   
                sampled_val_reg <= mux_sampled_val;  
            end
        end
    end

    // ----------------------------------------------------------------
    // State register
    // ----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= next_state;
    end

    // ----------------------------------------------------------------
    // Next state logic
    // ----------------------------------------------------------------
    always_comb begin
        next_state = state;
        unique case (state)
            ST_IDLE : if (start)        next_state = ST_INIT;
            ST_INIT : if (bs_init_done) next_state = ST_SWAP;
            ST_SWAP : begin
                if (ag_j_valid && (swap_cnt == $bits(swap_cnt)'(WEIGHT - 1)))
                    next_state = ST_DONE;
            end
            ST_DONE : if (!start)       next_state = ST_IDLE;
            default :                   next_state = ST_IDLE;
        endcase
    end

    // ----------------------------------------------------------------
    // Datapath counters
    // ----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_reg       <= '0;
            swap_cnt    <= '0;
            init_pulsed <= 1'b0;
        end else begin
            unique case (state)
                ST_IDLE : begin
                    i_reg       <= '0;
                    swap_cnt    <= '0;
                    init_pulsed <= 1'b0;
                end
                ST_INIT : begin
                    init_pulsed <= 1'b1;
                end
                ST_SWAP : begin
                    if (ag_j_valid) begin
                        i_reg    <= i_reg + 1'b1;
                        swap_cnt <= swap_cnt + 1'b1;
                    end
                end
                default : begin end
            endcase
        end
    end

    // ----------------------------------------------------------------
    // Output assignments
    // ----------------------------------------------------------------

    // Status
    assign ready         = (state == ST_IDLE);
    assign done          = (state == ST_DONE);

    // Bitset init — one-shot pulse on entry to ST_INIT
    assign bs_init_start = (state == ST_INIT) && !init_pulsed;

    // Address generator
    assign ag_enable     = (state == ST_SWAP);
    assign ag_ack        = (state == ST_SWAP) && ag_j_valid;
    assign ag_i          = i_reg;

    // ---- READ PATHS: live/combinational, zero latency ----
    assign bs_addr_i     = i_reg;
    assign bs_addr_j     = ag_j;
    assign mux_i_idx     = i_reg;
    assign mux_j_idx     = ag_j;
    assign mux_bit_i     = bs_bit_i;
    assign mux_bit_j     = bs_bit_j;

    // ---- WRITE PATHS: registered, fire one cycle after read ----

    // Bitset write
    assign bs_we         = write_strobe;
    assign bs_wr_addr_i  = i_reg_delayed;
    assign bs_wr_addr_j  = j_reg;

    // BRAM address: read address when idle, write address when committing
    assign bram_addr_i   = write_strobe ? i_reg_delayed : i_reg;
    assign bram_addr_j   = write_strobe ? j_reg         : ag_j;

    // BRAM data: registered MUX outputs — settled values from previous cycle
    assign bram_din_i    = new_val_i_reg;    
    assign bram_din_j    = new_val_j_reg;    
    assign bram_we_i     = write_strobe;
    assign bram_we_j     = write_strobe;

    // ---- P BUFFER: aligned to write_strobe cycle ----
    assign val_j_out     = sampled_val_reg;  
    assign val_j_valid   = write_strobe;     
    assign p_index       = i_reg_delayed;    

endmodule

`default_nettype wire

//***************************************************************************************
// TOP MODULE

`default_nettype none

module hqc_sampler_top #(
    parameter string parameter_set = "hqc128",

    parameter int N = (parameter_set == "hqc128") ? 17_669 :
                      (parameter_set == "hqc192") ? 35_851 :
                      (parameter_set == "hqc256") ? 57_637 : 17_669,

    parameter int M = (parameter_set == "hqc128") ? 15 :
                      (parameter_set == "hqc192") ? 16 :
                      (parameter_set == "hqc256") ? 16 : 15,

    parameter int WEIGHT = (parameter_set == "hqc128") ?  75 :
                           (parameter_set == "hqc192") ? 114 :
                           (parameter_set == "hqc256") ? 149 : 75
)(
    input  logic          clk,
    input  logic          rst_n,

    // --- Control Interface ---
    input  logic          start,
    output logic          ready,
    output logic          done,

    // --- Entropy Source (SHAKE256) Interface ---
    input  logic          shake_wr_en,
    input  logic [31:0]   shake_wr_data,
    output logic          shake_full,

    // --- Output Interface ---
    output logic [M-1:0]  P [0:WEIGHT-1]
);

    // Internal Structural Wires
  
    // FIFO
    logic [31:0]  fifo_rd_data;
    logic         fifo_empty;
    logic         fifo_rd_en;
  
  	// Address generator
    logic         ag_enable, ag_j_valid, ag_ack;
    logic [M-1:0] ag_i, ag_j;
  
 	 //Bitset
    logic         bs_init_start, bs_init_done, bs_we;
    logic [M-1:0] bs_addr_i, bs_addr_j, bs_wr_addr_i, bs_wr_addr_j;
    logic         bs_bit_i, bs_bit_j;
  
    // Swap MUX
    logic [M-1:0] mux_i_idx, mux_j_idx, mux_new_val_i, mux_new_val_j, mux_sampled_val;
    logic         mux_bit_i, mux_bit_j;

    // Sparse BRAM
    logic [M-1:0] bram_addr_i, bram_addr_j, bram_din_i, bram_din_j, bram_dout_i, bram_dout_j;
    logic         bram_we_i, bram_we_j;
  
    // P buffer write signals from FSM
    logic [M-1:0] val_j_out, p_index;
    logic         val_j_valid;

    // ----------------------------------------------------------------
    // 1. Shake FIFO (Entropy Buffer)
    // ----------------------------------------------------------------
    shake_fifo #(
        .WIDTH (32),
        .DEPTH (WEIGHT * 2 + 10) 
    ) u_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (shake_wr_en),
        .wr_data (shake_wr_data),
        .full    (shake_full),
        .rd_en   (fifo_rd_en),
        .rd_data (fifo_rd_data),
        .empty   (fifo_empty),
        .count   ()
    );

    // ----------------------------------------------------------------
    // 2. Address Generator (Rejection Sampler)
    // ----------------------------------------------------------------
    address_generator #(
        .parameter_set (parameter_set),
        .N             (N),
        .M             (M)
    ) u_addr_gen (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (ag_enable),
        .j_valid    (ag_j_valid),
        .ack        (ag_ack),
        .rand_word  (fifo_rd_data),
        .fifo_empty (fifo_empty),
        .fifo_rd_en (fifo_rd_en),
        .i          (ag_i),
        .j          (ag_j)
    );

    // ----------------------------------------------------------------
    // 3. HQC Bitset (Tracking Map)
    // ----------------------------------------------------------------
    hqc_bitset #(
        .parameter_set (parameter_set),
        .N             (N),
        .M             (M)
    ) u_bitset (
        .clk        (clk),
        .rst_n      (rst_n),
        .init_start (bs_init_start),
        .init_done  (bs_init_done),
        .addr_i     (bs_addr_i),
        .bit_i_out  (bs_bit_i),
        .addr_j     (bs_addr_j),
        .bit_j_out  (bs_bit_j),
        .we         (bs_we),
        .wr_addr_i  (bs_wr_addr_i),
        .wr_addr_j  (bs_wr_addr_j)
    );

    // ----------------------------------------------------------------
    // 4. Swap Multiplexer (Combinational Logic)
    // ----------------------------------------------------------------
    hqc_swap_mux #(
        .parameter_set (parameter_set),
        .N             (N),
        .M             (M)
    ) u_swap_mux (
        .i_idx       (mux_i_idx),
        .j_idx       (mux_j_idx),
        .bit_i       (mux_bit_i),
        .bit_j       (mux_bit_j),
        .ram_val_i   (bram_dout_i),
        .ram_val_j   (bram_dout_j),
        .new_val_i   (mux_new_val_i),
        .new_val_j   (mux_new_val_j),
        .sampled_val (mux_sampled_val)
    );

    // ----------------------------------------------------------------
    // 5. Sparse BRAM (Value Storage)
    // ----------------------------------------------------------------
    hqc_sparse_bram #(
        .parameter_set (parameter_set),
        .M             (M),
        .WEIGHT        (WEIGHT)
    ) u_bram (
        .clk    (clk),
        .addr_i (bram_addr_i),
        .din_i  (bram_din_i),
        .we_i   (bram_we_i),
        .dout_i (bram_dout_i),
        .addr_j (bram_addr_j),
        .din_j  (bram_din_j),
        .we_j   (bram_we_j),
        .dout_j (bram_dout_j)
    );

    // ----------------------------------------------------------------
    // 6.  FSM (Pipelined Controller)
    // ----------------------------------------------------------------
    hqc_fsm #(
        .parameter_set (parameter_set),
        .M             (M),
        .WEIGHT        (WEIGHT)
    ) u_boss (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .ready           (ready),
        .done            (done),
        .ag_enable       (ag_enable),
        .ag_j_valid      (ag_j_valid),
        .ag_ack          (ag_ack),
        .ag_i            (ag_i),
        .ag_j            (ag_j),
        .bs_init_start   (bs_init_start),
        .bs_init_done    (bs_init_done),
        .bs_addr_i       (bs_addr_i),
        .bs_addr_j       (bs_addr_j),
        .bs_bit_i        (bs_bit_i),
        .bs_bit_j        (bs_bit_j),
        .bs_we           (bs_we),
        .bs_wr_addr_i    (bs_wr_addr_i),
        .bs_wr_addr_j    (bs_wr_addr_j),
        .mux_i_idx       (mux_i_idx),
        .mux_j_idx       (mux_j_idx),
        .mux_bit_i       (mux_bit_i),
        .mux_bit_j       (mux_bit_j),
        .mux_new_val_i   (mux_new_val_i),
        .mux_new_val_j   (mux_new_val_j),
        .mux_sampled_val (mux_sampled_val),
        .bram_addr_i     (bram_addr_i),
        .bram_addr_j     (bram_addr_j),
        .bram_din_i      (bram_din_i),
        .bram_din_j      (bram_din_j),
        .bram_we_i       (bram_we_i),
        .bram_we_j       (bram_we_j),
        .val_j_out       (val_j_out),
        .val_j_valid     (val_j_valid),
        .p_index         (p_index)
    );

    // ----------------------------------------------------------------
    // 7. Final Output Buffer (P Array)
    // ----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < WEIGHT; k++) begin
                P[k] <= '0;
            end
        end else if (val_j_valid) begin
            P[p_index[$clog2(WEIGHT)-1:0]] <= val_j_out;
        end
    end

endmodule
