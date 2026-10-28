// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// ctrl.sv : matrix control: the configuration registers 0x10 to 0x1D, the run state machine, the status bits.
// Project: Digit reader on Tiny Tapeout SKY26d.
//
// Notes on module ctrl
//   Registers: M (8 bits), scale (16: 0x11 low byte, 0x1D high byte), shift (5) and ReLU
//   (MX_SHIFT bits 4:0 and 7), bias0 and bias1 (17 each). Written only in IDLE.
//   MX_W00 to MX_W11 have no register here: a write to 0x19 to 0x1C pulses mx_w_ld bit 0 to 3
//   in its data clock with mx_w = reg_wdata.
//   mx_busy = not IDLE. mx_start or a write to 0x10 to 0x1D while busy is ignored and sets mx_err;
//   err_clr clears it.
//   Resets: the state, mx_done and mx_err reset with rst_n (asynchronous). The counters and the
//   configuration registers have none: the host writes the configuration before a run, and every
//   read of a counter follows its clear at the start of the run.

`default_nettype none
import address_map::*;

module ctrl (
	input  logic               clk,        //rising edge
	input  logic               rst_n,      //asynchronous, active low; resets the state machine and the status bits; the configuration registers have no reset
	input  logic               reg_we,     //register write strobe; ctrl owns 0x10 to 0x1D
	input  logic        [7:0]  reg_addr,   //register address
	input  logic        [7:0]  reg_wdata,  //register write data
	input  logic               mx_start,   //pulse from cmd_dec: start a run
	input  logic               err_clr,    //pulse from cmd_dec: clear mx_err
	input  logic               row_pop,    //from mx_top: a row entered the array
	input  logic               res_pop,    //from mx_top: a result left
	output logic               stream_en,  //to mx_top
	output logic        [3:0]  mx_w_ld,    //a write to 0x19, 0x1A, 0x1B, 0x1C pulses bit 0, 1, 2, 3 in its data clock
	output logic        [7:0]  mx_w,       //= reg_wdata in that clock
	output logic signed [16:0] bias0,      //the column 0 bias (MX_BIAS0_HI, MX_BIAS0_MID, MX_BIAS0_LO)
	output logic signed [16:0] bias1,      //the column 1 bias (MX_BIAS1_HI, MX_BIAS1_MID, MX_BIAS1_LO)
	output logic        [15:0] scale,      //the unsigned scale (MX_SCALE_LO, MX_SCALE_HI)
	output logic        [4:0]  shift,      //S, the shift count (MX_SHIFT bits 4:0)
	output logic               relu,       //the ReLU enable (MX_SHIFT bit 7)
	output logic               mx_busy,    //status: a run in progress
	output logic               mx_done,    //status: the last run finished
	output logic               mx_err      //status: an error since the last err_clr
);

//The run's state. IDLE: waits for mx_start; the only state that takes register writes.
//LOAD: one clock, loads nothing (the weights load at their own writes). STREAM: rows pop
//into the array. DRAIN: waits for the last result.
enum logic [1:0] {IDLE, LOAD, STREAM, DRAIN} state, next_state;	
logic in_range;
logic wr_ok;
logic [7:0] row_count;
logic [7:0] res_count;
logic [7:0] m; 												//M, the number of rows in one matrix run. The host writes it to MX_M (0x10) before MX_START,
															//so it has no reset. The run streams m rows into the array and waits for m
															//results, then ends with mx_done; m = 0 ends the run in LOAD, at once, with mx_done. Internal
															//only, not a port 

assign in_range = (reg_addr >= REG_MX_FIRST) && (reg_addr <= REG_MX_LAST);	//the address is one of ctrl's
assign wr_ok = reg_we & in_range & (state == IDLE);							//write OK: a write to one of ctrl's addresses, in IDLE; 0 while busy, so a write while busy changes nothing here and sets mx_err below
	
assign mx_w_ld[0] = wr_ok & (reg_addr == REG_MX_W00);		//matrix weight load pulse, one bit per PE; no pulse while busy, since wr_ok = 0
assign mx_w_ld[1] = wr_ok & (reg_addr == REG_MX_W01);
assign mx_w_ld[2] = wr_ok & (reg_addr == REG_MX_W10);
assign mx_w_ld[3] = wr_ok & (reg_addr == REG_MX_W11);

assign mx_w = reg_wdata;									//matrix weight, the data of a weight write; a PE takes it only with its mx_w_ld bit at 1

//Register decoding (no reset): the host writes these before a run. scale and the biases are written
//a byte at a time at separate addresses; the bits a layout leaves unused are ignored.
always_ff @(posedge clk)
	begin
	//m
	if(wr_ok & (reg_addr == REG_MX_M))			//rows per run, MX_M (0x10); m = 0 ends a run at once
		m 			<= reg_wdata;
	
	//scale
	if(wr_ok & (reg_addr == REG_MX_SCALE_LO)) 	//the unsigned scale
		scale[7:0] 	<= reg_wdata;
	if(wr_ok & (reg_addr == REG_MX_SCALE_HI))
		scale[15:8] <= reg_wdata;
	
	//shift and ReLU
	if(wr_ok & (reg_addr == REG_MX_SHIFT))		//S, the shift count (MX_SHIFT bits 4:0) 
		begin									//the ReLU enable relu = 1: requant turns a negative result into 0
		shift 		<= reg_wdata[4:0];
		relu 		<= reg_wdata[7];
		end
	
	//bias0
	if(wr_ok & (reg_addr == REG_MX_BIAS0_LO))	//the column 0 bias, 17-bit signed,two's complement
		bias0[7:0] <= reg_wdata;
	if(wr_ok & (reg_addr == REG_MX_BIAS0_MID))
		bias0[15:8] <= reg_wdata;		
	if(wr_ok & (reg_addr == REG_MX_BIAS0_HI))
		bias0[16] <= reg_wdata[0];
 
 	//bias1
	if(wr_ok & (reg_addr == REG_MX_BIAS1_LO))	//the column 1 bias, 17-bit signed,two's complement
		bias1[7:0] <= reg_wdata;
	if(wr_ok & (reg_addr == REG_MX_BIAS1_MID))
		bias1[15:8] <= reg_wdata;		
	if(wr_ok & (reg_addr == REG_MX_BIAS1_HI))
		bias1[16] <= reg_wdata[0];
	end

always_ff @(posedge clk or negedge rst_n)
	if(~rst_n)
		state	<= IDLE;
	else
		state 	<= next_state;
		
//Next state: the five transitions, numbered as in Diagram 5a, tested in this order
always_comb
	case(state)
	IDLE: 	begin if(mx_start)								next_state = LOAD;	//1. a start
				  else 										next_state = IDLE;
			end
		  
	LOAD: 	begin if(m == '0) 								next_state = IDLE;	//2. nothing to stream: IDLE with mx_done
				  else   									next_state = STREAM;	//3. rows to stream
			end
		  
	STREAM:	begin if(row_pop & ((row_count + 8'd1) == m))	next_state = DRAIN;	//4. the M-th row popped
				  else										next_state = STREAM;
			end
	
	DRAIN:  begin if(res_pop & ((res_count + 8'd1) == m))	next_state = IDLE;	//5. the M-th result popped: IDLE with mx_done
			else											next_state = DRAIN;
			end
	
	default:												next_state = IDLE;
	endcase
	
assign stream_en = (state == STREAM);	//stream enable: rows may pop

assign mx_busy = (state != IDLE);		//a run is in progress, status S0 bit 2, mx_err reads it	

always_ff @(posedge clk)
	begin  
	//the rows popped in this run; no reset: every read follows the clear at start (STREAM is reached only through IDLE with mx_start)
	if((state == IDLE) & mx_start)
		row_count <= 8'd0;	
	else if((state == STREAM) & row_pop)
		row_count <= row_count + 8'd1;
		
	//the results popped in this run; counts in STREAM too, because results return while rows still stream
	if((state == IDLE) & mx_start)	
		res_count <= 8'd0;
	else if(((state == STREAM) | (state == DRAIN)) & res_pop)
		res_count <= res_count + 8'd1;
	end

always_ff @(posedge clk or negedge rst_n)
	begin
	//one reset branch for the block: both status bits to 0
	if(~rst_n)
		begin
		mx_done <= 1'b0;
		mx_err 	<= 1'b0;
		end
	else
		begin
		//the run ended: set by the two transitions back to IDLE (2 and 5), cleared by the next start (1);
		//reset 0 so S0 reads 0x00 after reset, since the host can read STATUS before the first start
		if((state == IDLE) & mx_start)
			mx_done <= 1'b0;
		else if((state == LOAD) & (m == '0))
			mx_done <= 1'b1;
		else if((state == DRAIN) & res_pop & ((res_count + 8'd1) == m))
			mx_done <= 1'b1;

		//a command for ctrl came while busy: an mx_start, or a write to one of ctrl's addresses (a write to
		//another block's address sets nothing, in_range = 0). err_clr clears it; a clear and a set in the same
		//clock: the clear wins here (cmd_dec never produces that clock, one command at a time)
		if(err_clr)
			mx_err 	<= 1'b0;
		else if(mx_busy & (mx_start | (reg_we & in_range)))
			mx_err 	<= 1'b1;
		end
	end
		
endmodule
