// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// touch_rd.sv : the touch reader
//
// Description
//   Runs TP_READ: one 3-byte frame to the XPT2046-protocol touch controller, which
//   returns one raw 12-bit conversion of the channel that the control byte picks.
//
// Operation
//   TP_READ's argument, the control byte, arrives on "arg_byte" with "arg_valid", and its
//   "go_ps" starts the read and raises "tp_busy".
//   The frame is the control byte, 0x00 and 0x00, each offered on "tp_tx_byte" with
//   "tp_tx_valid" until "tp_tx_ready_ps" takes it, with "tp_tx_last" on the third; the top
//   sends it to the touch controller with "dc" high.
//   The second and third bytes received ("rx_byte" with "rx_valid") form "tp_value";
//   "tp_valid" rises with the third byte and holds until the next TP_READ's "go_ps".
//   The control bytes for 12-bit differential reads are X 0xD0, Y 0x90, Z1 0xB0, Z2 0xC0.
//
// Timing
//   A read is 408 clocks at the touch's reset half period, H = 8 (16.32 us), plus the
//   guard when the previous frame went to the screen or it is the first frame since
//   reset. "tp_busy" is high from "go_ps" until the value is stored.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets "tp_value" and "tp_valid" to 0
//   and the read's state to idle. The control byte has no reset; TP_READ writes it.

`default_nettype none

module touch_rd (
    input  logic        clk,             //rising edge
    input  logic        rst_n,           //asynchronous, active low; resets the state and tp_valid
    input  logic [7:0]  cmd,             //the command byte; TP_READ and its control byte
    input  logic        arg_valid,       //pulse: an argument byte is on arg_byte
    input  logic [7:0]  arg_byte,        //the argument byte
    input  logic        go_ps,           //pulse: the command is complete, after its last argument
    output logic        tp_tx_valid,     //byte request to spi_master (the top adds tx_dev = 1, tx_dc = 1)
    output logic [7:0]  tp_tx_byte,      //the byte to send
    output logic        tp_tx_last,      //ends the frame
    input  logic        tp_tx_ready_ps,  //spi_master's tx_ready_ps, gated by the top
    input  logic [7:0]  rx_byte,         //the byte received, from spi_master
    input  logic        rx_valid,        //pulse: rx_byte is valid
    output logic [11:0] tp_value,        //the last conversion
    output logic        tp_valid,        //1 from the conversion's end until the next TP_READ's go_ps
    output logic        tp_busy          //from go_ps until the value is stored
);

logic [7:0] control;
logic [1:0] bytes_sent;
logic [1:0] bytes_rcvd;
logic tp_go_ps;
logic tp_take_ps;
logic got_rx_ps;
logic store_ps;


// The control byte, TP_READ's one argument. It names the channel the touch controller converts: X 0xD0, Y 0x90,
// Z1 0xB0, Z2 0xC0. No reset, because every TP_READ writes it before its go_ps.
always_ff @(posedge clk)
    if(arg_valid & (cmd == address_map::CMD_TP_READ))
        control     <= arg_byte;

//the read starts: TP_READ's go_ps, after its control byte
assign tp_go_ps = go_ps & (cmd == address_map::CMD_TP_READ);


// The read in progress. tp_busy is 1 from the go_ps until the store_ps, the clock in which the third byte back lands in
// tp_value. The top feeds it into the decoder's DISP_BUSY bit, which holds the next command until this read ends.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tp_busy     <= 1'b0;
    else if(tp_go_ps)
        tp_busy     <= 1'b1;
    else if(store_ps)
        tp_busy     <= 1'b0;                //the third byte is back: the read ends


// The frame out: three bytes to spi_master, the control byte and two zeros. bytes_sent counts the bytes taken,
// 0 to 3. A byte is offered while the read runs and the three are not all taken; the third carries tp_tx_last, which
// ends the frame. The zeros keep mosi low after the control byte, so the controller sees no second start bit while
// it answers.
always_ff @(posedge clk)
    if(tp_go_ps)
        bytes_sent  <= 2'd0;                //a new frame
    else if(tp_take_ps)
        bytes_sent  <= bytes_sent + 2'd1;   //one more byte taken

assign tp_tx_valid = tp_busy & (bytes_sent != 2'd3);         //a byte is offered until all three are taken

assign tp_tx_byte = (bytes_sent == 2'd0) ? control : 8'h00;  //the control byte first, then the zeros

assign tp_tx_last = (bytes_sent == 2'd2);                    //the third byte ends the frame

assign tp_take_ps = tp_tx_valid & tp_tx_ready_ps;            //spi_master takes the offered byte this clock


// The bytes back: spi_master returns one received byte for each byte sent, and bytes_rcvd counts them, 0 to 2. The
// controller's answer begins with one zero bit after the control byte, so the 12 data bits straddle the second and
// third bytes:
//
//    byte back             bit 7    6    5    4    3    2    1    0
//    first, bytes_rcvd 0   not data: the controller is still taking the control byte      ignored
//    second, bytes_rcvd 1    0     D11  D10  D9   D8   D7   D6   D5                       bits 6:0 to tp_value[11:5]
//    third, bytes_rcvd 2     D4    D3   D2   D1   D0   0    0    0                        bits 7:3 to tp_value[4:0]
always_ff @(posedge clk)
    if(tp_go_ps)
        bytes_rcvd  <= 2'd0;                //a new frame
    else if(got_rx_ps)
        bytes_rcvd  <= bytes_rcvd + 2'd1;   //one more byte back

assign got_rx_ps = tp_busy & rx_valid;                   //a byte came back during the read

assign store_ps = got_rx_ps & (bytes_rcvd == 2'd2);      //the third byte is back: the value is complete


// The value and its flag. tp_value takes the two data bytes as they land, so it is complete at the store_ps. tp_valid
// rises with the store_ps and holds until the next TP_READ's go_ps; the decoder supplies TP_READ's response bytes only
// while it is 1.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tp_value        <= 12'd0;
    else if(got_rx_ps & (bytes_rcvd == 2'd1))
        tp_value[11:5]  <= rx_byte[6:0];    //D11 to D5 from the second byte
    else if(store_ps)
        tp_value[4:0]   <= rx_byte[7:3];    //D4 to D0 from the third

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tp_valid    <= 1'b0;
    else if(tp_go_ps)
        tp_valid    <= 1'b0;                //a new read: the old value is stale
    else if(store_ps)
        tp_valid    <= 1'b1;                //the value is complete

endmodule
