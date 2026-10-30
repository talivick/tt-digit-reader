// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// project.v : the top level of the chip
//
// Description
//   The chip holds an INT8 2x2 matrix unit, a digit reader that runs on it, teach mode,
//   a screen and touch driver on one SPI bus and a 7-segment readout, on Tiny Tapeout
//   SKY26d (sky130, 3x2 tiles, 25 MHz). This file maps the blocks onto the template's
//   pins and joins them; it holds no flop of its own.
//
// Parameters
//   HAS_DIGIT, HAS_DISPLAY, HAS_TEACH and HAS_ATTRACT choose the blocks built, and
//   Tiny Tapeout's flow builds the defaults. The chip is 1, 1, 1 and 0, ID form code 1.
//   The fallback, the matrix unit alone, is all 0, code 2; the bench form is
//   HAS_DISPLAY alone, code 3; the digit reader without the display is HAS_DIGIT
//   alone, code 4.
//
// Operation
//   The host sends every command as bytes on "ui_in", one byte per four-phase
//   handshake: it sets "ui_in", raises "in_valid" ("uio_in" bit 7), waits for
//   "in_ready" ("uio_out" bit 6) high, reads "uo_out" when the byte is a response,
//   lowers "in_valid" and waits for "in_ready" low. No byte is taken until "in_valid"
//   has been low after reset. During a response "ui_in" carries 0x00.
//   Between responses "uo_out" shows the 7-segment pattern {dp, g, f, e, d, c, b, a}.
//   "uio_out" bits 0 to 4 are the SPI lines "sck", "mosi", "dc", "cs_lcd_n" and
//   "cs_tp_n"; "uio_in" bit 5 is the touch data. "uio_oe" is 0x5F; "ena" is not used.
//
// Reset
//   "rst_n" is active low and asynchronous at the pad. It passes the reset synchronizer, so every
//   flop with a reset takes its reset value at once when "rst_n" falls and is released
//   on the second or third "clk" edge after it rises. "in_valid" and the touch data
//   each pass a two-flop synchronizer. In reset "uo_out" is 0x40, segment g alone, and
//   "uio_out" is 0x1C: "sck", "mosi" and "in_ready" 0, "dc" and both selects 1. Data
//   registers have no reset, and the host writes its data again after every reset.

