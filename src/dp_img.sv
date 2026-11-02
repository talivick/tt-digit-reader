// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// dp_img.sv : the image ring
//
// Description
//   Stores the 8 by 8 input image, 64 pixel codes of 2 bits in 16 bytes, in a ring of 16
//   places. The head is the one place that is read. A step moves every byte one place
//   toward the head, and the byte that was at the head goes around to the tail, the place
//   at the far end. The ring serves the image at the head, one pixel pair at a time to
//   the tile walker and the display and one byte at a time to teach mode, and so
//   replaces a read multiplexer.
//
// Operation
//   IMG's 16 bytes arrive on "arg_byte" with "arg_we"; byte k holds pixels 4k to 4k + 3,
//   pixel 4k + j in bits [2j+1:2j], and after the 16th byte, byte 0 is at the head.
//   Request pair i, pixels 2i and 2i + 1, with "pair_req" high and "pair_idx" = i: the
//   ring steps one byte per clock until the pair's byte is at the head, then "pair_ack"
//   is high with {code(2i+1), code(2i)} on "pair".
//   One user drives the ring on any clock; the commands that drive it never overlap.
//
// Timing
//   A read waits at most 15 clocks, one per step.
//
// Modes
//   Teach mode moves byte 0 to the head with "img_seek0" ("img_at0" high when it is
//   there), steps one byte with "img_step" and reads "img_head0". Attract mode splits
//   the ring with "img_split" into two 8-byte rings, bytes 0 to 7 and 8 to 15, shifted
//   by "img_en_a" and "img_en_b" with tails "img_tail_a" and "img_tail_b", and read at
//   "img_head0" and "img_head8"; its frame overwrites the image.
//
// Reset
//   "rst_n" is asynchronous and active low and resets the ring position to 0. The 128
//   bits of image have no reset; the host writes them with IMG before use.

`default_nettype none

module dp_img(
    input  logic       clk,         //rising edge
    input  logic       rst_n,       //asynchronous, active low; resets ipos only
    input  logic [7:0] cmd,         //the command byte; IMG bytes
    input  logic       arg_we,      //pulse: an argument byte is on arg_byte
    input  logic [7:0] arg_byte,    //the argument byte
    input  logic       pair_req,    //read request for pair pair_idx
    input  logic [4:0] pair_idx,    //i: the pair {code(2i+1), code(2i)}
    output logic [3:0] pair,        //the pair
    output logic       pair_ack,    //1 while the pair's byte is at the head and pair_req = 1
    input  logic       img_seek0,   //teach: move byte 0 to the head
    input  logic       img_step,    //teach: step one byte
    input  logic       img_split,   //attract: two 8-byte rings, bytes 0 to 7 (A) and 8 to 15 (B)
    input  logic       img_en_a,    //attract: shift ring A (bytes 0 to 7)
    input  logic [7:0] img_tail_a,  //what ring A's tail takes
    input  logic       img_en_b,    //attract: shift ring B (bytes 8 to 15)
    input  logic [7:0] img_tail_b,  //what ring B's tail takes
    output logic [7:0] img_head0,   //ring[0], the head
    output logic [7:0] img_head8,   //ring[8]
    output logic       img_at0      //the head is byte 0
);

logic [63:0]    ring_b;
logic [63:0]    ring_a;
logic [3:0]     ipos;
logic           load;
logic           in_place;
logic           step;
logic [7:0]     new15;
logic           move_b;
logic [7:0]     new7;
logic           move_a;

//Image load: each byte of IMG enters at the tail, ring[15], and every byte already stored moves one place
//toward the head. After the sixteenth byte the image lies in order, byte 0 at the head, and the position
//counter is back at 0.
assign load = arg_we & (cmd == address_map::CMD_IMG);

//Ring step: a step moves every byte one place toward the head, and the byte that was at the head goes around
//to the tail. ipos counts the steps, so it is the index of the byte at the head. The ring steps for a pair
//request until the pair's byte is at the head, for a seek until byte 0 is at the head, and once for each
//img_step.
assign in_place = (ipos == pair_idx[4:1]);      //the requested pair's byte, byte i div 2, is at the head
assign img_at0 = (ipos == 4'd0);
assign step = (pair_req & ~in_place) | (img_seek0 & ~img_at0) | img_step;

//Ring buffer: the 16 bytes are stored in two 64-bit registers. ring_a holds bytes 0 to 7 with the head in its
//low byte, and ring_b holds bytes 8 to 15. In normal use they act as one ring of 16: ring_b's tail takes the
//head's byte, or the IMG byte, and ring_a's tail takes ring_b's low byte. When attract mode splits them, each
//is a ring of 8 that moves on its own enable and takes its own tail byte. The 128 bits have no reset; the host
//writes them before use.
assign new15 = load ? arg_byte : (img_split ? img_tail_b : ring_a[7:0]);    //what byte 15, ring_b's tail, takes
assign move_b = load | step | (img_split & img_en_b);                       //ring_b moves this clock
always_ff @(posedge clk)
    if(move_b)
        ring_b  <= {new15, ring_b[63:8]};

assign new7 = img_split ? img_tail_a : ring_b[7:0];      //what byte 7, ring_a's tail, takes
assign move_a = load | step | (img_split & img_en_a);    //ring_a moves this clock
always_ff @(posedge clk)
    if(move_a)
        ring_a  <= {new7, ring_a[63:8]};

//Position counter: ipos resets to 0, goes up by one with every step, returns to 0 with every IMG byte, and
//does not move while the ring is split.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        ipos    <= 4'd0;
    else if(load)
        ipos    <= 4'd0;
    else if(step)
        ipos    <= ipos + 1'd1;

//Read port: a pair request is acknowledged while its byte is at the head. The pair is the low half or the high
//half of the head's byte, chosen by bit 0 of the index. img_head0 and img_head8 are the low bytes of ring_a
//and ring_b.
assign pair_ack = pair_req & in_place;
assign pair = pair_idx[0] ? ring_a[7:4] : ring_a[3:0];

assign img_head0 = ring_a[7:0];
assign img_head8 = ring_b[7:0];

endmodule
