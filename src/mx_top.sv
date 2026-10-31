// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// mx_top.sv : the matrix unit
//
// Description
//   A two-entry row FIFO feeds a 2x2 systolic array of INT8 multiply-accumulators, and
//   one requantize unit, shared by the two columns, turns each row's column sums into
//   two INT8 results.
//
// Operation
//   Load the four weights before a run: "mx_w_ld" bit 2r + c loads PE(r, c) with "mx_w".
//   Load "bias0", "bias1", "scale", "shift" and "relu" through ctrl, before a run.
//   Hold "stream_en" high and offer rows on "row_valid" and "row_data" while "row_ready"
//   is high; the FIFO holds two rows. A row leaves the FIFO for the array when the
//   requantize unit is free.
//   The result {y1, y0} is on "res_data" while "res_valid" is high; "res_ready" high
//   takes it.
//   "row_pop" and "res_pop" pulse for one clock when a row enters the array and when a
//   result leaves; ctrl counts them.
//
// Timing
//   A result is ready 37 + 2S clocks after its row left the FIFO, S being "shift".
//   A result that is not taken holds the array, so a run moves at one row per 35 + 2S
//   clocks at best, and three rows can be written and not yet read.
//
// Modes
//   While "dp_sel" is high the tile walker, teach mode or attract mode owns the array
//   through the "dp_" ports and no row leaves the FIFO. The "ma_" ports lend the
//   requantize adder to those modes.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets the FIFO pointers, the array's
//   valid chain and the requantize control. The weights, the configuration and the data
//   registers have no reset; the host writes them before use.

