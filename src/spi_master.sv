// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Thomas Livick
//
// spi_master.sv : the SPI master
//
// Description
//   Sends byte frames to the screen controller and the touch controller, which share
//   one SPI bus in mode 0 with a select each, each device at its own rate; keeps both
//   selects high for a guard time before a change of device; and receives the touch
//   controller's bytes.
//
// Operation
//   SCKDIV (0x04) and GUARD (0x05) are written through the "reg_" ports. SCKDIV bits
//   3:0 are the screen's half period in clocks minus 1 and bits 7:4 the touch's; GUARD is
//   the guard in steps of 64 clocks, 0 for none.
//   Offer a byte on "tx_byte" with "tx_valid" high, its "dc" level on "tx_dc", "tx_dev"
//   0 for the screen or 1 for the touch controller, and "tx_last" high on the frame's
//   last byte; "tx_ready" pulses when the byte is taken. Bytes offered in time go back
//   to back; otherwise "sck" stops low with the select held.
//   "rx_valid" pulses after each byte; "rx_byte", sampled from "miso_s", holds the byte
//   from that clock until the next byte's first capture. "spi_busy" is high during a
//   guard or a frame.
//
// Timing
//   A bit is H clocks with "sck" low, then H high, H being the device's SCKDIV field
//   plus 1; a byte is 16H clocks, most significant bit first. From its first take a
//   frame of n bytes keeps "spi_busy" high 16Hn + 2H clocks. The guard, GUARD * 64
//   clocks, comes before the first frame after reset and before a frame to the other
//   device. The screen needs H of at least 2 and the touch controller at least 7.
//
// Reset
//   "rst_n" is asynchronous and active low. It resets SCKDIV to 0x71 (screen H = 2,
//   touch H = 8), GUARD to 0x4F (202.24 us), the pins to "sck" 0, "mosi" 0, "dc" 1,
//   "cs_lcd_n" 1 and "cs_tp_n" 1, and the state to idle with no previous frame.

