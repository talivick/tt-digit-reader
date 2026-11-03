// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// disp_seq.sv : the display sequencer
//
// Description
//   Turns each drawing command into one screen frame of window writes and pixels, with
//   no frame buffer: every byte is computed as it goes out through spi_master. It draws
//   rectangles, the 8 by 8 image, ten bars, 5 by 7 digits and the teach weight map, and
//   sends the pass-through bytes.
//
// Parameters
//   HAS_ATTRACT 1 builds the ATT_FRAME path, whose colors come from attract on the
//   "att_" ports; HAS_ATTRACT 0, the value in the chip, leaves it out.
//
// Operation
//   The "reg_" ports write OP_CASET, OP_PASET and OP_RAMWR (0x00 to 0x02), the window
//   opcodes, and PIXFMT (0x03), 0 for RGB565 and 1 for 18-bit pixels.
//   The command bus brings DRAW_RECT, DRAW_IMG, DRAW_BARS, DRAW_DIGIT, TCH_MAP, PT_CMD
//   and PT_DAT; "go" starts the frame. A window is 11 bytes, then its pixels in raster
//   order, x fastest. Each byte waits on the "ds_tx_" ports until "ds_tx_ready".
//   DRAW_IMG reads the image ring ("disp_pair_" ports), DRAW_BARS the accumulator ring
//   ("disp_acc_" ports) and the winner, TCH_MAP the teach weights ("wm_" ports); each
//   pixel that needs such a value waits for its acknowledge.
//   PT_CMD and PT_DAT send one byte as a one-byte frame, with "ds_tx_dc" 0 and 1.
//
// Timing
//   "ds_busy" is high from the clock after "go" and low by the third clock after the
//   clock in which "spi_busy" falls. A 320 by 240 RGB565 clear, 11 window bytes and
//   153,600 pixel bytes at 32 clocks each, takes 196.62 ms at the reset dividers.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets OP_CASET to 0x2A, OP_PASET to
//   0x2B, OP_RAMWR to 0x2C, PIXFMT to 0 and the state to idle. The drawing arguments
//   have no reset; each command captures its own before use.

