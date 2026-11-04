<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A tiny inference and learning coprocessor. A host microcontroller drives it one byte at a time over an
eight-bit bus with a two-wire handshake, and the chip does the arithmetic a small classifier needs.

Inside are four parts. An INT8 2 by 2 systolic matrix unit multiplies rows of two activations by a held 2 by 2
weight matrix and requantizes each result to INT8 with a bias, a scale, a rounding shift and ReLU. A digit
reader stores a 64-pixel 2-bit image, walks it through the matrix unit tile by tile against 640 weights, keeps
ten 12-bit accumulators and reports the best class. A teach block learns a two-class rule in a ring of 65
6-bit weights from examples the host labels, and scores an image against it. A display block drives a touch
LCD over SPI: it clears the screen, draws the image, draws ten bars, writes digits and reads the touch panel.

The host sees registers, commands and three status bytes, all listed in src/address_map.sv. The matrix unit
alone makes the chip a small accelerator; with the digit reader and the teach block it classifies and learns
from sixty-four inputs of any kind, so the same silicon reads a handwritten digit from the touch panel or an
eight-band sound spectrogram from a microphone on the host.

This submission is the full chip: the matrix unit, the digit reader, the teach block and the display, with the
command decoder, the handshake and the 7-segment output. The ID command reports the form.

## How to test

Hold rst_n low, then release it. The 7-segment display shows segment g alone as a sign of life.

Send a byte: put it on ui_in, raise in_valid (uio[7]) and hold both until in_ready (uio[6]) rises, then drop
in_valid and wait for in_ready to fall. A command is one byte, followed by its argument bytes the same way.
A response byte is read with the same handshake while ui_in holds 0x00: the byte appears on uo_out while
in_ready is high. The command codes, the register addresses and the status bits are in src/address_map.sv.

Send ID. The response is 0x44, then 0x81: bit 7 set for teach mode, bit 6 clear for the attract mode that is
not built, and form code 1 in the low six bits, the digit reader with the display.

Run the matrix unit: write MX_M, the row count, and the scale, shift, biases and four weights with REG_WR
(the address byte, then the data byte); send MX_START; send MX_ROW with two activation bytes per row, keeping
at most three rows written and not yet read, two before MX_START; read each result with MX_READ, which
returns a valid flag and two INT8 result bytes, and read again when the flag is 0. STATUS returns the three
status bytes: busy, done, the result flag and the FIFO count in the first, the error flags in the second,
the digit reader's answer in the third.

Read a digit: send DIG_START with ten INT8 biases, class 0 first; IMG with sixteen bytes, the 8 by 8 image at
2 bits per pixel, byte k holding pixels 4k to 4k + 3 with pixel 4k + j in bits 2j + 1 and 2j, pixel p on row
p div 8 and column p mod 8; then 160 TILE commands, each the four 4-bit weights of one 2 by 2 tile as {w01, w00}
then {w11, w10}, tile t covering pixels 2i and 2i + 1 for classes 2j and 2j + 1 with i = t div 5 and j = t mod 5;
then DIG_ARGMAX, which picks the class with the largest accumulator and puts it on the 7-segment display. DIG_READ returns S2, with WIN_VALID in bit 7 and the winner in
bits 3 to 0, then the ten accumulators, high byte first. The 640 weights and the ten biases are the host's, from
a model trained on 8 by 8 digits; the chip holds no weights of its own.

Teach a two-class rule: TCH_CLEAR zeroes the weights and the bias. For each example send IMG, then TCH_LEARN with
the label in bit 0 (0 for the first symbol, 1 for the second); the chip scores the image and moves the weights
toward the label when the score is within the margin. TCH_READ returns the score of the last image, high byte
first, then LEARNED (1 when the weights changed) and the bias; repeat the examples until LEARNED is 0 for every
one. TCH_SCORE scores an image without learning: a positive score reads as the first symbol, a negative one as
the second. The step is REG_WR register 0x1E (reset 1) and the margin is registers 0x1F and 0x20 (reset 124).
TCH_MAP draws the weights on the LCD.

Drive the LCD: PT_CMD and PT_DAT send one byte to the ILI9341 with dc 0 and 1, so the panel's startup is PT_CMD
0x01 (software reset) and PT_CMD 0x11 (sleep out), each followed by a 120 ms wait, then PT_CMD 0x3A with PT_DAT
0x55 (16-bit pixels), PT_CMD 0x36 with PT_DAT 0x28 (320 by 240, landscape) and PT_CMD 0x29 (display on).
DRAW_RECT takes X, Y, W, H as two bytes each (bit 8 in the first byte's bit 0, bits 7 to 0 in the second) and a
16-bit RGB565 color, high byte first; DRAW_IMG draws the stored image as blocks, DRAW_BARS the ten accumulators,
DRAW_DIGIT one digit and TCH_MAP the teach weights, with their byte layouts in src/disp_seq.sv, part 1. S0 bit 0,
DISP_BUSY, is 1 while a drawing goes out; a 320 by 240 clear takes 197 ms at the reset SPI dividers. TP_READ with
an XPT2046 control byte (0xD0 for X, 0x90 for Y, 0xB0 for Z1, 0xC0 for Z2) returns the 12-bit conversion in two
bytes, the high four bits first.

test/test.py is the test the flow runs on the RTL and again on the gate-level netlist: the pin levels through
reset, then ID, then STATUS twice. The block tests stay out of this repository.

## External hardware

A DFRobot DFR0665 2.8 inch touch LCD (ILI9341 and XPT2046 on one SPI bus) on the bidirectional pins, and a
host on the Tiny Tapeout demo board. The matrix unit alone needs no external hardware.
