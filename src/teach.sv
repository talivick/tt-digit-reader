// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// teach.sv : the teach control
//
// Description
//   Runs teach mode, a perceptron that learns to tell two drawn symbols, A and B, apart.
//   A drawing's score is the bias plus the sum of each weight times its pixel's 2-bit
//   code. The products use the array's PE(0,0) and the sum the requantize unit's adder
//   and register; the weights live in tch_ring, which brings one to its head each clock.
//
// Operation
//   TSTEP (0x1E, 0 to 15) and TMARGIN (0x1F, 0x20, 0 to 8,191) come on the "reg_" ports.
//   TCH_CLEAR writes 0 into all 65 weights. TCH_SCORE scores the image in the image ring.
//   TCH_LEARN scores it with the label in its argument bit 0, 0 for A (+1) and 1 for B
//   (-1), and when the label times the score is at most TMARGIN it moves each weight by
//   the label times its code times TSTEP, limited to -31..31; the bias's code is 1.
//   TCH_READ's bytes come from "tch_score" (14 bits, sign-extended to 16), "tch_learned"
//   and "tch_bias", the last once "tch_bias_ok" is high. TCH_MAP's weight requests on
//   "wm_req" and "wm_idx" are answered on "wm_w" with "wm_ack".
//
// Timing
//   TCH_CLEAR takes 65 clocks. TCH_SCORE takes its alignment wait plus 69 clocks;
//   TCH_LEARN adds 1 clock of compare and, when it learns, a second wait and 65 clocks.
//   "t_busy" is high while a teach command runs.
//
// Modes
//   Teach mode owns the array ("tch_sel") and the requantize adder ("tch_ma_" ports)
//   only while it scores and compares, and holds those outputs at 0 otherwise. A matrix
//   run refuses TCH_SCORE and TCH_LEARN, and a matrix row overwrites the score.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets TSTEP to 1, TMARGIN to 124,
//   LEARNED to 0, the phase and the counter. The label has no reset; TCH_LEARN writes
//   it. The weight ring has none either; the host clears it with TCH_CLEAR.

