// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// sync.sv : the reset and input synchronizers
//
// Description
//   rst_sync makes the chip's reset, "rst_n_s", from the pad reset "rst_n": two flops
//   cleared by "rst_n", the first loading 1 and the second driving "rst_n_s", which every
//   other flop with a reset takes. sync2 passes an asynchronous input "d" to "q" through
//   two flops. All four flops carry (* ASYNC_REG = "TRUE" *).
//
// Parameters
//   RST_VAL is the reset value of both sync2 flops: 1 for "in_valid", 0 for the touch
//   data.
//
// Timing
//   "rst_n_s" falls at once when "rst_n" falls and rises on the second or third rising
//   "clk" edge after "rst_n" rises, the third when it rises inside the first flop's
//   recovery window.
//
// Reset
//   Both reset asynchronously: rst_sync's flops are cleared by "rst_n", and sync2's flops
//   are set to RST_VAL by its "rst_n", which is "rst_n_s".

`default_nettype none

module rst_sync (
    input  logic  clk,      //clock
    input  logic  rst_n,    //the pad reset, asynchronous
    output logic  rst_n_s   //synchronized release, asynchronous assertion
);

(* ASYNC_REG = "TRUE" *) logic ff1;
(* ASYNC_REG = "TRUE" *) logic ff2;

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        ff1     <= 1'b0;
        ff2     <= 1'b0;
        end
    else
        begin
        ff1     <= 1'b1;
        ff2     <= ff1;
        end

assign rst_n_s = ff2;

endmodule

module sync2 #(
    parameter bit RST_VAL = 1'b0    //the reset value of both flops; 1 for in_valid, 0 for the touch data
) (
    input  logic  clk,    //clock
    input  logic  rst_n,  //rst_n_s
    input  logic  d,      //asynchronous input
    output logic  q       //the second flop
);
    
(* ASYNC_REG = "TRUE" *) logic ff1;
(* ASYNC_REG = "TRUE" *) logic ff2;

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        ff1     <= RST_VAL;
        ff2     <= RST_VAL;
        end
    else
        begin
        ff1     <= d;
        ff2     <= ff1;
        end
        
assign q = ff2;

endmodule
