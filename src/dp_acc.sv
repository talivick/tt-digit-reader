// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// dp_acc.sv : the accumulator ring and the argmax
//
// Description
//   Holds the digit reader's ten 12-bit signed class scores, ACC[0] to ACC[9], as a ring
//   that steps toward its head; takes the tile walker's adds, reads out any score, and
//   finds the class with the largest score, a tie going to the lowest class. The ring
//   replaces a 10-to-1 read multiplexer.
//
// Operation
//   DIG_START's ten argument bytes, the INT8 biases of classes 0 to 9, load the scores
//   sign-extended, and its "go" clears "win_valid".
//   An "acc_add" pulse adds "acc_add_val" to the score at the head, with 12-bit wrap,
//   and steps the ring.
//   Read score k with "acc_req" high and "acc_idx" = k: the ring steps one place per
//   clock until "acc_ack" is high with the score on "acc_val".
//   DIG_ARGMAX's "go" scans the ten scores and ends with "winner", "win_valid" high and
//   an "am_done" pulse. "am_busy" is high meanwhile, and "acc_req" is then ignored.
//
// Timing
//   A read waits at most 9 clocks. The argmax takes 11 clocks after 160 tiles and at
//   most 20, counting the "go" clock as 1.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets the ring position to 0, "winner"
//   and "win_valid" to 0 and the argmax state to idle. The scores have no reset;
//   DIG_START writes them before use.

`default_nettype none

module dp_acc (
    input  logic               clk,          //rising edge
    input  logic               rst_n,        //asynchronous, active low; resets apos, win_valid, am_busy and the argmax state
    input  logic        [7:0]  cmd,          //the command byte; DIG_START biases and go (clears WIN_VALID); DIG_ARGMAX go
    input  logic               arg_we,       //pulse: an argument byte is on arg_byte
    input  logic        [7:0]  arg_byte,     //the argument byte
    input  logic               go,           //pulse: the command is complete, after its last argument
    input  logic               acc_req,      //read request for accumulator acc_idx
    input  logic        [3:0]  acc_idx,      //k, the accumulator requested
    output logic signed [11:0] acc_val,      //the head
    output logic               acc_ack,      //1 while accumulator acc_idx is at the head and acc_req = 1
    input  logic               acc_add,      //add-and-step pulse, from dp_walk
    input  logic signed [11:0] acc_add_val,  //the value added
    output logic        [3:0]  winner,       //the argmax result
    output logic               win_valid,    //valid of winner
    output logic               am_done,      //pulses at the end of an argmax
    output logic               am_busy       //argmax in progress
);

logic [119:0] ar;
logic [3:0] apos;
logic signed [11:0] best;
logic [3:0] best_idx;
logic load;
logic [11:0] bias12;
logic [11:0] sum;
logic [11:0] new9;
logic step;
logic move;
logic go_argmax;
logic last;
logic better;
logic go_start;
enum logic [1:0] {IDLE, SEEK, SCAN} state, next_state;

//Ring input: the value the tail takes on a move. A DIG_START byte enters sign-extended from 8 bits to 12; an add
//puts the head's score plus the value added there, with 12-bit wrap; otherwise the head's score goes around
//unchanged.
assign load     = arg_we & (cmd == address_map::CMD_DIG_START);
assign bias12   = {{4{arg_byte[7]}}, arg_byte};
assign sum      = acc_val + acc_add_val;
assign new9     = load ? bias12 : (acc_add ? sum : acc_val);

//Ring step: the ring moves for a bias byte, an add, a read whose score is not yet at the head, and every clock
//of an argmax.
assign step     = am_busy | (acc_req & (apos != acc_idx));
assign move     = load | acc_add | step;

//Ring buffer: the ten scores are one 120-bit register with the head in its low 12 bits. Every move shifts it
//one score toward the head and the tail takes the ring input. The scores have no reset; DIG_START writes them.
always_ff @(posedge clk)
    if(move)
        ar      <= {new9, ar[119:12]};

//Position counter: apos is the index of the score at the head. It resets to 0, returns to 0 with every
//DIG_START byte, and goes up by one with every move, wrapping at 10.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        apos    <= 4'd0;
    else if(load)
        apos    <= 4'd0;
    else if(move)
        apos    <= (apos == 4'd9) ? 4'd0 : apos + 4'd1;

//Read port: the score at the head is always on acc_val. A read is acknowledged while its index is at the head
//and no argmax runs.
assign acc_val      = ar[11:0];
assign acc_ack      = acc_req & (apos == acc_idx) & ~am_busy;

//Argmax state machine: IDLE waits for DIG_ARGMAX's go; SEEK steps the ring until score 0 is at the head; SCAN
//steps through the ten scores, one per clock, and ends on the tenth.
assign go_argmax    = go & (cmd == address_map::CMD_DIG_ARGMAX);
assign go_start     = go & (cmd == address_map::CMD_DIG_START);

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        state       <= IDLE;
    else
        state       <= next_state;

always_comb
    case(state)
    IDLE: if(go_argmax & (apos != 4'd0))    next_state = SEEK;
          else if(go_argmax)                next_state = SCAN;
          else                              next_state = IDLE;

    SEEK: if(apos == 4'd9)                  next_state = SCAN;
          else                              next_state = SEEK;

    SCAN: if(apos == 4'd9)                  next_state = IDLE;
          else                              next_state = SCAN;

    default:                    next_state = IDLE;
    endcase

//Best so far: in SCAN the first score is taken, and a later score replaces it only when it is greater, as a
//signed compare, so a tie keeps the lower class. On the last clock the tenth score is compared on its own.
assign am_busy      = (state != IDLE);
assign last         = (state == SCAN) & (apos == 4'd9);
assign better       = (apos == 4'd0) | (acc_val > best);
always_ff @(posedge clk)
    if((state == SCAN) & better)
        begin
        best        <= acc_val;
        best_idx    <= apos;
        end

//Result registers: on the last clock winner takes the tenth score's index if it beats the best, else the
//best's index; win_valid rises then and falls at DIG_START's go; am_done is high for the one clock after the
//scan.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        winner      <= 4'd0;
        win_valid   <= 1'b0;
        am_done     <= 1'b0;
        end
    else
        begin
        am_done     <= last;
        if(last)
            begin
            winner      <= better ? apos : best_idx;
            win_valid   <= 1'b1;
            end
        else if(go_start)
            win_valid   <= 1'b0;
        end

endmodule
