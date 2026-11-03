// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// dp_walk.sv : the tile walker
//
// Description
//   Runs one TILE of the digit reader: loads its four 4-bit weights into the array,
//   sends one row of two pixel codes through it and adds the two column sums to two
//   class scores in the accumulator ring. 160 tiles cover 32 pixel pairs by 5 class
//   pairs; the walker keeps no weight registers.
//
// Operation
//   TILE's byte 0 loads PE(0,0) and PE(0,1) and byte 1 loads PE(1,0) and PE(1,1), each
//   4-bit weight sign-extended, as the bytes arrive ("arg_we", "arg_idx", "arg_byte").
//   Tile t covers pixels 2i and 2i + 1 for classes 2j and 2j + 1, i = t div 5 and
//   j = t mod 5. At "go" the walker requests pair i and accumulator 2j until "pair_ack"
//   and "acc_ack" are both high, sends the row on "wk_a" with "wk_a_valid", and adds
//   class 2j's sum, then class 2j + 1's, with "acc_add" and "acc_add_val". Then j
//   steps, wrapping at 5 with i + 1, and i wraps at 32.
//   "wk_sel" is high while the walker owns the array; its "wk_" outputs are 0 otherwise.
//   Send the 160 tiles in order after DIG_START, whose "go" clears i and j; more than
//   160 without DIG_START can overflow the 12-bit scores.
//
// Timing
//   A tile takes 7 clocks from "go" to idle with both rings in place, counting the "go"
//   clock as 1. 15 of the 160 tiles after IMG (16 when the image is reused) take 8,
//   where the image ring steps to the next byte. "wk_busy" is high during a tile.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets the walker's state and the tile
//   counters i and j to 0. The data registers have no reset; each tile writes them.

