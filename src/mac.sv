// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// mac.sv : the multiply-accumulate cell
//
// Description
//   One INT8 multiply-accumulate cell whose addend comes from a port, so that a partial
//   sum can move down a column of the array. "a" and "w" are 8-bit signed; "c_in" and
//   "c_out" are 17-bit signed, enough for two products of up to 16,384 each.
//
// Operation
//   At each rising edge with "en" high, "c_out" takes "c_in" + "a" * "w"; with "en" low
//   it holds.
//
// Timing
//   Latency 1 clock: inputs sampled at an edge are on "c_out" after that edge.
//
// Reset
//   The cell has no reset and no "rst_n" port; each edge with "en" high writes "c_out".

`default_nettype none

module mac (
    input  logic               clk,    //clock; no reset
    input  logic               en,     //c_out updates only while en = 1
    input  logic signed [7:0]  a,      //activation
    input  logic signed [7:0]  w,      //weight
    input  logic signed [16:0] c_in,   //addend: the partial sum from above
    output logic signed [16:0] c_out   //registered c_in + a * w
);

always_ff @(posedge clk)
    if(en)
        c_out <= c_in + a * w;

endmodule
