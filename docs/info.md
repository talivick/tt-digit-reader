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
in_ready is high.

Send ID. The response is 0x44, then one byte whose low bits give the form.

Run the matrix unit: write MX_M, the row count, and the scale, shift, biases and four weights with REG_WR
(the address byte, then the data byte); send MX_START; send MX_ROW with two activation bytes per row, keeping
at most three rows written and not yet read, two before MX_START; read each result with MX_READ, which
returns a valid flag and two INT8 result bytes, and read again when the flag is 0. STATUS returns the three
status bytes: busy, done, the result flag and the FIFO count in the first, the error flags in the second,
the digit reader's answer in the third.

## External hardware

A DFRobot DFR0665 2.8 inch touch LCD (ILI9341 and XPT2046 on one SPI bus) on the bidirectional pins, and a
host on the Tiny Tapeout demo board. The matrix unit alone needs no external hardware.
