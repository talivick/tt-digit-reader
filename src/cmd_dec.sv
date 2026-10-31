// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// cmd_dec.sv : the command decoder
//
// Description
//   Takes the host's bytes over the four-phase handshake, decodes the commands for the
//   blocks, supplies the response bytes and keeps the error and status bits.
//
// Parameters
//   HAS_DIGIT, HAS_DISPLAY, HAS_TEACH and HAS_ATTRACT, 1, 1, 1 and 0 in the chip, say
//   which blocks are present; a command or register of an absent block is unknown. ID's
//   second byte is {HAS_TEACH, HAS_ATTRACT, 6-bit form code}; the form code is 1 with
//   HAS_DIGIT and HAS_DISPLAY, 2 with neither, 3 with HAS_DISPLAY alone and 4 with
//   HAS_DIGIT alone.
//
// Operation
//   A byte is taken while "in_valid_s" is high, once it has been low after reset; a read
//   puts the response on "resp_byte" with "resp_oe" high.
//   Argument byte k pulses "arg_we" with "arg_idx" = k and "arg_byte"; "go" pulses after
//   the last argument, or after the command byte when there is none. REG_WR to a mapped
//   address pulses "reg_we", MX_START "mx_start", CLR_ERR "err_clr", MX_READ "res_ready"
//   for a waiting result and MX_ROW "row_valid"; a row with "row_ready" low sets ERR_OVF.
//   NOP, ID, STATUS and CLR_ERR are always served. Any other command byte is held,
//   "in_ready" low, while "disp_busy" or "walk_busy" is high; during a matrix run TILE,
//   TCH_SCORE, TCH_LEARN and ATT_FRAME are taken and ignored, with ERR_BUSY.
//   A response byte that needs a block waits for "tp_valid", "acc_ack" or "tch_bias_ok".
//
// Timing
//   "in_ready" rises one clock after the take and falls one edge after "in_valid_s"
//   falls. A block raises its busy no later than one clock after "go".
//
// Reset
//   "rst_n" is asynchronous and active low. It resets the handshake to idle, "resp_oe",
//   ARMED and the errors to 0 and RST_SEEN to 1. The captured bytes have no reset.

