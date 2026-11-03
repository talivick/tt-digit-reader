// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// tch_ring.sv : the teach weight ring
//
// Description
//   Stores teach mode's 65 weights of 6 bits signed, w[0] to w[63] for pixels 0 to 63
//   and w[64] the bias, in a ring of plain flops that moves one place toward its head
//   every clock and never stops, so the next weight is ready on every clock with no
//   address and no read multiplexer.
//
// Operation
//   "tr_head" is the word at the head and "tr_hpos" its index, 0 to 64.
//   At each edge the tail, word 64, takes what "tr_sel" names: 0 or 3 the head (keep),
//   1 "tr_in" (an updated weight), 2 zero (clear).
//   Every link carries one instantiated delay cell, sky130_fd_sc_hd__dlygate4sd3_1 with
//   the instance name dly, which meets hold time at the fast corner. The name is dly
//   and nothing else: src/config.json keeps the resizer off cells whose name ends in
//   .dly. The RTL simulation reads the stub test/dly_stub.v in place of the cell.
//
// Timing
//   A weight passes the head once every 65 clocks, which is when it is scored, updated,
//   cleared or read.
//
// Reset
//   "rst_n" is asynchronous and active low and resets "tr_hpos" to 0 only. The 390 bits
//   of weights have no reset and no enable; the host clears them with TCH_CLEAR after
//   every reset.

`default_nettype none

module tch_ring (
    input  logic              clk,      //rising edge
    input  logic              rst_n,    //asynchronous, active low; resets tr_hpos only
    input  logic        [1:0] tr_sel,   //what the tail takes: 0 or 3 the head (keep), 1 tr_in (update), 2 zero (clear)
    input  logic signed [5:0] tr_in,    //the updated weight
    output logic signed [5:0] tr_head,  //the word at the head
    output logic        [6:0] tr_hpos   //the index of the word at the head: 0 to 63 a pixel's weight, 64 the bias
);

logic [389:0] ring;
logic [5:0] tail;
logic [383:0] delayed;
genvar q;
genvar b;

// The value the tail takes. The tail is word 64, the word farthest from the head. At every edge it takes what tr_sel
// names: 1 the updated weight tr_in, 2 zero, 0 or 3 the head, so a weight that is neither updated nor cleared goes
// around the ring unchanged.
always_comb
    case(tr_sel)
    2'd1:    tail = tr_in;
    2'd2:    tail = 6'd0;
    default: tail = tr_head;
    endcase


// The 64 links between each word and the next, one delay cell per bit. The cell takes bit b of word q + 1 and gives
// it, delayed, to bit b of word q; its hierarchical name is links[q].bits[b].dly. The ring's flops feed each other
// with no logic between them, so at the fast corner the new value could reach the next flop before the clock edge
// that must still capture the old one, a hold-time failure; the delay cell gives each link the hold time it needs.
// The chip's build keeps every cell whose name ends in .dly as it is (src/config.json). The RTL simulation reads
// the stub test/dly_stub.v, a plain wire, in place of the cell.
generate
    for (q = 0; q < 64; q = q + 1)
    begin: links
        for (b = 0; b < 6; b = b + 1)
        begin: bits
            sky130_fd_sc_hd__dlygate4sd3_1 dly (
                .A(ring[6 * q + 6 + b]),            //bit b of word q + 1
                .X(delayed[6 * q + b])              //its delayed copy, into bit b of word q
            );
        end
    end
endgenerate


// The ring: 65 words of 6 bits, word 0 at the head in bits 5:0, word 64 at the tail in bits 389:384. At every edge
// every word moves one place toward the head and word 64 takes tail. No reset and no enable: the host's TCH_CLEAR
// puts zero in every word before the first score.
always_ff @(posedge clk)
    ring <= {tail, delayed};

assign tr_head = ring[5:0];                         //the word at the head, 6-bit two's complement


// The head's index. tr_hpos counts the edges, 0 to 64 and back to 0, so it names the word at the head: the ring and
// the counter both have a period of 65 edges. A word written at the tail while tr_hpos is n is at the head 65 edges
// later, when tr_hpos is n again.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tr_hpos     <= 7'd0;
    else
        tr_hpos     <= (tr_hpos == 7'd64) ? 7'd0 : tr_hpos + 7'd1;     //the next word; after 64 comes 0

endmodule
