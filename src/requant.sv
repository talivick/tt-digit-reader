// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// requant.sv : requantize unit shared by both columns: bias, scale, round, clamp, ReLU.
// Project: Digit reader on Tiny Tapeout SKY26d.
//
// Notes on module requant
//   The product register, the rounding bit R and y have no reset.
//   Per column: t1 = p + bias (18 bits signed); t2 = t1 * scale; t3 = round half up of t2 / 2^S;
//   t4 = t3 clamped to -128..127; y = relu ? max(t4, 0) : t4.
//   One result takes 37 + 2S clocks from the clock that pops its row into the array.

`default_nettype none

module requant #(
    parameter SCALE_W = 16  //width of scale; 16 in the chip and in the tests
) (
    input  logic                      clk,      //rising edge
    input  logic                      rst_n,    //asynchronous, active low; resets the state, the step counter, the column bit and y_valid
    input  logic signed [16:0]        p0,       //column 0 sum (the array's p_out[16:0]); the array holds it while the unit works
    input  logic signed [16:0]        p1,       //column 1 sum (the array's p_out[33:17]); held likewise
    input  logic                      p_valid,  //a matrix row's sums are on p0, p1 (mx_top's rq_v)
    output logic                      take,     //pulse: both columns are done; the array may advance
    input  logic signed [16:0]        bias0,    //column 0 bias
    input  logic signed [16:0]        bias1,    //column 1 bias
    input  logic        [SCALE_W-1:0] scale,    //unsigned scale
    input  logic        [4:0]         shift,    //S, the shift count
    input  logic                      relu,     //ReLU enable
    output logic        [15:0]        y,        //result {y1, y0}
    output logic                      y_valid,  //valid of y
    input  logic                      y_ready,  //pops the result
    input  logic                      ma_sel,   //the modes use the adder
    input  logic                      ma_we,    //the modes write PH
    input  logic                      ma_clr,   //the modes read PH as 0
    input  logic                      ma_pe,    //the modes add p0
    input  logic signed [16:0]        ma_b,     //the modes' addend
    output logic signed [17:0]        ma_q,     //PH, the high part of the product register
    output logic                      ma_neg    //sign of the 19-bit sum in the modes' use
);

//How a row becomes two result bytes, one column at a time (col_bit picks the column):
//  t1 = column sum + bias                          18-bit signed
//  {ph, pl} = t1 * scale                           MULT, 16 clocks: add t1 when the scale bit pl[0] is 1, then shift the pair right
//  {ph, pl} >>= shift, r_bit = the last bit out    SHFT, shift clocks: arithmetic shift; r_bit rounds half up
//  y_byte = clamp(q[7:0] + r_bit), then ReLU       WR, 1 clock: column 0 into y[7:0], column 1 into y[15:8]
//Teach mode (ma_sel = 1, only while IDLE) borrows the adder: it adds t1 = (ma_pe ? p0 : 0) + ma_b
//  to ph (or to 0 when ma_clr); ma_we loads ph with the sum; ma_q = ph; ma_neg = the sum's sign.

//Registers
enum logic   [1:0]   {IDLE, MULT, SHFT, WR} state, next_state; //the state and its next value
logic        [4:0]  step_cnt;         //clock count inside MULT (0 to 15) and SHFT (0 to shift - 1)
logic               col_bit;          //column in work: 0 first, 1 second
logic signed [17:0] ph;               //product high bits [33:16] of {ph, pl}
logic        [15:0] pl;               //product low bits [15:0]; holds scale at the start, bit 0 is the current scale bit
logic               r_bit;            //rounding bit: the last bit shifted out in SHFT

//Wires
logic signed [16:0] t1_a, t1_b;       //the two operands of t1: sum and bias, or the modes' operand and addend
logic signed [17:0] t1;
logic signed [18:0] add_a, add_b, s;  //the 19-bit adder: s = add_a + add_b
logic signed [33:0] q;                //the product after the shift, {ph, pl}
logic signed [7:0]  y_pre;            //q clamped to -128..127, rounded
logic        [7:0]  y_byte;           //y_pre after ReLU
logic               start;            //a row starts: sums valid and the result register free

assign start = p_valid & (~y_valid | y_ready);
assign s      = add_a + add_b;
assign q      = {ph, pl};
assign y_pre = (q >= 127) ? 8'sd127 : (q < -128) ? 8'sh80 : q[7:0] + {7'b0, r_bit};  //clamp (8'sh80 is -128); in range: round half up
assign y_byte = (relu & y_pre[7]) ? 8'd0 : y_pre;                       //ReLU: a negative byte becomes 0

assign t1_a  = ma_sel ? (ma_pe ? p0 : 17'sd0) : (col_bit ? p1 : p0);    //ma_sel: the modes' operand
assign t1_b  = ma_sel ? ma_b : (col_bit ? bias1 : bias0);               //ma_sel: the modes' addend
assign t1 = t1_a + t1_b;
assign add_a = (ma_sel & ma_clr) ? 19'sd0 : 19'(ph);                    //ma_clr: the modes read ph as 0
assign add_b = (ma_sel | pl[0]) ? 19'(t1) : 19'sd0;                     //add t1 on a MULT clock whose scale bit is 1
assign take   = (state == WR) & col_bit;                                //release the array after column 1

//For teach mode
assign ma_q   = ph;
assign ma_neg = s[18];
 
always_ff @(posedge clk or negedge rst_n) //Control: the registers with a reset
    begin                       
    if (~rst_n) 
        begin
        state    <= IDLE;
        step_cnt <= '0;
        col_bit  <= 1'b0;
        y_valid  <= 1'b0;
        end
    else
        begin
        state <= next_state;
        if (y_ready)
            y_valid <= 1'b0;
        
        if(state == IDLE) 
            if(start) //a row starts: column 0
                begin
                col_bit     <= 1'b0;
                step_cnt    <= '0;
                end
                
        if(state == MULT) //count the 16 MULT clocks
            step_cnt    <= (step_cnt == 'd15) ? 'd0 : (step_cnt + 'd1);
            
        if(state == SHFT) //count the shift clocks
            step_cnt    <= (step_cnt == (shift - 5'd1) ? '0 : step_cnt + 'd1);
            
        if(state == WR) 
            if(col_bit == 1'b0) //column 0 written: column 1 next
                begin
                step_cnt    <= 'd0;
                col_bit     <= 1'b1;
                end
            else /*(col_bit == 'd1)*/ //column 1 written: the row is done
                y_valid     <= 1'b1;
        end
    end
    
always_comb
    case(state)
    IDLE: begin if(start)                                       next_state = MULT; 
                else                                            next_state = IDLE;
          end
    MULT: begin if((step_cnt == 'd15) & (shift !='0))           next_state = SHFT; 
                else if((step_cnt == 'd15) & (shift == '0))     next_state = WR;
                else                                            next_state = MULT;
          end
    SHFT: begin if(step_cnt == (shift - 5'd1))                  next_state = WR;  
                else                                            next_state = SHFT;
          end
    WR:   begin if(col_bit == '0)                               next_state = MULT; 
               else /*(col_bit == 'd1)*/                        next_state = IDLE;
          end
    default:                                                    next_state = IDLE;
    endcase
    
always_ff @(posedge clk) //Data path: the registers without a reset
    begin
    if(state == IDLE) 
        if(start) //start of column 0: product register = {0, scale}
            begin
            ph          <= 'sd0;
            pl          <= scale;
            r_bit       <= 1'b0;
            end
        else if(ma_sel & ma_we) //teach mode writes the adder's sum into ph
            ph <= s[17:0];
    
    if(state == MULT) //s already holds ph + (pl[0] ? t1 : 0); shift the pair right by one
        begin
        ph          <= s[18:1];
        pl          <= {s[0], pl[15:1]};
        end
        
    if(state == SHFT) //arithmetic shift right by one; the bit leaving pl is the rounding bit
        begin
        ph          <= {ph[17], ph[17:1]};
        pl          <= {ph[0], pl[15:1]};
        r_bit       <= pl[0];
        end
        
    if(state == WR)
        if(col_bit == 1'b0) //write column 0's byte; reload for column 1
            begin
            y[7:0]      <= y_byte;
            ph          <= 'sd0;
            pl          <= scale;
            r_bit       <= 1'b0;
            end
        else /*(col_bit == 'd1)*/ //write column 1's byte
            y[15:8]     <= y_byte;
    end
    


endmodule
