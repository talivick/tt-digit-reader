// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// address_map.sv : the command codes, register addresses and status bits
//
// Description
//   A package of constants shared by the blocks: the command codes (CMD_ names), the
//   register addresses written with REG_WR (REG_ names, with the first and last address
//   of each block's range), ID's first byte, and the bit positions in the status bytes
//   S0, S1 and S2. The two numberings are independent: 0x10 is SEG_SHOW as a command
//   and MX_M as a register.
//
// Operation
//   A transfer is one command byte, then the command's argument bytes, then its response
//   bytes; REG_WR's first argument byte is the register address.
//   A module that decodes a command or a register address writes each name in full,
//   address_map::NAME, with no import statement.
//   The registers are write only: no command reads a register back. The status bits are
//   read through STATUS, which returns S0, S1 and S2.
//
// Reset
//   The package holds constants and has no reset. Of the registers it names, the screen
//   and SPI registers 0x00 to 0x05 and the teach registers 0x1E to 0x20 have reset
//   values; the matrix registers 0x10 to 0x1D have none, and the host writes them after
//   every reset, before the first MX_START.

package address_map;

// ---- command codes ----------------------------------------------------------------------------------
// accepted at any time (cmd_dec)
localparam logic [7:0] CMD_NOP         = 8'h00; // no arguments, no response
localparam logic [7:0] CMD_ID          = 8'h01; // response: 0x44, then {teach present, attract present, 6-bit form code}
localparam logic [7:0] CMD_STATUS      = 8'h02; // response: S0, S1, S2
localparam logic [7:0] CMD_CLR_ERR     = 8'h03; // clears the error flags of S1
localparam logic [7:0] CMD_REG_WR      = 8'h04; // arguments: register address, data byte
// 7-segment display (seg7)
localparam logic [7:0] CMD_SEG_SHOW    = 8'h10; // argument: the segment pattern {dp, g, f, e, d, c, b, a}; shown until SEG_WINNER
localparam logic [7:0] CMD_SEG_WINNER  = 8'h11; // shows the recognized digit
// matrix unit (ctrl, cmd_dec, mx_top)
localparam logic [7:0] CMD_MX_START    = 8'h20; // starts a run of MX_M rows
localparam logic [7:0] CMD_MX_ROW      = 8'h21; // arguments: a0, a1, one row of two INT8 values
localparam logic [7:0] CMD_MX_READ     = 8'h22; // response: {7'b0, v}, y0, y1; v = 1 when a result was waiting, else 0x00 bytes
// digit path (dp_acc, dp_img, dp_walk)
localparam logic [7:0] CMD_DIG_START   = 8'h30; // arguments: ten INT8 biases, class 0 first; clears the accumulators to them
localparam logic [7:0] CMD_IMG         = 8'h31; // arguments: sixteen bytes, the 8 by 8 image at 2 bits per pixel
localparam logic [7:0] CMD_TILE        = 8'h32; // arguments: {w01, w00}, {w11, w10}, four 4-bit weights; one tile of the inference
localparam logic [7:0] CMD_DIG_ARGMAX  = 8'h33; // picks the class with the largest accumulator
localparam logic [7:0] CMD_DIG_READ    = 8'h34; // response: S2, then the ten accumulators, high byte then low byte
// LCD (disp_seq)
localparam logic [7:0] CMD_DRAW_RECT   = 8'h40; // arguments: ten bytes, a filled rectangle: position, size, color
localparam logic [7:0] CMD_DRAW_IMG    = 8'h41; // arguments: fourteen bytes, the image: position, scale, the four pixel colors
localparam logic [7:0] CMD_DRAW_BARS   = 8'h42; // arguments: fifteen bytes, the ten accumulators as bars
localparam logic [7:0] CMD_DRAW_DIGIT  = 8'h43; // arguments: ten bytes, a digit in the 5 by 7 font: position, scale, colors
localparam logic [7:0] CMD_ATT_FRAME   = 8'h44; // arguments: six bytes; attract mode, not in this build
localparam logic [7:0] CMD_PT_CMD      = 8'h48; // argument: one byte sent to the LCD as a command (dc = 0)
localparam logic [7:0] CMD_PT_DAT      = 8'h49; // argument: one byte sent to the LCD as data (dc = 1)
// touch controller (touch_rd)
localparam logic [7:0] CMD_TP_READ     = 8'h50; // argument: the XPT2046 control byte; response: {4'b0, v[11:8]}, v[7:0]
// teach mode (teach, tch_ring)
localparam logic [7:0] CMD_TCH_CLEAR   = 8'h70; // clears the weights and the bias
localparam logic [7:0] CMD_TCH_SCORE   = 8'h71; // scores the image against the weights
localparam logic [7:0] CMD_TCH_LEARN   = 8'h72; // argument: the label in bit 0; updates the weights when the score is within the margin
localparam logic [7:0] CMD_TCH_READ    = 8'h73; // response: score high, score low, {7'b0, learned}, bias
localparam logic [7:0] CMD_TCH_MAP     = 8'h74; // arguments: fourteen bytes; draws the weights on the LCD as an image

