// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// array.sv : 2 by 2 weight-stationary systolic array of pe cells (N = 2 fixed).
// Project: Digit reader on Tiny Tapeout SKY26d.
//
// Notes on module array
//   A row sampled at edge e is on p_out after edge e + 2 while en stays 1.
//   Column c = a0 * w0c + a1 * w1c. The weights load whatever en is.

`default_nettype none

module array (
    input  logic        clk,      //rising edge
    input  logic        rst_n,    //asynchronous, active low; resets the valid skew register and every pe's v_out
    input  logic        en,       //global enable; every register except the weights holds while en = 0
    input  logic [3:0]  w_ld,     //bit 2r + c loads PE(r, c) from w_in
    input  logic [31:0] w_in,     //w_rc at bits [8(2r+c)+7 : 8(2r+c)]
    input  logic [15:0] a_in,     //{a1, a0}, row r at [8r+7 : 8r]
    input  logic        a_valid,  //the row valid
    output logic [33:0] p_out,    //de-skewed {c1, c0}, column c at [17c+16 : 17c]
    output logic        p_valid   //valid of p_out
);


logic [7:0] a1_skew;
logic v1_skew;
logic [7:0] a_00_01, a_10_11;
logic v_00_01, v_10_11;
logic [16:0] p_00_10, p_01_11, p_10, p_11, p0_deskew;

//Unused nets for Verilator
logic [7:0] unused_a_01, unused_a_11;
logic unused_v_01;

always_ff @(posedge clk or negedge rst_n) // Asynchronous clear; rst_n is synchronized by rst_sync (falls at once, rises on a clock edge).
    if(~rst_n)
        v1_skew <= 1'b0;
    else if(en)
        v1_skew <= a_valid; //delay one cycle
        
always_ff @(posedge clk)
    begin
    if(en)
        a1_skew <= a_in[15:8]; //delay one cycle
    
    if(en)
        p0_deskew <= p_10; //delay one cycle to align with p_11
    end
    
assign p_out = {p_11, p0_deskew};

pe pe_u00(      //Row 0, Column 0
        .clk,
        .rst_n,
        .en,
        .w_ld   (w_ld[0]),
        .w_in   (w_in[7:0]),
        .a_in   (a_in[7:0]),
        .v_in   (a_valid),
        .a_out  (a_00_01),
        .v_out  (v_00_01),
        .p_in   ('0),   //no pe above
        .p_out  (p_00_10)
        );

pe pe_u01(      //Row 0, Column 1
        .clk,
        .rst_n,
        .en,
        .w_ld   (w_ld[1]),
        .w_in   (w_in[15:8]),
        .a_in   (a_00_01),
        .v_in   (v_00_01),
        .a_out  (unused_a_01),      //no pe on right
        .v_out  (unused_v_01),      //no pe on right
        .p_in   ('0),   //no pe above
        .p_out  (p_01_11)
        );
        
pe pe_u10(      //Row 1, Column 0
        .clk,
        .rst_n,
        .en,
        .w_ld   (w_ld[2]),
        .w_in   (w_in[23:16]),
        .a_in   (a1_skew),
        .v_in   (v1_skew),
        .a_out  (a_10_11),
        .v_out  (v_10_11),
        .p_in   (p_00_10),
        .p_out  (p_10)
        );
        
pe pe_u11(      //Row 1, Column 1
        .clk,
        .rst_n,
        .en,
        .w_ld   (w_ld[3]),
        .w_in   (w_in[31:24]),
        .a_in   (a_10_11),
        .v_in   (v_10_11),
        .a_out  (unused_a_11),  //no pe on right
        .v_out  (p_valid),
        .p_in   (p_01_11),
        .p_out  (p_11)
        );

endmodule
