// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// fifo.sv : two-entry FIFO with the head shown without a read clock.
// Project: Digit reader on Tiny Tapeout SKY26d.
//
// Notes on module fifo
//   The storage has no reset. A push and a pop in the same clock are allowed.
//   count is 2 bits, sized for DEPTH = 2.

`default_nettype none

module fifo #(
    parameter DEPTH = 2,    //entries
    parameter WIDTH = 16    //bits per entry
) (
    input  logic             clk,       //rising edge
    input  logic             rst_n,     //asynchronous, active low; resets the pointers and count
    input  logic             wr_valid,  //push when wr_valid and wr_ready
    input  logic [WIDTH-1:0] wr_data,   //the entry pushed
    output logic             wr_ready,  //not full
    output logic             rd_valid,  //the head is valid (not empty)
    output logic [WIDTH-1:0] rd_data,   //the head, shown without a read clock
    input  logic             rd_ready,  //pop when rd_valid and rd_ready
    output logic [1:0]       count      //0 to 2
);

//registers
logic [15:0] entry [1:0];
logic wr_sel;
logic rd_sel;

//wires
logic push;
logic pop;

assign wr_ready = (count != 2'd2);  // not full
assign push = wr_valid & wr_ready;  //a row enters this clock

always_ff @(posedge clk or negedge rst_n)
    begin
    if(~rst_n)
        wr_sel  <= 1'b0;
    else if(push)
        wr_sel  <= ~wr_sel;         //the write pointer
    end
    
always_ff @(posedge clk or negedge rst_n)
    begin       
    if(~rst_n)
        rd_sel  <= 1'b0;
    else if(pop)
        rd_sel  <= ~rd_sel;         //the read pointer
    end
    
always_ff @(posedge clk or negedge rst_n)
    begin       
    if(~rst_n)
        count <= '0;
    else if(push & ~pop)
        count <= count + 2'd1;      //the fifo count
    else if(pop & ~push)
        count <= count - 2'd1;
    end
    
always_ff @(posedge clk)
    begin
    if(push)
        entry[wr_sel] <= wr_data; //no reset  the two rows
    end
    
assign rd_data = entry[rd_sel];     //the head; a mux, not a register: no read clock 
assign rd_valid = (count != 2'd0);  //not empty
assign pop = rd_valid && rd_ready;  //the head leaves this clock

endmodule
