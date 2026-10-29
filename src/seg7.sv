// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// seg7.sv : the 7-segment encoder
//
// Description
//   Holds the pattern for the demo board's 7-segment display, "seg" = {dp, g, f, e, d,
//   c, b, a}, active high: a pattern the host picks, or the digit the chip read.
//
// Operation
//   The commands arrive on "cmd", "arg_we", "arg_byte" and "go".
//   SEG_SHOW (0x10) writes its argument byte into SEG_PAT and selects pattern mode, in
//   which "seg" shows SEG_PAT.
//   SEG_WINNER (0x11), or an "am_done" pulse at the end of an argmax, selects winner
//   mode, in which "seg" shows the digit "winner" while "win_valid" is high and 0x00
//   otherwise, with dp off.
//   Digits 0 to 9 show 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F.
//
// Timing
//   "seg" is a register: it follows a change of SEG_PAT or of the mode one edge later.
//
// Reset
//   "rst_n" is asynchronous and active low. "seg" and SEG_PAT reset to 0x40, segment g
//   alone, and the mode to pattern mode, so the display shows a sign of life from reset.
//   Every register of the block has a reset.

`default_nettype none

module seg7 (
    input  logic       clk,        //rising edge
    input  logic       rst_n,      //asynchronous, active low; resets seg to 0x40 and the mode
    input  logic [7:0] cmd,        //the command byte; SEG_SHOW, SEG_WINNER
    input  logic       arg_we,     //pulse: an argument byte is on arg_byte
    input  logic [7:0] arg_byte,   //the argument byte
    input  logic       go,         //pulse: the command is complete, after its last argument
    input  logic       am_done,    //argmax done pulse, from dp_acc
    input  logic [3:0] winner,     //the winner, from dp_acc
    input  logic       win_valid,  //valid of winner
    output logic [7:0] seg         //registered {dp, g, f, e, d, c, b, a}, active high; reset 0x40
);


logic [7:0] seg_pat;   //the pattern SEG_SHOW wrote; shown in pattern mode
logic       seg_mode;  //0 pattern mode, 1 winner mode
logic       seg_show;  //the SEG_SHOW argument byte is on arg_byte: write the pattern and select pattern mode
logic       seg_win;   //select winner mode: a SEG_WINNER is complete, or an argmax has finished (am_done)
logic [7:0] digit;     //the winner's 7-segment pattern, from the table below
logic [7:0] win_pat;   //the digit while win_valid is 1, else every segment off
logic [7:0] seg_next;  //what seg loads at the next edge: win_pat in winner mode, seg_pat in pattern mode

//The two strobes from the command bus. SEG_SHOW has one argument byte, so its arg_we and its go come in
//the same clock; the pattern is taken with arg_we. SEG_WINNER has no argument, so its go marks it.
assign seg_show = arg_we & (cmd == address_map::CMD_SEG_SHOW);
assign seg_win = (go & (cmd == address_map::CMD_SEG_WINNER)) | am_done;

//The pattern register and the mode. SEG_SHOW writes the pattern and selects pattern mode in the same
//clock. When seg_show and seg_win arrive in one clock, seg_show wins.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        seg_pat     <= 8'h40;
        seg_mode    <= 1'b0;
        end
    else
        begin
        if(seg_show)
            seg_pat     <= arg_byte;
        
        if(seg_show)
            seg_mode    <= 1'b0;
        else if(seg_win)
            seg_mode    <= 1'b1;
        end

//The digit table of chip plan 7.1, {dp, g, f, e, d, c, b, a}, active high; dp stays 0. Winner values
//10 to 15 do not occur and show nothing.
always_comb
    case(winner)
    4'd0: digit = 8'h3F;
    4'd1: digit = 8'h06;
    4'd2: digit = 8'h5B;
    4'd3: digit = 8'h4F;
    4'd4: digit = 8'h66;
    4'd5: digit = 8'h6D;
    4'd6: digit = 8'h7D;
    4'd7: digit = 8'h07;
    4'd8: digit = 8'h7F;
    4'd9: digit = 8'h6F;    
    default: digit = 8'h00;
    endcase
    
assign win_pat = win_valid ? digit : 8'h00;

//The output register. seg loads at every edge, so a change of the pattern, the mode, the winner or
//win_valid reaches the pins one edge later.
assign seg_next = seg_mode ? win_pat : seg_pat;
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        seg     <= 8'h40;
    else
        seg     <= seg_next;

endmodule