`default_nettype none

module teach (
    input  logic               clk,          //rising edge
    input  logic               rst_n,        //asynchronous, active low; resets the registers the Reset paragraph names
    input  logic        [7:0]  cmd,          //the command byte; TCH_CLEAR, TCH_SCORE, TCH_LEARN and its label byte
    input  logic               arg_we,       //pulse: an argument byte is on arg_byte
    input  logic        [7:0]  arg_byte,     //the argument byte
    input  logic               go,           //pulse: the command is complete, after its last argument
    input  logic               reg_we,       //register write strobe; TSTEP 0x1E, TMARGIN 0x1F and 0x20
    input  logic        [7:0]  reg_addr,     //register address
    input  logic        [7:0]  reg_wdata,    //register write data
    output logic        [1:0]  tr_sel,       //what the ring's tail takes, to tch_ring
    output logic signed [5:0]  tr_in,        //the updated weight, to tch_ring
    input  logic signed [5:0]  tr_head,      //the word at the ring's head, from tch_ring
    input  logic        [6:0]  tr_hpos,      //the head position: that word's index, 0 to 64, from tch_ring
    output logic               img_seek0,    //move byte 0 to the image ring's head
    output logic               img_step,     //step the image ring one byte
    input  logic        [7:0]  img_head0,    //the image ring's head byte
    input  logic               img_at0,      //the head is byte 0
    output logic               tch_sel,      //teach owns the array's dp_ port, the digit path's port
    output logic        [3:0]  tch_w_ld,     //weight load bits into the array
    output logic        [31:0] tch_w,        //the weights into the array
    output logic        [15:0] tch_a,        //one row into the array
    output logic               tch_ma_sel,   //requant's adder is in use
    output logic               tch_ma_we,    //write PH, the high word of requant's running sum
    output logic               tch_ma_clr,   //read PH as 0 in this clock's add: the first product starts the sum
    output logic               tch_ma_pe,    //add p0, the array's first product, into PH
    output logic signed [16:0] tch_ma_b,     //the addend
    input  logic signed [17:0] ma_q,         //PH, the running sum, from requant
    input  logic               ma_neg,       //sign of the 19-bit sum, from requant
    output logic signed [15:0] tch_score,    //TCH_READ: the score
    output logic               tch_learned,  //TCH_READ: LEARNED
    output logic signed [7:0]  tch_bias,     //TCH_READ: the bias word
    output logic               tch_bias_ok,  //TCH_READ: the bias word is at the head
    input  logic               wm_req,       //TCH_MAP's weight request
    input  logic        [5:0]  wm_idx,       //the weight requested
    output logic signed [7:0]  wm_w,         //the requested weight, sign-extended
    output logic               wm_ack,       //the weight is the one requested
    output logic               t_busy        //a teach command in progress
);

logic label;
logic [3:0] tstep;
logic [12:0] tmargin;
logic learn_cmd;
logic [2:0] phase;
logic [6:0] count;
logic [5:0] map_w;
logic [5:0] map_idx;
logic map_valid;
logic go_clear;
logic go_score;
logic go_learn;
logic [1:0] code;
logic signed [7:0] head8;
logic first_prod;
logic add_prod;
logic learn;
logic [5:0] delta;
logic signed [7:0] sum;
logic map_hit;

localparam logic [2:0]  IDLE = 3'd0, CLEAR = 3'd1, ALIGN = 3'd2, SCORE = 3'd3, DRAIN = 3'd4,
                        CMP = 3'd5, ALIGN2 = 3'd6, UPDATE = 3'd7;


//--------------------------------------------------------------------------------------------------------------------
//  1. The commands and the host registers
//--------------------------------------------------------------------------------------------------------------------

//The three teach commands, each as its own start pulse: go is the decoder's pulse that says the command on cmd is
//complete, so each of these is 1 for one clock when its command has just arrived.
assign go_clear = go & (cmd == address_map::CMD_TCH_CLEAR);     //TCH_CLEAR: write 0 into every weight

assign go_score = go & (cmd == address_map::CMD_TCH_SCORE);     //TCH_SCORE: score the image

assign go_learn = go & (cmd == address_map::CMD_TCH_LEARN);     //TCH_LEARN: score it and maybe update the weights


//The label, TCH_LEARN's one argument: bit 0 names the drawn symbol, 0 for A and 1 for B. No reset, because every
//TCH_LEARN writes it before its go.
always_ff @(posedge clk)
    if(arg_we & (cmd == address_map::CMD_TCH_LEARN))
        label   <= arg_byte[0];


//TSTEP, the learning step: how far a weight moves per unit of pixel code when the chip learns. Host register 0x1E,
//bits 3:0, reset 1.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tstep   <= 4'd1;
    else if(reg_we & (reg_addr == address_map::REG_TSTEP))
        tstep   <= reg_wdata[3:0];


//TMARGIN, the learning margin: the chip learns only when the score is not already past the margin on the correct
//side. 13 bits over two host registers, the high 5 bits at 0x1F and the low 8 at 0x20, reset 124.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tmargin   <= 13'd124;
    else if(reg_we & (reg_addr == address_map::REG_TMARGIN_HI))
        tmargin[12:8] <= reg_wdata[4:0];
    else if(reg_we & (reg_addr == address_map::REG_TMARGIN_LO))
        tmargin[7:0] <= reg_wdata;


//Which of the two scoring commands is running: 1 for TCH_LEARN, 0 for TCH_SCORE. The score pass is the same for
//both; only the end differs. No reset, because every scoring command writes it at its go.
always_ff @(posedge clk)
    if(go_score)
        learn_cmd <= 1'b0;
    else if(go_learn)
        learn_cmd <= 1'b1;


//--------------------------------------------------------------------------------------------------------------------
//  2. The phase and the counter
//--------------------------------------------------------------------------------------------------------------------

//The phase, teach's state. The arrows, with the condition that takes each one:
//
//   IDLE --go_clear--> CLEAR (65 clocks, zero into every weight) --> IDLE
//
//   IDLE --go_score or go_learn--> ALIGN --weight 0 next and byte 0 at the image ring's head--> SCORE (n = 0 to 64)
//        --> DRAIN (n = 65 to 68, the last products arrive) --> IDLE after TCH_SCORE, or --> CMP after TCH_LEARN
//
//   CMP (one clock) --no learn--> IDLE, or --learn--> ALIGN2 --weight 0 next--> UPDATE (n = 0 to 64) --> IDLE
//
//Both waits end in the clock where the ring's head position is 64, so the next clock brings weight 0 to the head
//with n = 0. ALIGN also waits for byte 0 of the image to be at the image ring's head; after a score pass the image
//ring is back at byte 0 by itself, so ALIGN2 waits for the ring alone.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        phase       <= IDLE;
    else
        case(phase)
        IDLE:   if(go_clear)                            phase <= CLEAR;
                else if(go_score | go_learn)            phase <= ALIGN;

        CLEAR:  if(count == 7'd64)                      phase <= IDLE;

        ALIGN:  if((tr_hpos == 7'd64) & img_at0)        phase <= SCORE;

        SCORE:  if(count == 7'd64)                      phase <= DRAIN;

        DRAIN:  if((count == 7'd68) & learn_cmd)        phase <= CMP;
                else if(count == 7'd68)                 phase <= IDLE;

        CMP:    if(learn)                               phase <= ALIGN2;
                else                                    phase <= IDLE;

        ALIGN2: if(tr_hpos == 7'd64)                    phase <= UPDATE;

        UPDATE: if(count == 7'd64)                      phase <= IDLE;
        endcase


//The counter n: the clocks of the phase, 0 to 64 in CLEAR, SCORE and UPDATE, 65 to 68 in DRAIN. It is held at 0 in
//IDLE and in both waits, so it equals the ring's head position in SCORE and UPDATE.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        count       <= 7'd0;
    else if((phase == IDLE) | (phase == ALIGN) | (phase == ALIGN2))
        count       <= 7'd0;
    else
        count       <= count + 7'd1;

assign t_busy = (phase != IDLE);                                                //a teach command is running

assign img_seek0 = (phase == ALIGN);                                            //the image ring puts byte 0 at its head

assign img_step = ((phase == SCORE) | (phase == UPDATE)) & (count[1:0] == 2'd3);    //next byte after its fourth pixel


//--------------------------------------------------------------------------------------------------------------------
//  3. The score
//--------------------------------------------------------------------------------------------------------------------

//The pixel code: 2 bits per pixel, four pixels in each byte of the image, read from the byte at the image ring's
//head. Weight n belongs to pixel n, and byte k holds pixels 4k to 4k + 3, so the ring steps to the next byte after
//every fourth weight. The bias, weight 64, has the constant code 1.
//
//   img_head0 bits    7 6   |  5 4   |  3 2   |  1 0
//   pixel             4k+3  |  4k+2  |  4k+1  |  4k        byte k at the head while n = 4k to 4k + 3
assign code = (tr_hpos == 7'd64) ? 2'd1 : img_head0[{tr_hpos[1:0], 1'b0} +: 2];

assign head8 = { {2{tr_head[5]}}, tr_head };                        //the weight at the head, sign-extended to 8 bits


//The array's port during a score. Teach owns the port in SCORE and DRAIN, loads the weight at the head into PE(0,0)
//and PE(1,0) each clock (the two load bits of 4'b0101), and gives the pixel code as the row input. Outside the two
//phases every one of these is 0.
assign tch_sel = (phase == SCORE) | (phase == DRAIN);

assign tch_w_ld = (phase == SCORE) ? 4'b0101 : 4'b0000;

assign tch_w = (phase == SCORE) ? {24'd0, head8} : 32'd0;

//The code is a register, taken at the end of clock n from the byte at the head during clock n. The ring steps on
//that same edge when n mod 4 = 3, so the register still holds the code from before the step; read a clock later,
//every fourth weight would meet the next byte's pixel.
always_ff @(posedge clk)
    if(phase == SCORE)
        tch_a       <= {14'd0, code};
    else
        tch_a       <= 16'd0;


//The running sum in requant's adder. The product of weight n and code n leaves the array four clocks after the
//weight was at the head, so the adds run from n = 4 to n = 68, the first one with PH read as 0:
//
//   counter n        0    1    2    3    4      5      ...   64        65        66        67        68
//   weight at head   w0   w1   w2   w3   w4     w5           w64       DRAIN, no loads
//   tch_a            0    c0   c1   c2   c3     c4           c63       c64       0         0         0
//   p0, the product                      w0.c0  w1.c1        w60.c60   w61.c61   w62.c62   w63.c63   w64.c64
//   PH after the add                     w0.c0  +w1.c1       ...                                     the score
assign first_prod = (phase == SCORE) & (count == 7'd4);                    //the first product arrives

assign add_prod = ((phase == SCORE) & (count >= 7'd4)) | (phase == DRAIN);  //a product arrives this clock

assign tch_ma_sel = add_prod | (phase == CMP);                             //teach holds requant's adder

assign tch_ma_we = add_prod;                                               //PH takes this clock's sum
assign tch_ma_pe = add_prod;                                               //the product is one addend
assign tch_ma_clr = first_prod;                                            //PH reads as 0: the sum restarts


//--------------------------------------------------------------------------------------------------------------------
//  4. The compare
//--------------------------------------------------------------------------------------------------------------------

//The learn decision, one clock in CMP, done with the same adder: the margin is added to the score and the sign of
//the result is read. The sign alone, read against the label, says whether the score is on the wrong side or too
//close to the line:
//
//   LABEL 0, symbol A, wanted score positive:  learn when score <= TMARGIN,  so add -TMARGIN - 1 and learn on negative
//   LABEL 1, symbol B, wanted score negative:  learn when -score <= TMARGIN, so add TMARGIN and learn on not negative
//
//The bitwise complement of TMARGIN is -TMARGIN - 1 in two's complement, which is why the complement is added for
//LABEL 0. The adder's other strobes are 0 in CMP, so PH keeps the score and the result is only read.
always_comb
    if(phase != CMP)
        tch_ma_b = 17'd0;
    else if(label)
        tch_ma_b = {4'd0, tmargin};
    else
        tch_ma_b = ~{4'd0, tmargin};

assign learn = ma_neg ^ label;                                   //the sum's sign read against the label: 1 learns


//LEARNED, read by TCH_READ: 1 when the last TCH_LEARN updated the weights. Cleared at the go of TCH_CLEAR and
//TCH_SCORE, taken from the compare, held otherwise.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        tch_learned     <= 1'b0;
    else if(go_clear | go_score)
        tch_learned     <= 1'b0;
    else if(phase == CMP)
        tch_learned     <= learn;


//--------------------------------------------------------------------------------------------------------------------
//  5. The update
//--------------------------------------------------------------------------------------------------------------------

//What the ring's tail takes at each edge: 2 writes zero (CLEAR), 1 writes the updated weight (UPDATE), 0 lets the
//word at the head go around unchanged.
always_comb
    case(phase)
    CLEAR:      tr_sel = 2'd2;
    UPDATE:     tr_sel = 2'd1;
    default:    tr_sel = 2'd0;
    endcase

//The updated weight: the weight at the head moves by its pixel code times TSTEP, toward positive for symbol A and
//toward negative for symbol B, and is held within -31 to 31. The bias, with code 1, moves by TSTEP.
assign delta = {4'd0, code} * {2'd0, tstep};                                    //code times TSTEP, at most 45

assign sum = label ? (head8 - {2'd0, delta}) : (head8 + {2'd0, delta});         //the moved weight, before the limit

assign tr_in = (sum > 8'sd31) ? 6'sd31 : ((sum < -8'sd31) ? -6'sd31 : sum[5:0]);    //the limit, -31 to 31


//--------------------------------------------------------------------------------------------------------------------
//  6. The readback and the weight map
//--------------------------------------------------------------------------------------------------------------------

//TCH_READ's words. The score is PH's low 14 bits, which hold the whole range of a score, sign-extended to 16. The
//bias is read when the ring brings it to the head, so the decoder waits for tch_bias_ok before its last byte.
assign tch_score = { {2{ma_q[13]}}, ma_q[13:0] };

assign tch_bias = head8;                                                        //the word at the head

assign tch_bias_ok = (tr_hpos == 7'd64);                                        //the word at the head is the bias


//The weight map: the display sequencer asks for weight wm_idx while it draws the map, and the ring brings that weight
//to the head within 65 clocks. The capture takes the weight and its index when they pass, and holds them until the
//next command; wm_ack says the held weight is the one asked for. A go and a capture in the same clock: the go wins.
assign map_hit = wm_req & (tr_hpos == {1'b0, wm_idx});                          //the requested weight is at the head

always_ff @(posedge clk)
    if(map_hit)
        begin
        map_w       <= tr_head;
        map_idx     <= wm_idx;
        end

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        map_valid       <= 1'b0;
    else if(go)
        map_valid       <= 1'b0;                //a new command: the capture is stale
    else if(map_hit)
        map_valid       <= 1'b1;

assign wm_ack = map_valid & (map_idx == wm_idx);                                //the held weight is the one asked for

assign wm_w = { {2{map_w[5]}}, map_w };                                         //the held weight, sign-extended

wire unused = &{1'b0, arg_byte[7:1], ma_q[17:14]};

endmodule
