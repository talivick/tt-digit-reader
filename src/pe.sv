// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// pe.sv : the processing element
//
// Description
//   One weight-stationary processing element of the array: a held INT8 weight and one
//   mac. The activation moves right one PE per clock and the partial sum moves down.
//
// Operation
//   "w_ld" high loads "w_in" into the held weight at the edge, whatever "en" is.
//   At each edge with "en" high, "a_out" and "v_out" take "a_in" and "v_in", and "p_out"
//   takes "p_in" + "a_in" * weight. "v_in" travels with the data and gates nothing.
//
// Timing
//   Latency 1 clock. A weight loaded at edge e is used by activations sampled at edge
//   e + 1 or later; an activation sampled at the same edge as a load uses the old weight.
//
// Reset
//   "rst_n" is asynchronous and active low and resets "v_out" to 0 only. The weight,
//   "a_out" and "p_out" have no reset; "w_ld" loads the weight before use.

`default_nettype none

module pe (
    input  logic               clk,    //rising edge
    input  logic               rst_n,  //asynchronous, active low; resets v_out only
    input  logic               en,     //global enable for a_out, v_out, p_out
    input  logic               w_ld,   //load the held weight from w_in, whatever en is
    input  logic signed [7:0]  w_in,   //the weight to load
    input  logic signed [7:0]  a_in,   //activation from the left
    input  logic               v_in,   //valid from the left
    output logic signed [7:0]  a_out,  //registered a_in, to the right
    output logic               v_out,  //registered v_in, to the right
    input  logic signed [16:0] p_in,   //partial sum from above
    output logic signed [16:0] p_out   //registered p_in + a_in * weight (mac)
);

logic signed [7:0]  w;

always_ff @(posedge clk)
    begin
    if(w_ld)
        w <= w_in;
    
    if(en)
        a_out <= a_in; //a_out does not reset
    end
    

always_ff @(posedge clk or negedge rst_n) //asynchronous clear; rst_n comes from the top's reset synchronizer, so it falls at once and rises on a clock edge
    if(~rst_n)  
        v_out <= 'sd0;
    else if(en)
        v_out <= v_in;

mac mac_u(
    .clk,
    .en,
    .a      (a_in),
    .w,
    .c_in   (p_in),
    .c_out  (p_out)
    );  

endmodule