`default_nettype none

module cmd_dec #(
    parameter bit HAS_DIGIT = 1'b1, //digit path present (sets the form code in ID); parameter bit: one bit in ID's byte
    parameter bit HAS_DISPLAY = 1'b1,   //display path present
    parameter bit HAS_TEACH = 1'b1, //teach mode present (ID bit 7)
    parameter bit HAS_ATTRACT = 1'b0    //attract mode present (ID bit 6); 0 in this chip
) (
    input  logic               clk,          //rising edge
    input  logic               rst_n,        //asynchronous, active low; resets the handshake state, ARMED and the status bits
    input  logic               in_valid_s,   //the synchronized in_valid
    input  logic        [7:0]  ui_in,        //the host byte
    output logic               in_ready,     //to uio_out[6]
    output logic        [7:0]  resp_byte,    //the response byte
    output logic               resp_oe,      //select the response onto uo_out
    output logic        [7:0]  cmd,          //the command byte; command bus to the blocks
    output logic               arg_we,       //pulse: an argument byte is on arg_byte
    output logic        [3:0]  arg_idx,      //the argument's index, 0 first
    output logic        [7:0]  arg_byte,     //the argument byte
    output logic               go,           //pulse: the command is complete, after its last argument
    output logic               reg_we,       //register write strobe; register bus (REG_WR)
    output logic        [7:0]  reg_addr,     //register address
    output logic        [7:0]  reg_wdata,    //register write data
    output logic               mx_start,     //pulse to ctrl: start a run
    output logic               err_clr,      //pulse to ctrl: clear mx_err
    output logic               row_valid,    //MX_ROW: a row is offered to mx_top
    output logic        [15:0] row_data,     //the row
    input  logic               row_ready,    //from mx_top
    input  logic               res_valid,    //MX_READ: a result is ready
    input  logic        [15:0] res_data,     //the result
    output logic               res_ready,    //pops the result
    input  logic        [1:0]  fifo_count,   //status input
    input  logic               mx_busy,      //status input
    input  logic               mx_done,      //status input
    input  logic               mx_err,       //status input
    input  logic               disp_busy,    //hold input: the display is busy
    input  logic               walk_busy,    //hold input: the walker is busy
    input  logic        [11:0] tp_value,     //TP_READ's value
    input  logic               tp_valid,     //valid of tp_value
    output logic               dec_acc_req,  //DIG_READ's request to the accumulator ring
    output logic        [3:0]  dec_acc_idx,  //the accumulator requested
    input  logic signed [11:0] acc_val,      //the ring's head
    input  logic               acc_ack,      //the head is the one requested
    input  logic        [3:0]  winner,       //the argmax winner (DIG_READ and S2)
    input  logic               win_valid,    //valid of winner
    input  logic signed [15:0] tch_score,    //TCH_READ: the score
    input  logic               tch_learned,  //TCH_READ: LEARNED
    input  logic signed [7:0]  tch_bias,     //TCH_READ: the bias word
    input  logic               tch_bias_ok   //TCH_READ: the bias word is at the ring's head
);

//Command codes: the commands this decoder knows, with the values of address_map.sv's CMD_ names.
localparam logic [7:0] NOP = 8'h00, ID = 8'h01, STATUS = 8'h02, CLR_ERR = 8'h03, REG_WR = 8'h04,
                       SEG_SHOW = 8'h10, SEG_WINNER = 8'h11, MX_START = 8'h20, MX_ROW = 8'h21,
                       MX_READ = 8'h22;

localparam logic [7:0] DIG_START = 8'h30, IMG = 8'h31, TILE = 8'h32, DIG_ARGMAX = 8'h33,
                       DIG_READ = 8'h34;
                    
//State codes: the handshake states and the three phases of a transfer. A transfer is one command byte, then its
//argument bytes, then its response bytes.
localparam logic [1:0] HS_IDLE = 2'd0, HS_PREP = 2'd1, HS_ACK = 2'd2;
localparam logic [1:0] PHASE_CMD = 2'd0, PHASE_ARG = 2'd1, PHASE_RESP = 2'd2;
 
logic       armed;       //1 once in_valid_s has been 0 after a reset; no byte is taken before that
logic [1:0] hs_state;    //HS_IDLE waits for a byte; HS_PREP is the clock after a take; HS_ACK holds in_ready at 1
logic [1:0] phase;       //which byte of the transfer comes next: the command byte, an argument byte or a response byte
logic [4:0] byte_idx;    //the argument or response byte being taken, 0 first; 5 bits for DIG_READ's 21 response bytes
logic       rst_seen;    //1 after a reset until STATUS supplies S1; S1 bit 7
logic       err_cmd;     //an unknown command byte, or a REG_WR to an address no block owns; S1 bit 0
logic       err_busy;    //a TILE taken during a matrix run and ignored; S1 bit 1
logic       err_ovf;     //a MX_ROW row arrived while mx_top could not take it (row_ready = 0); S1 bit 2
logic       v;           //res_valid as MX_READ's first response byte saw it; bytes 2 and 3 and res_ready use this copy
logic       refused;     //the current transfer is a TILE taken during a matrix run; no arg_we and no go for its bytes
logic       held;        //the command byte must wait: the display or the walker is busy and it is not NOP, ID, STATUS or CLR_ERR
logic       take;        //1 in the clock a byte is taken from ui_in or a response byte is loaded
logic [7:0] code;        //the command being decoded: ui_in for the command byte, afterwards the stored cmd
logic       known;       //code is a command this decoder knows; an unknown command byte sets err_cmd
logic [4:0] arg_count;   //the number of argument bytes of code
logic [4:0] resp_count;  //the number of response bytes of code
logic       last;        //1 when byte_idx is the last argument byte or the last response byte of code
logic       take_cmd;    //take split by phase: the command byte
logic       take_arg;    //an argument byte
logic       take_resp;   //a response byte
logic       mapped;      //the REG_WR address is one of ctrl's registers, 0x10 to 0x1D
logic [7:0] s0;          //status byte 0
logic [7:0] s1;          //status byte 1
logic [7:0] s2;          //status byte 2
logic [5:0] form_code;   //ID's second byte, bits 5:0: which blocks this build has
logic [7:0] resp_mux;    //the response byte for code and byte_idx; loaded into resp_byte at the take
logic       refuse;      //the command byte on ui_in is a TILE and the matrix unit is busy
logic [4:0] acc_pos;     //DIG_READ response byte n (1 to 20) gives n - 1: bits 4:1 the accumulator, bit 0 the low byte
logic       acc_wait;    //a DIG_READ accumulator byte waits for the accumulator ring to deliver the one asked for

//Byte capture: a byte is taken when the handshake is idle, the decoder is armed, the host has raised
//in_valid_s, and nothing holds the byte back. held keeps a command byte waiting while the display or the
//tile walker is busy; acc_wait keeps a DIG_READ response byte waiting until the accumulator ring has the value.
assign held = (phase == PHASE_CMD) & (disp_busy | walk_busy) & (ui_in > 8'h03);   
assign take = (hs_state == HS_IDLE) & armed & in_valid_s & ~held & ~acc_wait;

//Handshake: the four-phase handshake with the host. take is the clock the byte is captured. One
//clock later hs_state is HS_PREP and in_ready rises. in_ready and the response stay until the host lowers
//in_valid; then both fall and the handshake is idle again. armed blocks every byte until in_valid_s has
//been 0 once after reset, so a host holding in_valid high through the reset gets no byte taken by mistake.
always_ff @(posedge clk or negedge rst_n)
    begin
    if(~rst_n)
        begin
        armed       <= 1'b0;
        hs_state    <= HS_IDLE;
        in_ready    <= 1'b0;
        resp_oe     <= 1'b0;
        end
    else
        begin
        if(~in_valid_s)
            armed       <= 1'b1;

        if(take)
            hs_state    <= HS_PREP;
        else if(hs_state == HS_PREP)
            hs_state    <= HS_ACK;
        else if((hs_state == HS_ACK) & ~in_valid_s)
            hs_state    <= HS_IDLE;

        if(hs_state == HS_PREP)
            in_ready    <= 1'b1;
        else if((hs_state == HS_ACK) & ~in_valid_s)
            in_ready    <= 1'b0;

        if(take_resp)
            resp_oe     <= 1'b1;
        else if((hs_state == HS_ACK) & ~in_valid_s)
            resp_oe     <= 1'b0;
        end
    end
            
   
assign code = (phase == PHASE_CMD) ? ui_in : cmd;

//Command table: every command the decoder knows has a fixed number of argument bytes and response
//bytes. The three lines before the case are the values for a command with no arguments and no response;
//each row changes only what differs. The digit path's commands are known only when HAS_DIGIT is 1.
always_comb
    begin
    known = 1'b1;
    arg_count = 5'd0;
    resp_count = 5'd0;       
    case(code)
    NOP, CLR_ERR, SEG_WINNER, MX_START: /*default*/ ;
                                        
    ID:                                 resp_count = 5'd2;

    STATUS, MX_READ:                    resp_count = 5'd3;
    
    REG_WR, MX_ROW:                     arg_count = 5'd2;
    
    SEG_SHOW:                           arg_count = 5'd1;
    
    DIG_START:  begin                   known = HAS_DIGIT; arg_count = 5'd10; end
    
    IMG:        begin                   known = HAS_DIGIT; arg_count = 5'd16; end
    
    TILE:       begin                   known = HAS_DIGIT; arg_count = 5'd2; end
    
    DIG_ARGMAX:                         known = HAS_DIGIT;
    
    DIG_READ:   begin                   known = HAS_DIGIT; resp_count = 5'd21; end
    
    default:                            known = 1'b0;
    endcase
    end

assign take_cmd = take & (phase == PHASE_CMD);
assign take_arg = take & (phase == PHASE_ARG);
assign take_resp = take & (phase == PHASE_RESP);

assign last = (phase == PHASE_ARG) ? (byte_idx == (arg_count - 5'd1)):
                                     (byte_idx == (resp_count - 5'd1));

//Transfer sequence: after the command byte, arguments if the command has any, else responses if it
//has any, else the next command byte. After the last argument: responses if any, else the next command
//byte. byte_idx counts the bytes of the current phase from 0 and restarts for the responses. An unknown
//command byte leaves phase at PHASE_CMD.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        phase       <= PHASE_CMD;
        byte_idx    <= '0;
        end
    else    
        begin
        if(take_cmd & known & (arg_count != 5'd0))
            phase       <= PHASE_ARG;
        else if(take_cmd & known & (resp_count != 5'd0))
            phase       <= PHASE_RESP;
        else if(take_arg & last & (resp_count != 5'd0))
            phase       <= PHASE_RESP;
        else if(take_arg & last)
            phase       <= PHASE_CMD;
        else if(take_resp & last)
            phase       <= PHASE_CMD;
            
        if(take_cmd)
            byte_idx    <= 5'd0;
        else if(take_arg & last)
            byte_idx    <= 5'd0;
        else if(take)   
            byte_idx    <= byte_idx + 5'd1;
        end

//Data registers: the bytes kept from the bus, with no reset; each is written before it is read.
//arg_byte and arg_idx go to the blocks with arg_we one clock later. REG_WR's two bytes are the address
//and the data. MX_ROW's two bytes are the row, first byte low.
always_ff @(posedge clk)
    begin
    if(take_cmd)
        cmd         <= ui_in;
        
    if(take_arg)
        arg_byte    <= ui_in;        
    if(take_arg)   
        arg_idx     <= byte_idx[3:0];
        
    if(take_arg & (code == REG_WR) & (byte_idx == 5'd0))
        reg_addr    <= ui_in;       
    if(take_arg & (code == REG_WR) & (byte_idx == 5'd1))
        reg_wdata   <= ui_in;
        
    if(take_arg & (code == MX_ROW) & (byte_idx == 5'd0))
        row_data[7:0]   <= ui_in;
    if(take_arg & (code == MX_ROW) & (byte_idx == 5'd1))
        row_data[15:8]  <= ui_in;
    end
        
//Strobes to the blocks: each pulse is one clock wide, in the clock after the byte that causes it. go marks a
//complete command: after the command byte when it has no arguments, else after the last argument.
//A TILE taken during a run (refused) gives no arg_we and no go. reg_we needs a mapped address;
//row_valid needs row_ready = 1 in the clock of the take; res_ready needs v = 1.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        arg_we      <= 1'b0;
        go          <= 1'b0;
        reg_we      <= 1'b0;
        mx_start    <= 1'b0;
        err_clr     <= 1'b0;
        row_valid   <= 1'b0;
        res_ready   <= 1'b0;
        end
    else
        begin
        if(take_arg & ~refused)
            arg_we      <= 1'b1;
        else
            arg_we      <= 1'b0;
            
        if(take_cmd & known & (arg_count == 5'd0))
            go          <= 1'b1;
        else if(take_arg & last & ~refused)
            go          <= 1'b1;
        else
            go          <= 1'b0;
        
        if(take_arg & last & (code == REG_WR) & mapped)
            reg_we      <= 1'b1;
        else
            reg_we      <= 1'b0;
        
        if(take_cmd & (code == MX_START))
            mx_start    <= 1'b1;
        else
            mx_start    <= 1'b0;
            
        if(take_cmd & (code == CLR_ERR))
            err_clr     <= 1'b1;
        else
            err_clr     <= 1'b0;
            
        if(take_arg & last & (code == MX_ROW) & row_ready)
            row_valid   <= 1'b1;
        else
            row_valid   <= 1'b0;
            
        if(take_resp & last & (code == MX_READ) & v) 
            res_ready   <= 1'b1;
        else
            res_ready   <= 1'b0;
        end

assign mapped = (reg_addr >= address_map::REG_MX_FIRST) & (reg_addr <= address_map::REG_MX_LAST);

//Status bits: rst_seen clears in the clock S1 is loaded, so the S1 the host reads still shows it.
//Each error bit sets on its event and clears on err_clr; an event in the clock of err_clr wins.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        rst_seen    <= 1'b1;
        err_cmd     <= 1'b0;
        err_busy    <= 1'b0;
        err_ovf     <= 1'b0;
        end
    else
        begin
        if(take_resp & (code == STATUS) & (byte_idx == 5'd1))
            rst_seen    <= 1'b0;
            
        if(take_cmd & ~known)
            err_cmd     <= 1'b1;
        else if(take_arg & last & (code == REG_WR) & ~mapped)
            err_cmd     <= 1'b1;
        else if(err_clr)
            err_cmd     <= 1'b0;
            
        if(take_cmd & refuse)
            err_busy    <= 1'b1;
        else if(err_clr)
            err_busy    <= 1'b0;
        
        if(take_arg & last & (code == MX_ROW) & ~row_ready)
            err_ovf     <= 1'b1;
        else if(err_clr)
            err_ovf     <= 1'b0;
        end
        
//Status bytes: the three bytes STATUS returns.
//S0: bit 7 is 0, bits 6:5 the FIFO count, bit 4 res_valid, 3 mx_done, 2 mx_busy, 1 walk_busy, 0 disp_busy.
//S1: bit 7 rst_seen, bits 6:4 are 0, bit 3 mx_err, 2 err_ovf, 1 err_busy, 0 err_cmd.
//S2: bit 7 win_valid, bits 6:4 are 0, bits 3:0 the winner.
assign s0 = {1'b0, fifo_count, res_valid, mx_done, mx_busy, walk_busy, disp_busy};
assign s1 = {rst_seen, 3'b000, mx_err, err_ovf, err_busy, err_cmd};
assign s2 = {win_valid, 3'b000, winner};

//MX_READ's first byte reports res_valid. The copy decides what the next two bytes carry and whether the
//result is popped, so a result arriving between the bytes does not change the answer part way through.
always_ff @(posedge clk)
    if(take_resp & (code == MX_READ) & (byte_idx == 5'd0))
        v       <= res_valid;

//form_code: 1 the digit reader with the display, 2 the matrix unit alone, 3 the display without the digit reader,
//4 the digit reader without the display.
assign form_code = HAS_DIGIT ? (HAS_DISPLAY ? 6'd1 : 6'd4) :
                               (HAS_DISPLAY ? 6'd3 : 6'd2);

//Response mux: the response byte for the current command and byte index. ID: 0x44, then {HAS_TEACH, HAS_ATTRACT,
//form_code}. STATUS: S0, S1, S2. MX_READ: {7'b0, res_valid}, then the result's low byte and high byte,
//or 0x00 bytes when no result was waiting. DIG_READ: S2, then each accumulator high byte first, the high
//byte sign-extended from 12 bits to 16; the value comes from the accumulator ring on acc_val.
always_comb
    case(code)
    ID:         begin if(byte_idx == 5'd0)       resp_mux = 8'h44;
                      else                       resp_mux = {HAS_TEACH, HAS_ATTRACT, form_code};
                end

    STATUS:     begin if(byte_idx == 5'd0)       resp_mux = s0;
                      else if(byte_idx == 5'd1)  resp_mux = s1;
                      else                       resp_mux = s2;
                end

    MX_READ:    begin if(byte_idx == 5'd0)       resp_mux = {7'b0, res_valid};
                      else if(byte_idx == 5'd1)  resp_mux = v ? res_data[7:0]  : 8'h00;
                      else                       resp_mux = v ? res_data[15:8] : 8'h00;
                end

    DIG_READ:   begin if(byte_idx == 5'd0)       resp_mux = s2;
                      else                       resp_mux = acc_pos[0] ? acc_val[7:0] : { {4{acc_val[11]}}, acc_val[11:8] };
                end

    default:    resp_mux = 8'h00;
    endcase
    
always_ff @(posedge clk)
    if(take_resp)
        resp_byte   <= resp_mux;  //loaded in the clock of the take; the top puts it on uo_out while resp_oe is 1

//DIG_READ's accumulator bytes: from the clock after S2 is taken until the last byte, dec_acc_req asks
//the accumulator ring for accumulator dec_acc_idx. The byte is taken only when acc_ack says the ring's
//head is that accumulator; until then acc_wait holds take at 0 and the host waits on in_ready.
assign dec_acc_req = (phase == PHASE_RESP) & (code == DIG_READ) & (byte_idx != 5'd0);
assign dec_acc_idx = acc_pos[4:1];

//TILE refused during a matrix run: refuse is read in the clock of the command byte; refused keeps the decision
//for the two argument bytes that follow.
assign refuse = HAS_DIGIT & (code == TILE) & mx_busy;
always_ff @(posedge clk)
    if(take_cmd)
        refused <= refuse;
        
assign acc_pos = byte_idx - 5'd1;        
assign acc_wait = dec_acc_req & ~acc_ack;

endmodule