`default_nettype none

module disp_seq #(
    parameter bit HAS_ATTRACT = 1'b0    //with 0 a generate block leaves out the ATT_FRAME path
) (
    input  logic               clk,            //rising edge
    input  logic               rst_n,          //asynchronous, active low; resets the four registers and the state
    input  logic        [7:0]  cmd,            //the command byte; DRAW_*, PT_*, TCH_MAP, ATT_FRAME
    input  logic               arg_we,         //pulse: an argument byte is on arg_byte
    input  logic        [3:0]  arg_idx,        //the argument's index, 0 first
    input  logic        [7:0]  arg_byte,       //the argument byte
    input  logic               go,             //pulse: the command is complete, after its last argument
    input  logic               reg_we,         //register write strobe; 0x00 to 0x03
    input  logic        [7:0]  reg_addr,       //register address
    input  logic        [7:0]  reg_wdata,      //register write data
    output logic               ds_tx_valid,    //byte request to spi_master (tx_dev = 0)
    output logic        [7:0]  ds_tx_byte,     //the byte to send
    output logic               ds_tx_dc,       //dc level for the byte
    output logic               ds_tx_last,     //ends the frame
    input  logic               ds_tx_ready,    //spi_master's tx_ready, gated by the top
    input  logic               spi_busy,       //the frame's end
    output logic               disp_pair_req,  //DRAW_IMG's request to the image ring
    output logic        [4:0]  disp_pair_idx,  //the pair requested
    input  logic        [3:0]  pair,           //the pair, from dp_img
    input  logic               pair_ack,       //the pair is the one requested
    output logic               disp_acc_req,   //DRAW_BARS's request to the accumulator ring
    output logic        [3:0]  disp_acc_idx,   //the accumulator requested
    input  logic signed [11:0] acc_val,        //the ring's head, from dp_acc
    input  logic               acc_ack,        //the head is the one requested
    input  logic        [3:0]  winner,         //from dp_acc
    input  logic               win_valid,      //valid of winner
    output logic               wm_req,         //TCH_MAP's weight request
    output logic        [5:0]  wm_idx,         //the weight requested
    input  logic signed [7:0]  wm_w,           //the weight, from teach
    input  logic               wm_ack,         //the weight is the one requested
    output logic        [7:0]  att_cx,         //ATT_FRAME's CX argument, to attract
    output logic        [6:0]  att_cy,         //ATT_FRAME's CY argument, to attract
    output logic               att_relu,       //ATT_FRAME's ReLU argument, to attract
    input  logic        [2:0]  att_ch_we,      //attract's channel write strobes into the next-color register
    input  logic        [7:0]  att_ch_val,     //the channel value written
    input  logic               att_full,       //the next color is complete
    output logic               att_take,       //pulse: the next color moved to the current color
    output logic               ds_busy         //a frame in progress; low by the third clock after spi_busy falls
);

logic        [7:0]  op_caset;
logic        [7:0]  op_paset;
logic        [7:0]  op_ramwr;
logic               pixfmt;
logic        [7:0]  arg [14:0];
logic        [3:0]  head_n;
logic        [1:0]  byte_n;
logic        [8:0]  px;
logic        [8:0]  py;
logic        [5:0]  u;
logic        [2:0]  c;
logic        [5:0]  v;
logic        [2:0]  r;
logic        [3:0]  bar_idx;
logic        [10:0] bar_col;
logic        [8:0]  len;
logic               go_draw;
logic               go_pass;
logic        [8:0]  arg_x;
logic        [8:0]  arg_y;
logic        [8:0]  arg_w;
logic        [8:0]  arg_h;
logic        [5:0]  arg_s;
logic        [5:0]  arg_b;
logic        [5:0]  arg_bw;
logic        [5:0]  arg_pitch;
logic        [8:0]  arg_l;
logic        [3:0]  arg_sh;
logic        [3:0]  arg_d;
logic        [8:0]  win_w;
logic        [8:0]  win_h;
logic        [10:0] x0;
logic        [10:0] x1;
logic        [10:0] y0;
logic        [10:0] y1;
logic        [7:0]  head_byte;
logic               head_dc;
logic               take;
logic               pix_last;
logic               pix_done;
logic               row_last;
logic               win_last;
logic               u_wrap;
logic               v_wrap;
logic        [15:0] rect_color;
logic               block;
logic        [1:0]  pix_code;
logic        [15:0] img_color;
logic        [4:0]  w_mag;
logic        [15:0] map_color;
logic signed [11:0] shifted;
logic        [8:0]  len_next;
logic               bar_on;
logic        [15:0] bars_color;
logic               bar_last;
logic        [3:0]  glyph;
logic        [4:0]  glyph_row;
logic               dot;
logic        [15:0] digit_color;
logic        [15:0] color;
logic        [7:0]  pixel_byte;
logic               pixel_ok;
enum logic [2:0] {D_RECT, D_IMG, D_BARS, D_DIGIT, D_MAP, D_PTCMD, D_PTDAT, D_NONE} cmd_code, drawn;
enum logic [2:0] {IDLE, START, FETCH, WINDOW, PIXELS, PASS, DONE} state, next_state;


//--------------------------------------------------------------------------------------------------------------------
//  1. Commands and arguments
//--------------------------------------------------------------------------------------------------------------------

//Control registers: the three opcodes the window bytes carry, column address set, page address set and memory
//write, and the pixel format, 0 for RGB565 with two bytes per pixel and 1 for 18-bit color with three. They reset to
//the ILI9341's values; the host may write them for another controller.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        op_caset    <= 8'h2A;
        op_paset    <= 8'h2B;
        op_ramwr    <= 8'h2C;
        pixfmt      <= 1'b0;
        end
    else
        begin
        if(reg_we & (reg_addr == address_map::REG_OP_CASET))
            op_caset    <= reg_wdata;

        if(reg_we & (reg_addr == address_map::REG_OP_PASET))
            op_paset    <= reg_wdata;

        if(reg_we & (reg_addr == address_map::REG_OP_RAMWR))
            op_ramwr    <= reg_wdata;

        if(reg_we & (reg_addr == address_map::REG_PIXFMT))
            pixfmt      <= reg_wdata[0];
        end


//Command decode: cmd_code names the command on the bus with one of this block's codes, D_NONE for a command that is
//not the display's. drawn keeps the code of the frame being drawn, and the argument bytes are kept as they arrive.
always_comb
    case(cmd)
    address_map::CMD_DRAW_RECT:     cmd_code = D_RECT;
    address_map::CMD_DRAW_IMG:      cmd_code = D_IMG;
    address_map::CMD_DRAW_BARS:     cmd_code = D_BARS;
    address_map::CMD_DRAW_DIGIT:    cmd_code = D_DIGIT;
    address_map::CMD_TCH_MAP:       cmd_code = D_MAP;
    address_map::CMD_PT_CMD:        cmd_code = D_PTCMD;
    address_map::CMD_PT_DAT:        cmd_code = D_PTDAT;
    default:                        cmd_code = D_NONE;
    endcase

assign go_draw = (state == IDLE) & go & (cmd_code != D_NONE);                   //a display command's go, in IDLE only
assign go_pass = go_draw & ((cmd_code == D_PTCMD) | (cmd_code == D_PTDAT));     //a pass-through command's go

always_ff @(posedge clk)
    begin
    if(arg_we & (cmd_code != D_NONE))
        arg[arg_idx]    <= arg_byte;    //argument byte k of the command arriving

    if(go_draw)
        drawn           <= cmd_code;    //the code of the frame drawn from now
    end


//Argument fields: each drawing reads its own fields from the argument bytes. A coordinate or size is 9 bits, the low
//bit of one byte then the whole of the next. A color is two bytes, RGB565, high byte first.
assign arg_x    = {arg[0][0], arg[1]};          //X, the window's first column
assign arg_y    = {arg[2][0], arg[3]};          //Y, the window's first row
assign arg_w    = {arg[4][0], arg[5]};          //W, DRAW_RECT's width
assign arg_h    = {arg[6][0], arg[7]};          //H, DRAW_RECT's height
assign arg_s    = arg[4][5:0];                  //S, the cell size in pixels: DRAW_IMG, TCH_MAP, DRAW_DIGIT

assign arg_b    = arg[5][5:0];                  //B, the block size inside a cell: DRAW_IMG, TCH_MAP
assign arg_bw   = arg[4][5:0];                  //BW, a bar's width: DRAW_BARS
assign arg_pitch= arg[5][5:0];                  //PITCH, from one bar's first column to the next bar's
assign arg_l    = {arg[6][0], arg[7]};          //L, the bar length in rows, the bar window's height

assign arg_sh   = arg[8][3:0];                  //SH, the right shift that scales a score to a length
assign arg_d    = arg[5][3:0];                  //D, the digit to draw: 0 to 9, or 15 for the winner


//--------------------------------------------------------------------------------------------------------------------
//  2. The sequencer
//--------------------------------------------------------------------------------------------------------------------

//State machine: a frame is a window of 11 bytes, then its pixels in raster order, x fastest; a bar frame repeats that
//for each of the ten bars. IDLE waits for a go; START sizes the window and skips an empty one; FETCH waits for the
//bar's score; WINDOW sends the 11 bytes; PIXELS sends the pixels; PASS sends the one pass-through byte; DONE waits
//for the frame to leave the bus.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        state       <= IDLE;
    else
        state       <= next_state;

always_comb
    case(state)
    IDLE:   if(go_pass)                                 next_state = PASS;
            else if(go_draw)                            next_state = START;
            else                                        next_state = IDLE;

    START:  if((win_w == 9'd0) | (win_h == 9'd0))       next_state = DONE;
            else if(drawn == D_BARS)                    next_state = FETCH;
            else                                        next_state = WINDOW;

    FETCH:  if(acc_ack)                                 next_state = WINDOW;
            else                                        next_state = FETCH;

    WINDOW: if(take & (head_n == 4'd10))                next_state = PIXELS;
            else                                        next_state = WINDOW;

    PIXELS: if(pix_done & win_last & ~bar_last)         next_state = FETCH;
            else if(pix_done & win_last)                next_state = DONE;
            else                                        next_state = PIXELS;

    PASS:   if(take)                                    next_state = DONE;
            else                                        next_state = PASS;

    DONE:   if(~spi_busy)                               next_state = IDLE;
            else                                        next_state = DONE;

    default:                                            next_state = IDLE;
    endcase


//--------------------------------------------------------------------------------------------------------------------
//  3. The window
//--------------------------------------------------------------------------------------------------------------------

//Window size: the width and height of the frame's window in pixels. DRAW_IMG and TCH_MAP draw 8 by 8 cells of S
//pixels, DRAW_DIGIT 5 by 7 cells, a bar is BW wide and L tall, a rectangle W by H.
always_comb
    case(drawn)
    D_RECT:         win_w = arg_w;
    D_IMG, D_MAP:   win_w = {arg_s, 3'd0};
    D_BARS:         win_w = {3'd0, arg_bw};
    D_DIGIT:        win_w = {1'b0, arg_s, 2'd0} + {3'd0, arg_s};    //5S, as 4S + S
    default:        win_w = 9'd0;
    endcase

always_comb
    case(drawn)
    D_RECT:         win_h = arg_h;
    D_IMG, D_MAP:   win_h = {arg_s, 3'd0};
    D_BARS:         win_h = arg_l;
    D_DIGIT:        win_h = {arg_s, 3'd0} - {3'd0, arg_s};          //7S, as 8S - S
    default:        win_h = 9'd0;
    endcase


//Window corners: columns x0 to x1 and rows y0 to y1, both ends included, 11 bits so a window reaching past column 511
//does not wrap. A bar's first column is its own, X + k PITCH, kept in bar_col.
assign x0 = (drawn == D_BARS) ? bar_col : {2'd0, arg_x};    //the first column
assign x1 = x0 + {2'd0, win_w} - 11'd1;                     //the last column
assign y0 = {2'd0, arg_y};                                  //the first row
assign y1 = y0 + {2'd0, win_h} - 11'd1;                     //the last row


//Window bytes: the 11 bytes that set the window and start the pixel write; an opcode has dc 0, a value dc 1:
//     0  CASET      1  x0 high    2  x0 low     3  x1 high    4  x1 low
//     5  PASET      6  y0 high    7  y0 low     8  y1 high    9  y1 low
//    10  RAMWR, and the pixel bytes follow.
always_ff @(posedge clk)
    if(state != WINDOW)
        head_n      <= 4'd0;                //the byte offered; 0 outside WINDOW, so a window starts at its first byte
    else if(take)
        head_n      <= head_n + 4'd1;       //the next byte once this one is taken

always_comb
    case(head_n)
    4'd0:       head_byte = op_caset;
    4'd1:       head_byte = {5'd0, x0[10:8]};
    4'd2:       head_byte = x0[7:0];
    4'd3:       head_byte = {5'd0, x1[10:8]};
    4'd4:       head_byte = x1[7:0];
    4'd5:       head_byte = op_paset;
    4'd6:       head_byte = {5'd0, y0[10:8]};
    4'd7:       head_byte = y0[7:0];
    4'd8:       head_byte = {5'd0, y1[10:8]};
    4'd9:       head_byte = y1[7:0];
    default:    head_byte = op_ramwr;       //byte 10; head_n does not pass 10
    endcase

assign head_dc = (head_n != 4'd0) & (head_n != 4'd5) & (head_n != 4'd10);       //0 for the three opcodes


//--------------------------------------------------------------------------------------------------------------------
//  4. The pixel and cell counters
//--------------------------------------------------------------------------------------------------------------------

//Pixel counters: a pixel is two bytes in RGB565 and three in 18-bit color, and the counters step when a pixel's last
//byte is taken. px and py are the pixel's column and row inside the window, 0 at the top left, x fastest.
assign take     = ds_tx_valid & ds_tx_ready;                      //a byte accepted by spi_master
assign pix_last = pixfmt ? (byte_n == 2'd2) : (byte_n == 2'd1);    //the pixel's last byte

always_ff @(posedge clk)
    if(state != PIXELS)
        byte_n      <= 2'd0;                //the byte of the pixel being sent
    else if(take & pix_last)
        byte_n      <= 2'd0;                //the pixel is complete
    else if(take)
        byte_n      <= byte_n + 2'd1;       //its next byte

assign pix_done = (state == PIXELS) & take & pix_last;            //a pixel's last byte taken: the counters step
assign row_last = (px == win_w - 9'd1);                           //the last pixel of a row
assign win_last = row_last & (py == (win_h - 9'd1));              //the last pixel of the window

always_ff @(posedge clk)
    if(state != PIXELS)
        px      <= 9'd0;                    //the pixel's column in the window
    else if(pix_done & row_last)
        px      <= 9'd0;                    //back to the left at a row's end
    else if(pix_done)
        px      <= px + 9'd1;               //the next column

always_ff @(posedge clk)
    if(state != PIXELS)
        py      <= 9'd0;                    //the pixel's row in the window
    else if(pix_done & row_last)
        py      <= py + 9'd1;               //the next row


//Cell counters, for the drawings made of cells: a cell is S by S pixels, u and v are the pixel's column and row inside
//its cell, c and r the cell's column and row in the grid, so px = S c + u and py = S r + v. DRAW_RECT and DRAW_BARS
//read none of them.
assign u_wrap = (u == (arg_s - 6'd1));          //the last column of a cell

always_ff @(posedge clk)
    if(state != PIXELS)
        u       <= 6'd0;                        //the column inside the cell, 0 to S - 1
    else if(pix_done & (row_last | u_wrap))
        u       <= 6'd0;                        //the next cell starts, or the row ends
    else if(pix_done)
        u       <= u + 6'd1;                    //the next column in the cell

always_ff @(posedge clk)
    if(state != PIXELS)
        c       <= 3'd0;                        //the cell's column, 0 to 7, or 0 to 4 for a digit
    else if(pix_done & row_last)
        c       <= 3'd0;                        //back to the first cell at a row's end
    else if(pix_done & u_wrap)
        c       <= c + 3'd1;                    //the next cell when this one's last column is done

assign v_wrap = (v == arg_s - 6'd1);            //the last row of a cell

always_ff @(posedge clk)
    if(state != PIXELS)
        v       <= 6'd0;                        //the row inside the cell, 0 to S - 1
    else if(pix_done & row_last & v_wrap)
        v       <= 6'd0;                        //the next cell row starts
    else if(pix_done & row_last)
        v       <= v + 6'd1;                    //the next row in the cell, once per pixel row

always_ff @(posedge clk)
    if(state != PIXELS)
        r       <= 3'd0;                        //the cell's row, 0 to 7, or 0 to 6 for a digit
    else if(pix_done & row_last & v_wrap)
        r       <= r + 3'd1;                    //the next cell row


//--------------------------------------------------------------------------------------------------------------------
//  5. The drawings
//--------------------------------------------------------------------------------------------------------------------

assign rect_color = {arg[8], arg[9]};                   //DRAW_RECT: one color, C, over the whole window


//DRAW_IMG: the 8 by 8 input image, one 2-bit code per pixel, drawn as a grid of 8 by 8 cells, each S by S screen
//pixels, so the window is 8S by 8S with its top left at (X, Y). Image pixel 8r + c becomes cell (c, r): a block of
//B by B pixels at the cell's top left in the color of the pixel's code, P0 to P3 for codes 0 to 3, and the rest of
//the cell, the gap, in P0:
//
//    the image, 8 by 8 codes           the window, 8 by 8 cells          one cell, S by S pixels
//        c = 0 1 2 3 4 5 6 7           +-----+-----+-----+--             +----------+
//    r = 0   . . . . . . . .           |##   |##   |##   |               |####      |   #  the block, B by B:
//    r = 1   . . . . . . . .           |     |     |     |               |####      |      u < B and v < B,
//      ...                             +-----+-----+-----+--             |          |      in the code's color
//    r = 7   . . . . . . . .           |##   |##   |##   |               +----------+   .  the gap: the rest, P0
//                                      |     |     |     |
//
//The image ring serves two codes at a time: pair i holds pixels 2i and 2i + 1, so cell (c, r) reads pair 4r + c div 2,
//the even column's code in the pair's low two bits and the odd column's in its high two. The pair is requested during
//the whole frame; a block pixel waits until the ring acknowledges it; a gap pixel needs no code and does not wait.
assign block = (u < arg_b) & (v < arg_b);               //the pixel is inside its cell's block
assign pix_code = c[0] ? pair[3:2] : pair[1:0];         //the cell's code: the pair's high code in an odd column

always_comb
    if(~block)
        img_color = {arg[6], arg[7]};                   //the gap: P0
    else
        case(pix_code)
        2'd0:       img_color = {arg[6], arg[7]};       //code 0: P0
        2'd1:       img_color = {arg[8], arg[9]};       //code 1: P1
        2'd2:       img_color = {arg[10], arg[11]};     //code 2: P2
        default:    img_color = {arg[12], arg[13]};     //code 3: P3
        endcase

assign disp_pair_req = (state == PIXELS) & (drawn == D_IMG);    //asked during every pixel of the frame
assign disp_pair_idx = {r, c[2:1]};                             //pair 4r + c div 2, the pair holding pixel 8r + c


//TCH_MAP: the 64 teach weights in the same 8 by 8 grid of cells as DRAW_IMG, weight 8r + c in cell (c, r). The block
//is red for a negative weight and green for zero or positive, brighter for a larger magnitude, and the gap is P0. The
//weight is a 6-bit signed value, -31 to 31, sign-extended to 8 bits, requested from teach during the whole frame; a
//block pixel waits for it, a gap pixel does not.
always_comb
    if(wm_w[7])
        w_mag = 5'd0 - wm_w[4:0];                       //the magnitude of the weight, 0 to 31
    else
        w_mag = wm_w[4:0];

always_comb
    if(~block)
        map_color = {arg[6], arg[7]};                   //the gap: P0
    else if(wm_w[7])
        map_color = {w_mag, 11'd0};                     //negative: the magnitude in the red field
    else
        map_color = {5'd0, w_mag, w_mag[4], 5'd0};      //zero or positive: the magnitude in the green field

assign wm_req = (state == PIXELS) & (drawn == D_MAP);           //asked during every pixel of the frame
assign wm_idx = {r, c};                                         //weight 8r + c


//DRAW_BARS: ten bars, one per class score, score k from the accumulator ring. Bar k is its own window, BW columns
//wide from column X + k PITCH and L rows tall from row Y; the frame draws the ten windows one after another, bar 0
//first. The bar's length is len, the score shifted right by SH and clipped to 0 to L, so a negative score gives no
//bar and a score past L a full one. The bar fills the bottom len rows of its window in CF, or in CW when k is the
//valid winner, and the rows above it are the background CB:
//
//        X          X + PITCH  X + 2 PITCH
//        |<--BW-->|                              row Y              ^
//        +--------+ +--------+ +--------+                           |   above the bar: CB
//        |        | |        | |########|        row Y + L - len    |   L rows
//        |        | |########| |########|        of bar 2           |   the bar, len rows: CF, or CW for the winner's
//        |########| |########| |########|        row Y + L - 1      v
//          bar 0      bar 1      bar 2
always_ff @(posedge clk)
    if(state == START)
        begin
        bar_idx     <= 4'd0;                            //k, the bar drawn
        bar_col     <= {2'd0, arg_x};                   //bar 0's first column, X
        end
    else if(pix_done & win_last)
        begin
        bar_idx     <= bar_idx + 4'd1;                  //the next bar when a bar's last pixel is taken
        bar_col     <= bar_col + {5'd0, arg_pitch};     //its first column
        end

assign shifted = $signed(acc_val) >>> arg_sh;           //the score scaled; the shift keeps the sign

always_comb
    if(shifted[11])
        len_next = 9'd0;                                //a negative score: no bar
    else if(shifted[10:0] > {2'd0, arg_l})
        len_next = arg_l;                               //above the limit: the full length L
    else
        len_next = shifted[8:0];                        //the score itself; at most L, so 9 bits hold it

always_ff @(posedge clk)
    if((state == FETCH) & acc_ack)
        len     <= len_next;                            //the bar's length, taken once when its score arrives

assign bar_on = (py >= (arg_l - len));                  //the row is in the bar, the bottom len rows

always_comb
    if(~bar_on)
        bars_color = {arg[9], arg[10]};                 //above the bar: the background CB
    else if(win_valid & (winner == bar_idx))
        bars_color = {arg[13], arg[14]};                //the winner's bar: CW
    else
        bars_color = {arg[11], arg[12]};                //any other bar: CF

assign bar_last     = (drawn != D_BARS) | (bar_idx == 4'd9);    //the frame's last window: not a bar frame, or bar 9
assign disp_acc_req = (state == FETCH);                         //the bar's score, from the accumulator ring
assign disp_acc_idx = bar_idx;                                  //score k for bar k


//DRAW_DIGIT: one digit as 5 by 7 cells of S pixels, a lit cell in CF and a dark one in CB, from a 5 by 7 font. D is
//the digit, or 15 for the digit reader's winner; the blank glyph, 10, shows for D of 10 to 14 and for a winner that is
//not valid.
always_comb
    if(arg_d <= 4'd9)
        glyph = arg_d;                          //a digit given by the host
    else if((arg_d == 4'd15) & win_valid)
        glyph = winner;                         //15: the winner, when it is valid
    else
        glyph = 4'd10;                          //blank


//The font: ten glyphs of 5 columns by 7 rows, one 5-bit row per case item, bit 4 the left column; glyph g row r is
//item 8g + r. Each row is drawn beside its item, * for a lit dot, so the table checks itself.
always_comb
    case({glyph, r})
    7'h00:      glyph_row = 5'h0E;                 //glyph 0  .***.
    7'h01:      glyph_row = 5'h11;                 //         *...*
    7'h02:      glyph_row = 5'h13;                 //         *..**
    7'h03:      glyph_row = 5'h15;                 //         *.*.*
    7'h04:      glyph_row = 5'h19;                 //         **..*
    7'h05:      glyph_row = 5'h11;                 //         *...*
    7'h06:      glyph_row = 5'h0E;                 //         .***.

    7'h08:      glyph_row = 5'h04;                 //glyph 1  ..*..
    7'h09:      glyph_row = 5'h0C;                 //         .**..
    7'h0A:      glyph_row = 5'h04;                 //         ..*..
    7'h0B:      glyph_row = 5'h04;                 //         ..*..
    7'h0C:      glyph_row = 5'h04;                 //         ..*..
    7'h0D:      glyph_row = 5'h04;                 //         ..*..
    7'h0E:      glyph_row = 5'h0E;                 //         .***.

    7'h10:      glyph_row = 5'h0E;                 //glyph 2  .***.
    7'h11:      glyph_row = 5'h11;                 //         *...*
    7'h12:      glyph_row = 5'h01;                 //         ....*
    7'h13:      glyph_row = 5'h02;                 //         ...*.
    7'h14:      glyph_row = 5'h04;                 //         ..*..
    7'h15:      glyph_row = 5'h08;                 //         .*...
    7'h16:      glyph_row = 5'h1F;                 //         *****

    7'h18:      glyph_row = 5'h1F;                 //glyph 3  *****
    7'h19:      glyph_row = 5'h02;                 //         ...*.
    7'h1A:      glyph_row = 5'h04;                 //         ..*..
    7'h1B:      glyph_row = 5'h02;                 //         ...*.
    7'h1C:      glyph_row = 5'h01;                 //         ....*
    7'h1D:      glyph_row = 5'h11;                 //         *...*
    7'h1E:      glyph_row = 5'h0E;                 //         .***.

    7'h20:      glyph_row = 5'h02;                 //glyph 4  ...*.
    7'h21:      glyph_row = 5'h06;                 //         ..**.
    7'h22:      glyph_row = 5'h0A;                 //         .*.*.
    7'h23:      glyph_row = 5'h12;                 //         *..*.
    7'h24:      glyph_row = 5'h1F;                 //         *****
    7'h25:      glyph_row = 5'h02;                 //         ...*.
    7'h26:      glyph_row = 5'h02;                 //         ...*.

    7'h28:      glyph_row = 5'h1F;                 //glyph 5  *****
    7'h29:      glyph_row = 5'h10;                 //         *....
    7'h2A:      glyph_row = 5'h1E;                 //         ****.
    7'h2B:      glyph_row = 5'h01;                 //         ....*
    7'h2C:      glyph_row = 5'h01;                 //         ....*
    7'h2D:      glyph_row = 5'h11;                 //         *...*
    7'h2E:      glyph_row = 5'h0E;                 //         .***.

    7'h30:      glyph_row = 5'h06;                 //glyph 6  ..**.
    7'h31:      glyph_row = 5'h08;                 //         .*...
    7'h32:      glyph_row = 5'h10;                 //         *....
    7'h33:      glyph_row = 5'h1E;                 //         ****.
    7'h34:      glyph_row = 5'h11;                 //         *...*
    7'h35:      glyph_row = 5'h11;                 //         *...*
    7'h36:      glyph_row = 5'h0E;                 //         .***.

    7'h38:      glyph_row = 5'h1F;                 //glyph 7  *****
    7'h39:      glyph_row = 5'h01;                 //         ....*
    7'h3A:      glyph_row = 5'h02;                 //         ...*.
    7'h3B:      glyph_row = 5'h04;                 //         ..*..
    7'h3C:      glyph_row = 5'h08;                 //         .*...
    7'h3D:      glyph_row = 5'h08;                 //         .*...
    7'h3E:      glyph_row = 5'h08;                 //         .*...

    7'h40:      glyph_row = 5'h0E;                 //glyph 8  .***.
    7'h41:      glyph_row = 5'h11;                 //         *...*
    7'h42:      glyph_row = 5'h11;                 //         *...*
    7'h43:      glyph_row = 5'h0E;                 //         .***.
    7'h44:      glyph_row = 5'h11;                 //         *...*
    7'h45:      glyph_row = 5'h11;                 //         *...*
    7'h46:      glyph_row = 5'h0E;                 //         .***.

    7'h48:      glyph_row = 5'h0E;                 //glyph 9  .***.
    7'h49:      glyph_row = 5'h11;                 //         *...*
    7'h4A:      glyph_row = 5'h11;                 //         *...*
    7'h4B:      glyph_row = 5'h0F;                 //         .****
    7'h4C:      glyph_row = 5'h01;                 //         ....*
    7'h4D:      glyph_row = 5'h02;                 //         ...*.
    7'h4E:      glyph_row = 5'h0C;                 //         .**..

    default:    glyph_row = 5'h00;                 //blank: glyphs 10 to 15, and row 7
    endcase

assign dot         = glyph_row[3'd4 - c];                           //the dot of column c, 0 to 4; bit 4 is the left one
assign digit_color = dot ? {arg[8], arg[9]} : {arg[6], arg[7]};     //CF on a dot, CB elsewhere


//--------------------------------------------------------------------------------------------------------------------
//  6. The pixel byte and the outputs
//--------------------------------------------------------------------------------------------------------------------

//Pixel byte: the pixel's color is RGB565, red in bits 15 to 11, green 10 to 5, blue 4 to 0. RGB565 sends it as two
//bytes, high then low; 18-bit color sends three, each color left-aligned with its top bit repeated to make 6 bits:
//    RGB565   byte 0  color[15:8]                byte 1  color[7:0]
//    18-bit   byte 0  {R, R[4], 00}              byte 1  {G, 00}                 byte 2  {B, B[4], 00}
always_comb
    case(drawn)
    D_RECT:     color = rect_color;
    D_IMG:      color = img_color;
    D_MAP:      color = map_color;
    D_BARS:     color = bars_color;
    D_DIGIT:    color = digit_color;
    default:    color = 16'd0;              //the pass-through codes send no pixel
    endcase

always_comb
    if(~pixfmt)
        pixel_byte = (byte_n == 2'd0) ? color[15:8] : color[7:0];       //RGB565: the high byte, then the low
    else
        case(byte_n)
        2'd0:       pixel_byte = {color[15:11], color[15], 2'd0};       //18-bit: red
        2'd1:       pixel_byte = {color[10:5], 2'd0};                   //green
        default:    pixel_byte = {color[4:0], color[4], 2'd0};          //blue
        endcase

always_comb
    if((drawn == D_IMG) & block)
        pixel_ok = pair_ack;                //an image block pixel waits for its pair
    else if((drawn == D_MAP) & block)
        pixel_ok = wm_ack;                  //a map block pixel waits for its weight
    else
        pixel_ok = 1'b1;                    //every other pixel goes at once


//Outputs to spi_master: a byte is offered in WINDOW, in PASS, and in PIXELS once the pixel's value is in hand; the
//frame ends with the pass-through byte or with the last byte of its last window. ds_busy spans the frame.
assign ds_tx_valid = (state == WINDOW) | (state == PASS) | ((state == PIXELS) & pixel_ok);      //a byte offered

always_comb
    case(state)
    WINDOW:     ds_tx_byte = head_byte;         //a window byte
    PASS:       ds_tx_byte = arg[0];            //the pass-through byte
    default:    ds_tx_byte = pixel_byte;        //a pixel byte
    endcase

always_comb
    case(state)
    WINDOW:     ds_tx_dc = head_dc;             //0 for an opcode, 1 for a value
    PASS:       ds_tx_dc = (drawn == D_PTDAT);    //PT_CMD sends an opcode, PT_DAT a data byte
    default:    ds_tx_dc = 1'b1;                //pixel bytes are data
    endcase

assign ds_tx_last = (state == PASS) | ((state == PIXELS) & pix_last & win_last & bar_last);     //the frame's last byte
assign ds_busy    = (state != IDLE);                                                            //a frame in progress


//Attract mode is not built in the chip, HAS_ATTRACT 0, so its outputs are tied low.
generate
    if(HAS_ATTRACT == 1'b0)
        begin : without_attract
        assign att_cx   = 8'd0;
        assign att_cy   = 7'd0;
        assign att_relu = 1'b0;
        assign att_take = 1'b0;
        end
endgenerate


//Unused signals: the attract inputs and the sign-extension bits of the weight, declared so Verilator does not report
//them.
wire _unused = &{1'b0, att_ch_we, att_ch_val, att_full, wm_w[6:5]};

endmodule
