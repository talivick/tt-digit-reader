// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// mac.sv : multiply-accumulate cell with the addend taken from a port.
// Project: Digit reader, Tiny Tapeout SKY26d (top module tt_um_talivick_digit_reader).
//
// Notes on module mac
//   No reset in this module.
//   Latency 1 clock: inputs sampled at a rising edge are on c_out after that edge.

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