`default_nettype none

module mx_top (
    input  logic               clk,         //rising edge
    input  logic               rst_n,       //asynchronous, active low; resets passed to the FIFO, the array and the requant unit (no registers of its own)
    input  logic               row_valid,   //a row is offered
    input  logic        [15:0] row_data,    //the row {a1, a0} into the FIFO
    output logic               row_ready,   //FIFO not full
    output logic               res_valid,   //a result is ready
    output logic        [15:0] res_data,    //the result {y1, y0}
    input  logic               res_ready,   //pops the result
    input  logic               stream_en,   //pops from the FIFO allowed (ctrl)
    output logic               row_pop,     //pulse: a row entered the array
    output logic               res_pop,     //pulse: a result left
    input  logic        [3:0]  mx_w_ld,     //REG_WR weight write: bit 2r + c loads PE(r, c) with mx_w
    input  logic        [7:0]  mx_w,        //the weight written
    input  logic signed [16:0] bias0,       //configuration from ctrl
    input  logic signed [16:0] bias1,       //configuration from ctrl
    input  logic        [15:0] scale,       //configuration from ctrl
    input  logic        [4:0]  shift,       //configuration from ctrl
    input  logic               relu,        //configuration from ctrl
    output logic        [1:0]  fifo_count,  //FIFO occupancy
    input  logic               dp_sel,      //the tile walker, teach, or attract owns the array
    input  logic        [3:0]  dp_w_ld,     //weight loads through the dp_ port (layout as the array's w_ld)
    input  logic        [31:0] dp_w,        //the weights through the dp_ port (layout as the array's w_in)
    input  logic        [15:0] dp_a,        //one row through the dp_ port
    input  logic               dp_a_valid,  //valid of dp_a
    output logic        [33:0] dp_p,        //column sums
    output logic               dp_p_valid,  //valid of dp_p, only while dp_sel = 1
    input  logic               ma_sel,      //to requant
    input  logic               ma_we,       //to requant
    input  logic               ma_clr,      //to requant
    input  logic               ma_pe,       //to requant
    input  logic signed [16:0] ma_b,        //the addend of teach mode or attract mode, to requant
    output logic signed [17:0] ma_q,        //PH, from requant
    output logic               ma_neg       //sign of the 19-bit sum, from requant
);
    
//This module has no registers of its own. Every flop is inside the FIFO, the array and requant.
//It connects the three blocks and selects what drives the array. When dp_sel is 1 the tile walker,
//teach mode or attract mode drives the array through the dp_ ports. When dp_sel is 0 the FIFO and
//the REG_WR weight writes drive it. Teach mode also uses requant's adder through the ma_ ports.
logic [15:0] a_in;      //the row going into the array: the oldest row in the FIFO, or dp_a when dp_sel is 1
logic        a_valid;   //1 when a_in holds a row: row_pop, or dp_a_valid when dp_sel is 1
logic [3:0]  w_ld;      //the array's weight load bits, one per PE: mx_w_ld from a REG_WR weight write, or dp_w_ld when dp_sel is 1
logic [31:0] w_in;      //the array's four weight bytes, one per PE: mx_w repeated four times, or dp_w when dp_sel is 1
logic        rq_v;      //1 while a finished row's sums wait at the array output during a matrix run (dp_sel is 0)
logic        en;        //the array's enable; every array register holds while it is 0. It goes to every register in the array, more loads than any other net in the chip
logic        rd_valid;  //1 while the FIFO holds at least one row
logic [15:0] rd_data;   //the oldest row in the FIFO, {a1, a0}. It comes from a mux on the two entries, not from a register, so no read clock is needed
logic [33:0] p_out;     //the array's two column sums {c1, c0}
logic        p_valid;   //1 while p_out holds a row's sums
logic        take;      //from requant: 1 for one clock when both columns of a row are done, so the array may advance to the next row

//Row FIFO: fifo_count is the rows stored, 0 to 2, status S0 bits 7:5.
fifo  
    #(.DEPTH    (2), 
      .WIDTH    (16)
    )i_fifo(           
      .clk      (clk), 
      .rst_n    (rst_n), 
      .wr_valid (row_valid), 
      .wr_data  (row_data),
      .wr_ready (row_ready), 
      .rd_valid (rd_valid), 
      .rd_data  (rd_data),
      .rd_ready (row_pop), 
      .count    (fifo_count)
    );

//Input multiplexers: four multiplexers choose the array's inputs by dp_sel.
assign a_in = dp_sel ? dp_a : rd_data;  //dp_sel = 1: the row from the dp_ port. dp_sel = 0: the oldest row in the FIFO
assign a_valid = dp_sel ? dp_a_valid : row_pop;  //dp_sel = 0: the row is valid in the clock it leaves the FIFO
assign w_ld = dp_sel ? dp_w_ld : mx_w_ld;        
assign w_in = dp_sel ? dp_w : {mx_w, mx_w, mx_w, mx_w};  //a REG_WR weight write carries one byte. The byte goes to all four PE inputs and the w_ld bit selects the PE that loads it

//Systolic array: the 2x2 array, with the enable that holds it.
array i_array 
    (
    .clk,    
    .rst_n,  
    .en,     
    .w_ld,   
    .w_in,   
    .a_in,   
    .a_valid,
    .p_out,  
    .p_valid
    );
    
    
//Flow control: three signals control the flow of rows during a run.
//rq_v: the array has finished a row and its sums wait at the output for requant.
//en: the array runs when dp_sel is 1, when no sums wait, or in the clock requant takes them (take = 1).
//Otherwise every array register holds and the sums stay at the output until requant has them.
//row_pop: the oldest row leaves the FIFO when ctrl allows pops (stream_en = 1), the FIFO holds a row
//(rd_valid = 1), the array runs (en = 1) and dp_sel is 0.
assign rq_v = p_valid & ~dp_sel;               
assign en = dp_sel | ~rq_v | take;             
assign row_pop = stream_en & rd_valid & en & ~dp_sel;  //also the FIFO's rd_ready. In a clock with row_pop = 1 the oldest row leaves the FIFO and enters the array


//Requantize unit: one unit serves both columns, one column after the other. Its result {y1, y0} is res_data.
requant   
    #(.SCALE_W(16)
    )i_requant(                 
    .clk,         
    .rst_n,      
    .p0         (p_out[16:0]), 
    .p1         (p_out[33:17]),
    .p_valid    (rq_v), 
    .take,       
    .bias0,      
    .bias1,      
    .scale,      
    .shift,      
    .relu,       
    .y          (res_data), 
    .y_valid    (res_valid),
    .y_ready    (res_ready), 
    .ma_sel, 
    .ma_we,
    .ma_clr,
    .ma_pe,
    .ma_b,
    .ma_q,
    .ma_neg
    );
    
assign res_pop = res_valid & res_ready;  //a result leaves in a clock with res_valid = 1 and res_ready = 1. ctrl counts these pulses

//dp_ port outputs: while dp_sel is 1 the sums go out on dp_p instead of into requant, because rq_v is 0 then.
assign dp_p = p_out;                           
assign dp_p_valid = p_valid & dp_sel;         

endmodule
