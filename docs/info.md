<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A 2 by 2 INT8 systolic matrix unit and a digit reader, driven by a host through a byte handshake; the chip draws on a touch LCD over SPI.

## How to test

Send commands as bytes on ui_in with the in_valid and in_ready handshake; read the winner on the 7-segment display.

## External hardware

List external hardware used in your project (e.g. PMOD, LED display, etc), if any