// ---- register addresses, written with REG_WR ----------------------------------------------------------
// LCD opcodes and pixel format (disp_seq); the opcodes are the ILI9341's
localparam logic [7:0] REG_OP_CASET    = 8'h00; // reset 0x2A, column address set
localparam logic [7:0] REG_OP_PASET    = 8'h01; // reset 0x2B, page address set
localparam logic [7:0] REG_OP_RAMWR    = 8'h02; // reset 0x2C, memory write
localparam logic [7:0] REG_PIXFMT      = 8'h03; // bit 0: 0 = RGB565, 2 bytes per pixel; 1 = 18-bit color, 3 bytes per pixel
localparam logic [7:0] REG_DISP_FIRST  = 8'h00;
localparam logic [7:0] REG_DISP_LAST   = 8'h03;
// SPI bus (spi_master)
localparam logic [7:0] REG_SCKDIV      = 8'h04; // reset 0x71: SPI half period in clocks minus 1; [3:0] for the LCD, [7:4] for the touch
localparam logic [7:0] REG_GUARD       = 8'h05; // reset 0x4F: idle gap when the bus changes device, in steps of 64 clocks (0x4F = 202 us)
localparam logic [7:0] REG_SPI_FIRST   = 8'h04;
localparam logic [7:0] REG_SPI_LAST    = 8'h05;
// matrix unit settings (ctrl); no reset, written before a run
localparam logic [7:0] REG_MX_M        = 8'h10; // rows in one run; 0 ends the run at once
localparam logic [7:0] REG_MX_SCALE_LO = 8'h11; // the output scale, bits 7:0 (16-bit unsigned)
localparam logic [7:0] REG_MX_SHIFT    = 8'h12; // [4:0] the output shift, [7] the ReLU enable
localparam logic [7:0] REG_MX_BIAS0_HI = 8'h13; // column 0 bias, bit 16 in bit 0 (17-bit signed)
localparam logic [7:0] REG_MX_BIAS0_MID = 8'h14;    // column 0 bias, bits 15:8
localparam logic [7:0] REG_MX_BIAS0_LO = 8'h15; // column 0 bias, bits 7:0
localparam logic [7:0] REG_MX_BIAS1_HI = 8'h16; // column 1 bias, bit 16 in bit 0
localparam logic [7:0] REG_MX_BIAS1_MID = 8'h17;    // column 1 bias, bits 15:8
localparam logic [7:0] REG_MX_BIAS1_LO = 8'h18; // column 1 bias, bits 7:0
localparam logic [7:0] REG_MX_W00      = 8'h19; // INT8 weight of PE(0,0); a write loads the PE at once
localparam logic [7:0] REG_MX_W01      = 8'h1A; // PE(0,1)
localparam logic [7:0] REG_MX_W10      = 8'h1B; // PE(1,0)
localparam logic [7:0] REG_MX_W11      = 8'h1C; // PE(1,1)
localparam logic [7:0] REG_MX_SCALE_HI = 8'h1D; // the output scale, bits 15:8
localparam logic [7:0] REG_MX_FIRST    = 8'h10;
localparam logic [7:0] REG_MX_LAST     = 8'h1D;
// teach mode (teach)
localparam logic [7:0] REG_TSTEP       = 8'h1E; // reset 0x01: the learning step, bits 3:0
localparam logic [7:0] REG_TMARGIN_HI  = 8'h1F; // reset 0x00: the learning margin, bits 12:8 in bits 4:0
localparam logic [7:0] REG_TMARGIN_LO  = 8'h20; // reset 0x7C: the learning margin, bits 7:0 (reset margin 124)
localparam logic [7:0] REG_TEACH_FIRST = 8'h1E;
localparam logic [7:0] REG_TEACH_LAST  = 8'h20;

// ---- responses --------------------------------------------------------------------------------------
localparam logic [7:0] ID_BYTE0        = 8'h44; // ID's first byte; the second is {teach present, attract present, 6-bit form code}
// status byte S0, bit positions
localparam int S0_DISP_BUSY  = 0;
localparam int S0_WALK_BUSY  = 1;
localparam int S0_MX_BUSY    = 2;
localparam int S0_MX_DONE    = 3;
localparam int S0_RES_VALID  = 4;
localparam int S0_FIFO_COUNT = 5;   // bits 7:5, rows waiting in the FIFO, 0 to 2
// status byte S1
localparam int S1_ERR_CMD    = 0;   // unknown command, or a write to an unmapped register
localparam int S1_ERR_BUSY   = 1;   // a command refused because a run was in progress
localparam int S1_ERR_OVF    = 2;   // a row sent while the FIFO was full
localparam int S1_MX_ERR     = 3;   // a matrix command or register write while the matrix unit was busy
localparam int S1_RST_SEEN   = 7;   // 1 after a reset until STATUS supplies S1
// status byte S2
localparam int S2_WINNER     = 0;   // bits 3:0, the recognized digit
localparam int S2_WIN_VALID  = 7;

endpackage