`default_nettype none

module tt_um_talivick_digit_reader #(
    parameter bit HAS_DIGIT = 1'b0,    //1 builds the digit reader (dp_img, dp_walk, dp_acc); 0 in the safety-net submission
    parameter bit HAS_DISPLAY = 1'b0,  //1 builds the display (spi_master, disp_seq, touch_rd)
    parameter bit HAS_TEACH = 1'b0,    //1 builds teach mode (tch_ring, teach)
    parameter bit HAS_ATTRACT = 1'b0   //1 builds attract mode (attract); 0 in the chip
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

// the synchronizers
logic               rst_n_s;
logic               in_valid_s;
logic               miso_s;
// cmd_dec's outputs
logic               in_ready;
logic        [7:0]  resp_byte;
logic               resp_oe;
logic        [7:0]  cmd;
logic               arg_we;
logic        [3:0]  arg_idx;
logic        [7:0]  arg_byte;
logic               go;
logic               reg_we;
logic        [7:0]  reg_addr;
logic        [7:0]  reg_wdata;
logic               mx_start;
logic               err_clr;
logic               row_valid;
logic        [15:0] row_data;
logic               res_ready;
logic               dec_acc_req;
logic        [3:0]  dec_acc_idx;
// ctrl's outputs
logic               stream_en;
logic        [3:0]  mx_w_ld;
logic        [7:0]  mx_w;
logic signed [16:0] bias0;
logic signed [16:0] bias1;
logic        [15:0] scale;
logic        [4:0]  shift;
logic               relu;
logic               mx_busy;
logic               mx_done;
logic               mx_err;
// mx_top's outputs
logic               row_ready;
logic               res_valid;
logic        [15:0] res_data;
logic               row_pop;
logic               res_pop;
logic        [1:0]  fifo_count;
logic        [33:0] dp_p;
logic               dp_p_valid;
logic signed [17:0] ma_q;
logic               ma_neg;
// seg7's output
logic        [7:0]  seg;
//  the display's nets (spi_master, disp_seq, touch_rd): tied in without_display
logic               sck;
logic               mosi;
logic               dc;
logic               cs_lcd_n;
logic               cs_tp_n;
logic               ds_busy;
logic               tp_busy;
logic               spi_busy;
logic        [11:0] tp_value;
logic               tp_valid;
// the digit reader's nets (dp_walk, dp_acc): tied in without_digit
logic               wk_busy;
logic               am_busy;
logic               wk_sel;
logic        [3:0]  wk_w_ld;
logic        [31:0] wk_w;
logic        [15:0] wk_a;
logic               wk_a_valid;
logic signed [11:0] acc_val;
logic               acc_ack;
logic        [3:0]  winner;
logic               win_valid;
logic               am_done;
// teach mode's nets (teach): tied in without_teach
logic               t_busy;
logic               tch_sel;
logic        [3:0]  tch_w_ld;
logic        [31:0] tch_w;
logic        [15:0] tch_a;
logic               tch_ma_sel;
logic               tch_ma_we;
logic               tch_ma_clr;
logic               tch_ma_pe;
logic signed [16:0] tch_ma_b;
logic signed [15:0] tch_score;
logic               tch_learned;
logic signed [7:0]  tch_bias;
logic               tch_bias_ok;
// attract mode's nets (attract): tied in without_attract
logic               att_busy;
logic               att_sel;
logic        [3:0]  att_w_ld;
logic        [31:0] att_w;
logic        [15:0] att_a;
logic               att_ma_sel;
logic               att_ma_we;
logic               att_ma_clr;
logic               att_ma_pe;
logic signed [16:0] att_ma_b;
// the nets that join the blocks
logic               disp_busy;
logic               walk_busy;
logic               dp_sel;
logic        [3:0]  dp_w_ld;
logic        [31:0] dp_w;
logic        [15:0] dp_a;
logic               dp_a_valid;
logic               ma_sel;
logic               ma_we;
logic               ma_clr;
logic               ma_pe;
logic signed [16:0] ma_b;

//The three synchronizers, all instances of sync2. i_rst_sync makes the chip's reset: its d is tied to 1 and it
//resets to 0, so rst_n_s falls at once when the pad's rst_n falls and rises on the second or third clock edge after
//rst_n rises. Its two flops are the only ones the pad's rst_n reaches; every other flop with a reset takes rst_n_s,
//the other two synchronizers included. i_sync_valid resets to 1, so a pin held high through a reset is not read as a
//byte; i_sync_miso resets to 0. ui_in has no synchronizer: the host holds it steady whenever the chip samples it.
sync2 #(.RST_VAL (1'b0)) i_rst_sync (.clk, .rst_n, .d(1'b1), .q(rst_n_s));

sync2 #(.RST_VAL (1'b1)) i_sync_valid (.clk, .rst_n(rst_n_s), .d(uio_in[7]), .q(in_valid_s));

sync2 #(.RST_VAL (1'b0)) i_sync_miso (.clk, .rst_n(rst_n_s), .d(uio_in[5]), .q(miso_s));

//The command decoder. It runs the handshake with the host, splits each transfer into the command byte, its
//arguments and its responses, answers ID and STATUS itself, and drives the command bus and the register bus to
//the blocks. The four parameters set which commands and registers it knows, and ID's second byte.
cmd_dec #(
    .HAS_DIGIT (HAS_DIGIT),      //digit path present (sets the form code in ID); parameter bit: one bit in ID's byte
    .HAS_DISPLAY (HAS_DISPLAY),  //display path present
    .HAS_TEACH (HAS_TEACH),      //teach mode present (ID bit 7)
    .HAS_ATTRACT (HAS_ATTRACT)   //attract mode present (ID bit 6); 0 in this chip
    ) i_cmd_dec (
    .clk,              //rising edge
    .rst_n (rst_n_s),  //asynchronous, active low; resets the handshake state, ARMED and the status bits
    .in_valid_s,       //the synchronized in_valid
    .ui_in,            //the host byte
    .in_ready,         //to uio_out[6]
    .resp_byte,        //the response byte
    .resp_oe,          //select the response onto uo_out
    .cmd,              //the command byte; command bus to the blocks
    .arg_we,           //pulse: an argument byte is on arg_byte
    .arg_idx,          //the argument's index, 0 first
    .arg_byte,         //the argument byte
    .go,               //pulse: the command is complete, after its last argument
    .reg_we,           //register write strobe; register bus (REG_WR)
    .reg_addr,         //register address
    .reg_wdata,        //register write data
    .mx_start,         //pulse to ctrl: start a run
    .err_clr,          //pulse to ctrl: clear mx_err
    .row_valid,        //MX_ROW: a row is offered to mx_top
    .row_data,         //the row
    .row_ready,        //from mx_top
    .res_valid,        //MX_READ: a result is ready
    .res_data,         //the result
    .res_ready,        //pops the result
    .fifo_count,       //status input
    .mx_busy,          //status input
    .mx_done,          //status input
    .mx_err,           //status input
    .disp_busy,        //hold input: the display is busy
    .walk_busy,        //hold input: the walker is busy
    .tp_value,         //TP_READ's value
    .tp_valid,         //valid of tp_value
    .dec_acc_req,      //DIG_READ's request to the accumulator ring
    .dec_acc_idx,      //the accumulator requested
    .acc_val,          //the ring's head
    .acc_ack,          //the head is the one requested
    .winner,           //the argmax winner (DIG_READ and S2)
    .win_valid,        //valid of winner
    .tch_score,        //TCH_READ: the score
    .tch_learned,      //TCH_READ: LEARNED
    .tch_bias,         //TCH_READ: the bias word
    .tch_bias_ok       //TCH_READ: the bias word is at the ring's head
    );

//The matrix control. It holds the matrix registers, counts the rows of a run and lets them stream into the
//array, and reports mx_busy, mx_done and mx_err.
ctrl i_ctrl(
    .clk,                   //rising edge
    .rst_n (rst_n_s),       //asynchronous, active low; resets the state machine and the status bits; the configuration registers have no reset
    .reg_we,                //register write strobe; ctrl owns 0x10 to 0x1D
    .reg_addr,              //register address
    .reg_wdata,             //register write data
    .mx_start,              //pulse from cmd_dec: start a run
    .err_clr,               //pulse from cmd_dec: clear mx_err
    .row_pop,               //from mx_top: a row entered the array
    .res_pop,               //from mx_top: a result left
    .stream_en,             //to mx_top
    .mx_w_ld,               //a write to 0x19, 0x1A, 0x1B, 0x1C pulses bit 0, 1, 2, 3 in its data clock
    .mx_w,                  //= reg_wdata in that clock
    .bias0,                 //the column 0 bias (MX_BIAS0_HI, MX_BIAS0_MID, MX_BIAS0_LO)
    .bias1,                 //the column 1 bias (MX_BIAS1_HI, MX_BIAS1_MID, MX_BIAS1_LO)
    .scale,                 //the unsigned scale (MX_SCALE_LO, MX_SCALE_HI)
    .shift,                 //S, the shift count (MX_SHIFT bits 4:0)
    .relu,                  //the ReLU enable (MX_SHIFT bit 7)
    .mx_busy,               //status: a run in progress
    .mx_done,               //status: the last run finished
    .mx_err                 //status: an error since the last err_clr
    );

//The matrix unit: the row FIFO, the 2x2 array and the requant stage. Host rows enter through the FIFO. The digit
//reader, teach mode and attract mode enter through the dp_ port, and the two modes reach the requant stage
//through the ma_ port.
mx_top i_mx_top(
    .clk,                   //rising edge
    .rst_n (rst_n_s),       //asynchronous, active low; resets passed to the FIFO, the array and the requant unit (no registers of its own)
    .row_valid,             //a row is offered
    .row_data,              //the row {a1, a0} into the FIFO
    .row_ready,             //FIFO not full
    .res_valid,             //a result is ready
    .res_data,              //the result {y1, y0}
    .res_ready,             //pops the result
    .stream_en,             //pops from the FIFO allowed (ctrl)
    .row_pop,               //pulse: a row entered the array
    .res_pop,               //pulse: a result left
    .mx_w_ld,               //REG_WR weight write: bit 2r + c loads PE(r, c) with mx_w
    .mx_w,                  //the weight written
    .bias0,                 //configuration from ctrl
    .bias1,                 //configuration from ctrl
    .scale,                 //configuration from ctrl
    .shift,                 //configuration from ctrl
    .relu,                  //configuration from ctrl
    .fifo_count,            //FIFO occupancy
    .dp_sel,                //the tile walker, teach, or attract owns the array
    .dp_w_ld,               //weight loads through the dp_ port (layout as the array's w_ld)
    .dp_w,                  //the weights through the dp_ port (layout as the array's w_in)
    .dp_a,                  //one row through the dp_ port
    .dp_a_valid,            //valid of dp_a
    .dp_p,                  //column sums
    .dp_p_valid,            //valid of dp_p, only while dp_sel = 1
    .ma_sel,                //to requant
    .ma_we,                 //to requant
    .ma_clr,                //to requant
    .ma_pe,                 //to requant
    .ma_b,                  //the modes' addend, to requant
    .ma_q,                  //PH, from requant
    .ma_neg                 //sign of the 19-bit sum, from requant
    );

//The 7-segment readout. seg is the pattern on uo_out whenever no response is on it: a pattern the host wrote, or
//the digit the argmax picked.
seg7 i_seg7 (
    .clk,                   //rising edge
    .rst_n (rst_n_s),       //asynchronous, active low; resets seg to 0x40 and the mode
    .cmd,                   //the command byte; SEG_SHOW, SEG_WINNER
    .arg_we,                //pulse: an argument byte is on arg_byte
    .arg_byte,              //the argument byte
    .go,                    //pulse: the command is complete, after its last argument
    .am_done,               //argmax done pulse, from dp_acc
    .winner,                //the winner, from dp_acc
    .win_valid,             //valid of winner
    .seg                    //registered {dp, g, f, e, d, c, b, a}, active high; reset 0x40
    );

//The blocks not built. One if block per parameter. When a block is not built, the else block ties every net it
//would drive: the SPI lines to their idle levels, every other net to 0, so the rest of the chip sees no busy, no
//valid and no request from it.
generate
  if(HAS_DISPLAY)
  begin: with_display
  end
  else
  begin: without_display
      assign sck      = 1'b0;
      assign mosi     = 1'b0;
      assign dc       = 1'b1;
      assign cs_lcd_n = 1'b1;
      assign cs_tp_n  = 1'b1;
      assign ds_busy  = 1'b0;
      assign tp_busy  = 1'b0;
      assign spi_busy = 1'b0;
      assign tp_value = 12'd0;
      assign tp_valid = 1'b0;
  end

  if(HAS_DIGIT)
  begin: with_digit
  end
  else
  begin: without_digit
      assign wk_busy    = 1'b0;
      assign am_busy    = 1'b0;
      assign wk_sel     = 1'b0;
      assign wk_w_ld    = 4'd0;
      assign wk_w       = 32'd0;
      assign wk_a       = 16'd0;
      assign wk_a_valid = 1'b0;
      assign acc_val    = 12'd0;
      assign acc_ack    = 1'b0;
      assign winner     = 4'd0;
      assign win_valid  = 1'b0;
      assign am_done    = 1'b0;
  end

  if(HAS_TEACH)
  begin: with_teach
  end
  else
  begin: without_teach
      assign t_busy      = 1'b0;
      assign tch_sel     = 1'b0;
      assign tch_w_ld    = 4'd0;
      assign tch_w       = 32'd0;
      assign tch_a       = 16'd0;
      assign tch_ma_sel  = 1'b0;
      assign tch_ma_we   = 1'b0;
      assign tch_ma_clr  = 1'b0;
      assign tch_ma_pe   = 1'b0;
      assign tch_ma_b    = 17'd0;
      assign tch_score   = 16'd0;
      assign tch_learned = 1'b0;
      assign tch_bias    = 8'd0;
      assign tch_bias_ok = 1'b0;
  end

  if(HAS_ATTRACT)
  begin: with_attract
  end
  else
  begin: without_attract
      assign att_busy   = 1'b0;
      assign att_sel    = 1'b0;
      assign att_w_ld   = 4'd0;
      assign att_w      = 32'd0;
      assign att_a      = 16'd0;
      assign att_ma_sel = 1'b0;
      assign att_ma_we  = 1'b0;
      assign att_ma_clr = 1'b0;
      assign att_ma_pe  = 1'b0;
      assign att_ma_b   = 17'd0;
  end
endgenerate

//The nets that join the blocks. disp_busy and walk_busy make the decoder hold its next command byte. The dp_ port
//and the ma_ port are shared: one block drives a port at a time and the others drive 0, so each OR passes the
//active block's value. dp_a_valid is the tile walker's alone; teach mode and attract mode present no valid.
assign disp_busy  = ds_busy | tp_busy | spi_busy;
assign walk_busy  = wk_busy | am_busy | t_busy | att_busy;
assign dp_sel     = wk_sel | tch_sel | att_sel;
assign dp_w_ld    = wk_w_ld | tch_w_ld | att_w_ld;
assign dp_w       = wk_w | tch_w | att_w;
assign dp_a       = wk_a | tch_a | att_a;
assign dp_a_valid = wk_a_valid;
assign ma_sel     = tch_ma_sel | att_ma_sel;
assign ma_we      = tch_ma_we | att_ma_we;
assign ma_clr     = tch_ma_clr | att_ma_clr;
assign ma_pe      = tch_ma_pe | att_ma_pe;
assign ma_b       = tch_ma_b | att_ma_b;

//The pins. uo_out carries the response while resp_oe is 1 and the 7-segment pattern otherwise. uio bits 5 and 7
//are inputs; their output path reads 0.
assign uo_out  = resp_oe ? resp_byte : seg;

assign uio_out = {1'b0, in_ready, 1'b0, cs_tp_n, cs_lcd_n, dc, mosi, sck};

assign uio_oe  = 8'b0101_1111;

//The inputs and outputs nothing reads in this form, gathered in one reduction as the template does, so the lint
//does not report them.
wire unused = &{1'b0, ena, uio_in[6], uio_in[4:0], miso_s, arg_idx, dp_p, dp_p_valid, ma_q, ma_neg, dec_acc_req, dec_acc_idx};


endmodule