`default_nettype none

module dp_walk (
    input  logic               clk,            //rising edge
    input  logic               rst_n,          //asynchronous, active low; resets the walker's state (DIG_START's go clears i and j)
    input  logic        [7:0]  cmd,            //the command byte; TILE bytes and go; DIG_START's go clears i and j
    input  logic               arg_we,         //pulse: an argument byte is on arg_byte
    input  logic        [3:0]  arg_idx,        //the argument's index, 0 first
    input  logic        [7:0]  arg_byte,       //the argument byte
    input  logic               go,             //pulse: the command is complete, after its last argument
    output logic               walk_pair_req,  //request for pair i
    output logic        [4:0]  walk_pair_idx,  //i
    input  logic        [3:0]  pair,           //the pair, from dp_img
    input  logic               pair_ack,       //the pair is the one requested
    output logic               walk_acc_req,   //request for accumulator 2j
    output logic        [3:0]  walk_acc_idx,   //2j
    input  logic               acc_ack,        //from dp_acc
    output logic               wk_sel,         //owns the array's dp_ port
    output logic        [3:0]  wk_w_ld,        //weight load bits into the array
    output logic        [31:0] wk_w,           //the weights into the array
    output logic        [15:0] wk_a,           //one row into the array
    output logic               wk_a_valid,     //valid of wk_a
    input  logic        [33:0] dp_p,           //column sums
    input  logic               dp_p_valid,     //valid of dp_p
    output logic               acc_add,        //pulse: one add-and-step of the accumulator ring
    output logic signed [11:0] acc_add_val,    //the value added
    output logic               wk_busy         //tile in progress
);

logic [3:0] pair_reg;
logic [11:0] c1_reg;
logic [2:0] j;
logic [4:0] i;
logic tile_byte;
logic [7:0] weight_lo;
logic [7:0] weight_hi;
logic add1;
logic go_tile;
logic rings_ack;
logic go_start;
enum logic [2:0] {IDLE, REQ, ROW, WAIT, ADD2} state, next_state;


//Weight loads: each TILE byte loads two of the array's four weights as it arrives, byte 0 the top row and
//byte 1 the bottom row, each nibble sign-extended from 4 bits to 8. wk_sel is high while the bytes load and
//while a tile runs, so the array takes its weights and its row from the walker instead of the matrix path.
//A tile is pixel pair i, pixels 2i and 2i + 1, by class pair j, classes 2j and 2j + 1; PE(r, c) takes the weight
//of pixel 2i + r for class 2j + c:
//                    class 2j      class 2j + 1
//    pixel 2i        PE(0, 0)      PE(0, 1)          TILE byte 0: the low nibble, then the high nibble
//    pixel 2i + 1    PE(1, 0)      PE(1, 1)          TILE byte 1: the low nibble, then the high nibble
assign tile_byte    = arg_we & (cmd == address_map::CMD_TILE);    //a TILE byte is arriving
assign weight_lo    = {{4{arg_byte[3]}}, arg_byte[3:0]};          //the low nibble, the column 0 weight, sign-extended
assign weight_hi    = {{4{arg_byte[7]}}, arg_byte[7:4]};          //the high nibble, the column 1 weight, sign-extended
assign wk_w_ld      = tile_byte ? ((arg_idx == 4'd0) ? 4'b0011 : 4'b1100) : 4'b0000;
assign wk_w         = tile_byte ? {weight_hi, weight_lo, weight_hi, weight_lo} : 32'd0;
assign wk_sel       = tile_byte | wk_busy;


//Pair register: the pair from dp_img is kept in the clock both rings acknowledge, so the row sent next holds
//it whatever the image ring does after.
always_ff @(posedge clk)
    if((state == REQ) & rings_ack)
        pair_reg    <= pair;    //the kept pair, {code(2i+1), code(2i)}


//Row: the two codes of the pair go into the array as one row, pixel 2i in the low byte and pixel 2i + 1 in the
//high byte, each zero-extended from 2 bits to 8, with the valid high for the one clock of ROW.
assign wk_a         = (state == ROW) ? {6'b0, pair_reg[3:2], 6'b0, pair_reg[1:0]} : 16'd0;
assign wk_a_valid   = (state == ROW);


//Accumulator adds: when the column sums come out of the array, class 2j's sum goes to the accumulator ring at
//once and class 2j + 1's is kept for one clock and goes next. The low 12 bits of each 17-bit signed sum are its
//whole value: a sum of two products of a 2-bit unsigned code, 0 to 3, and a 4-bit signed weight, -8 to 7, lies
//between -48 and 42.
assign add1 = (state == WAIT) & dp_p_valid;    //the clock the sums arrive in WAIT, the first add

always_ff @(posedge clk)
    if(add1)
        c1_reg      <= dp_p[28:17];            //column 1's low 12 bits, kept for the second add in ADD2

assign acc_add      = add1 | (state == ADD2);
assign acc_add_val  = (state == ADD2) ? c1_reg : dp_p[11:0];


//Tile state machine: IDLE waits for TILE's go; REQ holds both ring requests until both acknowledge; ROW sends
//the row; WAIT waits for the column sums; ADD2 sends the second add. A tile takes 7 clocks from go to idle when
//both rings are already in place, one more for each step the image ring needs.
assign go_tile      = go & (cmd == address_map::CMD_TILE);    //TILE's go
assign rings_ack    = pair_ack & acc_ack;                     //both rings acknowledge

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        state       <= IDLE;
    else
        state       <= next_state;

always_comb
    case(state)
    IDLE: if(go_tile)           next_state = REQ;
          else                  next_state = IDLE;

    REQ:  if(rings_ack)         next_state = ROW;
          else                  next_state = REQ;

    ROW:                        next_state = WAIT;

    WAIT: if(dp_p_valid)        next_state = ADD2;
          else                  next_state = WAIT;

    ADD2:                       next_state = IDLE;
    default:                    next_state = IDLE;
    endcase


//Ring requests and busy: both requests are high in REQ, the pair index is i and the accumulator index is 2j;
//wk_busy is high in every state but IDLE.
assign wk_busy          = (state != IDLE);
assign walk_pair_idx    = i;
assign walk_pair_req    = (state == REQ);
assign walk_acc_req     = (state == REQ);
assign walk_acc_idx     = {j, 1'b0};


//Tile counters: j counts the class pair, 0 to 4, and i the pixel pair, 0 to 31. At the end of each tile j
//steps, and when j wraps i steps; i wraps at 32 by its width. DIG_START's go clears both, so the 160 tiles
//that follow it start at tile 0.
//The order of the tiles; tile t covers pixel pair i = t div 5 and class pair j = t mod 5:
//    tile    0     1     2     3     4     5     6     ...   158   159
//    i       0     0     0     0     0     1     1     ...   31    31
//    j       0     1     2     3     4     0     1     ...   3     4
assign go_start = go & (cmd == address_map::CMD_DIG_START);    //DIG_START's go

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        j       <= 3'd0;
        i       <= 5'd0;
        end
    else if(go_start)
        begin
        j       <= 3'd0;
        i       <= 5'd0;
        end
    else
        begin
        if(state == ADD2)
            j   <= (j == 3'd4) ? 3'd0 : j + 3'd1;

        if((state == ADD2) & (j == 3'd4))
            i   <= i + 5'd1;
        end


//Unused signals: the bits of the column sums above their low 12, declared so Verilator does not report them.
wire _unused = &{1'b0, dp_p[33:29], dp_p[16:12]};

endmodule
