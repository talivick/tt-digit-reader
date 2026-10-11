// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// pe.sv : weight-stationary processing element: one held weight and one mac.
// Project: Digit reader on Tiny Tapeout SKY26d.
//
// Notes on module pe
//   Latency 1 clock. A weight loaded at edge e is used by activations sampled at edge e + 1
//   or later; an activation sampled at the same edge as a load uses the old weight.
//   en is the only gate on a_out, v_out and p_out; v_in gates nothing.

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
	

always_ff @(posedge clk or negedge rst_n) // Asynchronous clear; rst_n is synchronized by rst_sync (falls at once, rises on a clock edge).
	if(~rst_n)	
		v_out <= 'sd0;
	else if(en)
		v_out <= v_in;

mac mac_u(
	.clk,
	.en,
	.a		(a_in),
	.w,
	.c_in	(p_in),
	.c_out	(p_out)
	);	

endmodule