`default_nettype none

module spi_master (
    input  logic       clk,        //rising edge
    input  logic       rst_n,      //asynchronous, active low; resets SCKDIV to 0x71, GUARD to 0x4F, the pin flops (sck 0, mosi 0, dc 1, cs_lcd_n 1, cs_tp_n 1), the state
    input  logic       reg_we,     //register write strobe; SCKDIV (0x04), GUARD (0x05)
    input  logic [7:0] reg_addr,   //register address
    input  logic [7:0] reg_wdata,  //register write data
    input  logic       tx_valid,   //byte request
    input  logic [7:0] tx_byte,    //the byte to send
    input  logic       tx_dc,      //dc level for the byte
    input  logic       tx_dev,     //0 screen, 1 touch
    input  logic       tx_last,    //ends the frame
    output logic       tx_ready,   //pulse: the byte is taken
    output logic [7:0] rx_byte,    //the byte received during the byte just ended
    output logic       rx_valid,   //pulse: rx_byte is valid
    input  logic       miso_s,     //synchronized touch data
    output logic       spi_busy,   //guard or frame in progress
    output logic       sck,        //pin flop to uio_out[0]
    output logic       mosi,       //pin flop to uio_out[1]
    output logic       dc,         //pin flop to uio_out[2]
    output logic       cs_lcd_n,   //pin flop to uio_out[3]
    output logic       cs_tp_n     //pin flop to uio_out[4]
);

logic [7:0] sckdiv;
logic [7:0] guard;
logic had_frame;
logic touch_frame;
logic [13:0] guard_left;
logic last_flag;
logic [3:0] half_count;
logic [2:0] bits_left;
logic [6:0] out_bits;
logic guard_due;
logic start;
logic [3:0] h_field;
logic half_done;
logic sck_fall;
logic byte_done;
logic sel_rise;
enum logic [2:0] {IDLE, WAIT, SEND, PAUSE, TAIL, HOLD} state, next_state;


//--------------------------------------------------------------------------------------------------------------------
//  1. The control registers and the guard
//--------------------------------------------------------------------------------------------------------------------

//Control registers: SCKDIV holds, for each device, the half period of sck in clocks minus 1, the screen in bits 3:0
//and the touch controller in bits 7:4. GUARD holds the length of the guard, the quiet time with both selects high
//between a frame to one device and a frame to the other, in steps of 64 clocks. The reset values give the screen
//a half period of 2 clocks, the touch controller 8, and a guard of 79 steps, 5056 clocks.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        sckdiv      <= 8'h71;
        guard       <= 8'h4F;
        end
    else
        begin
        if(reg_we & (reg_addr == address_map::REG_SCKDIV))
            sckdiv      <= reg_wdata;

        if(reg_we & (reg_addr == address_map::REG_GUARD))
            guard       <= reg_wdata;
        end


//Guard: a quiet time with both selects high before a frame to a different device than the last frame's, and before
//the first frame after reset. A select driven high rises slowly at the device behind the display module's diode and
//100 k pull-up, so without the quiet time that device would also take the next frame's bytes. The length is GUARD
//times 64 clocks from the clock the request arrives; GUARD = 0 skips it. had_frame: a frame has started since reset.
//touch_frame: the last frame's device (1 touch). guard_due: this request needs a guard. guard_left: the count down.
//last_flag: tx_last of the byte being sent, so the end of that byte can end the frame.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        had_frame       <= 1'b0;
    else if(start)
        had_frame       <= 1'b1;

assign guard_due = (guard != 8'd0) & (~had_frame | (tx_dev != touch_frame));

always_ff @(posedge clk)
    begin
    if(start)
        touch_frame     <= tx_dev;

    if((state == IDLE) & tx_valid & guard_due)
        guard_left      <= {guard, 6'd0} - 14'd1;
    else if((state == WAIT) & (guard_left != 14'd0))
        guard_left      <= guard_left - 14'd1;

    if(tx_ready)
        last_flag       <= tx_last;
    end


//--------------------------------------------------------------------------------------------------------------------
//  2. Taking a byte and the state machine
//--------------------------------------------------------------------------------------------------------------------

//Taking a byte: tx_ready is high for one clock when a byte is taken from tx_byte, which happens when tx_valid is
//high and the master is idle with no guard due, or at the end of the guard, or in a pause between bytes, or at the
//end of a byte that is not the frame's last. start is tx_ready for the first byte of a frame.
assign tx_ready     = tx_valid
                    & (((state == IDLE) & ~guard_due)
                    | ((state == WAIT) & (guard_left == 14'd0)) | (state == PAUSE)
                    | (byte_done & ~last_flag));

assign start        = tx_ready & ((state == IDLE) | (state == WAIT));


//State machine: IDLE between frames; WAIT during the guard; SEND while a byte is on the bus; PAUSE between bytes of
//a frame when the next byte is not offered in time, with sck low and the select held; TAIL for the half period of
//sck low after the last byte's last falling edge; HOLD for the half period after the selects rise. spi_busy is
//high in every state but IDLE.
//One frame of one byte after a guard, drawn with H = 4, H being the half period of sck in clocks, and two
//characters per clock; the guard and the bits between bit 6 and bit 0 are drawn short. select is the frame's chip
//select, and capture marks the clocks in which rx_byte takes miso_s in a touch frame:
//                    v request   v take
//    state     IDLE    WAIT        SEND                                                 TAIL    HOLD    IDLE
//    spi_busy  ________---------------------------------------------------------------------------------________
//    select    --------------------_____________________________________________________________----------------
//    sck       ____________________________--------________-------- ... ________--------________________________
//    mosi      ____________________|bit 7          |bit 6           ... |bit 0                  |_______________
//    capture                                     ^               ^                    ^
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        state       <= IDLE;
    else
        state       <= next_state;

always_comb
    case(state)
    IDLE:   if(tx_valid & guard_due)        next_state = WAIT;
            else if(tx_ready)               next_state = SEND;
            else                            next_state = IDLE;

    WAIT:   if(tx_ready)                    next_state = SEND;
            else                            next_state = WAIT;

    SEND:   if(tx_ready)                    next_state = SEND;
            else if(byte_done & last_flag)  next_state = TAIL;
            else if(byte_done)              next_state = PAUSE;
            else                            next_state = SEND;

    PAUSE:  if(tx_ready)                    next_state = SEND;
            else                            next_state = PAUSE;

    TAIL:   if(half_done)                   next_state = HOLD;
            else                            next_state = TAIL;

    HOLD:   if(half_done)                   next_state = IDLE;
            else                            next_state = HOLD;

    default:                                next_state = IDLE;
    endcase

assign spi_busy     = (state != IDLE);


//--------------------------------------------------------------------------------------------------------------------
//  3. The outputs to the bus
//--------------------------------------------------------------------------------------------------------------------

//Half period counter: a bit is one half period of sck low then one of sck high, each H clocks, H being the SCKDIV
//field of the frame's device plus 1. h_field is that field, half_count counts the clocks of the current half period
//and half_done is 1 on its last clock. sck toggles at the end of each half period while a byte is on the bus;
//sck_fall is 1 in the last clock of each high half period (sck falls at the end of that clock), and byte_done on
//the sck_fall that ends the eighth bit.
assign h_field      = touch_frame ? sckdiv[7:4] : sckdiv[3:0];

always_ff @(posedge clk)
    if(tx_ready | half_done)
        half_count  <= 4'd0;
    else
        half_count  <= half_count + 4'd1;

assign half_done    = (half_count == h_field);

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        sck         <= 1'b0;
    else if((state == SEND) & half_done)
        sck         <= ~sck;

assign sck_fall = (state == SEND) & sck & half_done;
assign byte_done = sck_fall & (bits_left == 3'd0);


//Output shift register: bits_left counts the bits of the byte still to send after the one on mosi, and out_bits
//holds them. mosi takes bit 7 of tx_byte when the byte is taken and the next bit at each sck_fall, and returns to 0
//when the selects rise.
always_ff @(posedge clk)
    if(tx_ready)
        bits_left   <= 3'd7;
    else if(sck_fall)
        bits_left   <= bits_left - 3'd1;

always_ff @(posedge clk)
    if(tx_ready)
        out_bits    <= tx_byte[6:0];
    else if(sck_fall)
        out_bits    <= {out_bits[5:0], 1'b0};

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        mosi        <= 1'b0;
    else
        if(tx_ready)
            mosi        <= tx_byte[7];
        else if(sck_fall & (bits_left != 3'd0))
            mosi        <= out_bits[6];
        else if(sel_rise)
            mosi        <= 1'b0;


//Chip selects and dc: the frame's device is selected when its first byte is taken, cs_lcd_n low for the screen and
//cs_tp_n low for the touch controller. dc takes tx_dc with each byte. sel_rise is 1 at the end of TAIL, one half
//period after the last falling edge; then both selects rise and dc returns to 1.
always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        dc          <= 1'b1;
    else
        if(tx_ready)
            dc          <= tx_dc;
        else if(sel_rise)
            dc          <= 1'b1;

assign sel_rise = (state == TAIL) & half_done;

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        begin
        cs_lcd_n    <= 1'b1;
        cs_tp_n     <= 1'b1;
        end
    else
        if(start)
            begin
            cs_lcd_n    <= tx_dev;
            cs_tp_n     <= ~tx_dev;
            end
        else if(sel_rise)
            begin
            cs_lcd_n    <= 1'b1;
            cs_tp_n     <= 1'b1;
            end


//--------------------------------------------------------------------------------------------------------------------
//  4. Receiving the touch controller's bytes
//--------------------------------------------------------------------------------------------------------------------

//Receive shift register: during a touch frame rx_byte takes miso_s in the last clock of each high half period of
//sck, the clock before sck falls. rx_valid is 1 for the clock after the eighth capture, and rx_byte holds the byte
//until the next capture.
always_ff @(posedge clk)
    if(sck_fall & touch_frame)
        rx_byte     <= {rx_byte[6:0], miso_s};

always_ff @(posedge clk or negedge rst_n)
    if(~rst_n)
        rx_valid    <= 1'b0;
    else
        if(byte_done & touch_frame)
            rx_valid    <= 1'b1;
        else
            rx_valid    <= 1'b0;

endmodule
