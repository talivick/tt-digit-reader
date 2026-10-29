// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// sync2.sv : the two-flop synchronizer
//
// Description
//   sync2 passes an asynchronous input "d" to "q" through two flops. Both flops carry
//   (* ASYNC_REG = "TRUE" *). The top uses it three times: as the reset synchronizer, with
//   "d" tied to 1 and RST_VAL 0, making the chip's reset "rst_n_s" from the pad reset "rst_n",
//   which every other flop with a reset takes; for "in_valid"; and for the touch data.
//
// Parameters
//   RST_VAL is the reset value of both flops: 1 for "in_valid", 0 for the touch data and the
//   reset synchronizer.
//
// Timing
//   A change of "d" reaches "q" on the second rising "clk" edge after it, or the third when it
//   lands inside the first flop's setup window. As the reset synchronizer: "rst_n_s" falls at
//   once when "rst_n" falls and rises on the second or third rising "clk" edge after "rst_n"
//   rises, the third when it rises inside the first flop's recovery window.
//
// Reset
//   Both flops are set to RST_VAL asynchronously by "rst_n": the pad reset for the reset
//   synchronizer, "rst_n_s" for the other two.

`default_nettype none

module sync2 #(
    parameter bit RST_VAL = 1'b0    //reset value of both flops; 1 for in_valid, 0 for the touch data and the reset synchronizer
) (
    input  logic  clk,    //clock
    input  logic  rst_n,  //rst_n_s; the pad reset in the reset synchronizer
    input  logic  d,      //asynchronous input; tied to 1 in the reset synchronizer
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
