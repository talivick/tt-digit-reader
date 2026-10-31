# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Thomas Livick
#
# test.py : the test the flow runs on the top, on the RTL and again on the gate-level netlist
#
# Description
#   The test bench tb.v holds the top with its default parameters, which build the matrix unit alone.
#   This test speaks to it as the host does: one byte per four-phase handshake on ui_in, in_valid on
#   uio_in bit 7, in_ready on uio_out bit 6, and uo_out read while the byte is a response. It checks
#   the levels of the three output ports in reset and after it, then ID, then STATUS twice, so the
#   handshake, the framing, the form code and the reset-seen bit are each seen once. Everything else
#   the chip does is covered by the tests that stay out of this repository.
#
# Operation
#   The clock runs at 25 MHz, a 40 ns period. Inputs change on the falling edge of clk and outputs are
#   read there, half a period after the rising edge that set them, so every value is settled when it is
#   read, on the RTL and on the netlist with its unit delays. The chip takes no byte until in_valid has
#   been low after the reset release, so in_valid is 0 through the reset and for the clocks after it.
#   A transfer is the command byte, then one 0x00 byte per response byte; the byte uo_out shows during
#   the command byte's handshake is the 7-segment pattern, and during each response handshake it is the
#   response. A handshake that does not complete within HANDSHAKE_CLKS clocks fails the test.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

IN_VALID        = 0x80    # uio_in bit 7: a byte is offered on ui_in
IN_READY        = 0x40    # uio_out bit 6: the chip has taken the byte and shows its answer
SEG_RESET       = 0x40    # uo_out in reset and between responses before any pattern is written: segment g alone
UIO_OUT_RESET   = 0x1C    # uio_out in reset: dc and both chip selects 1, sck, mosi and in_ready 0
UIO_OE          = 0x5F    # uio bits 0 to 4 and 6 are outputs, bits 5 and 7 inputs
ID              = 0x01    # the command: two response bytes, 0x44 and the form byte
STATUS          = 0x02    # the command: three response bytes S0, S1, S2
ID_BYTE0        = 0x44    # ID's first byte
ID_FALLBACK     = 0x02    # ID's second byte with the matrix unit alone: no teach mode, no attract mode, form code 2
RST_SEEN        = 0x80    # S1 bit 7: set by a reset, cleared when STATUS supplies S1
HANDSHAKE_CLKS  = 200     # clocks one handshake may take before the test fails


async def handshake(dut, byte):
    """One byte to the chip, as the host sends it, returning the byte uo_out shows while in_ready is 1.

    ui_in takes the byte one clock before in_valid rises, so the chip never samples a changing byte.
    in_valid stays high until in_ready is 1, then falls, and the next byte waits until in_ready is 0."""
    await FallingEdge(dut.clk)
    dut.ui_in.value = byte
    await FallingEdge(dut.clk)
    dut.uio_in.value = IN_VALID
    for _ in range(HANDSHAKE_CLKS):
        await FallingEdge(dut.clk)
        if int(dut.uio_out.value) & IN_READY:
            break
    else:
        raise AssertionError(f"in_ready did not rise within {HANDSHAKE_CLKS} clocks for the byte 0x{byte:02X}")
    shown = int(dut.uo_out.value)
    dut.uio_in.value = 0
    for _ in range(HANDSHAKE_CLKS):
        await FallingEdge(dut.clk)
        if not int(dut.uio_out.value) & IN_READY:
            break
    else:
        raise AssertionError(f"in_ready did not fall within {HANDSHAKE_CLKS} clocks after the byte 0x{byte:02X}")
    return shown


async def transfer(dut, command, response_count):
    """A command with no argument bytes: the command byte, then one 0x00 byte per response byte.

    Returns the response bytes. The byte shown during the command byte's handshake must be the 7-segment
    pattern, since no response is on uo_out then."""
    shown = await handshake(dut, command)
    assert shown == SEG_RESET, f"uo_out showed 0x{shown:02X} during the command byte 0x{command:02X}; expected the pattern 0x{SEG_RESET:02X}"
    return [await handshake(dut, 0x00) for _ in range(response_count)]


def check_pins(dut, when):
    """The three output ports at their reset levels."""
    uo_out = int(dut.uo_out.value)
    uio_out = int(dut.uio_out.value)
    uio_oe = int(dut.uio_oe.value)
    assert uo_out == SEG_RESET, f"uo_out is 0x{uo_out:02X} {when}; expected 0x{SEG_RESET:02X}"
    assert uio_out == UIO_OUT_RESET, f"uio_out is 0x{uio_out:02X} {when}; expected 0x{UIO_OUT_RESET:02X}"
    assert uio_oe == UIO_OE, f"uio_oe is 0x{uio_oe:02X} {when}; expected 0x{UIO_OE:02X}"


@cocotb.test()
async def test_top(dut):
    dut._log.info("The clock, 40 ns")
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset: rst_n low for ten clocks with in_valid low, released on a falling edge. The reset
    # synchronizer frees the chip's flops two or three clocks later, and in_valid's synchronizer needs
    # two clocks of a low pin after that before a byte may be offered, so the first handshake waits.
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    await FallingEdge(dut.clk)
    check_pins(dut, "in reset")
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 6)
    await FallingEdge(dut.clk)
    check_pins(dut, "after the reset release")

    # ID: 0x44, then the form byte of the build with the matrix unit alone.
    dut._log.info("ID")
    got = await transfer(dut, ID, 2)
    assert got == [ID_BYTE0, ID_FALLBACK], f"ID returned {[hex(b) for b in got]}; expected [0x44, 0x02]"

    # STATUS twice: S1 shows the reset the first time and clears when that S1 is supplied; S0 and S2
    # are 0 with nothing running, no result waiting and no winner.
    dut._log.info("STATUS")
    got = await transfer(dut, STATUS, 3)
    assert got == [0x00, RST_SEEN, 0x00], f"the first STATUS returned {[hex(b) for b in got]}; expected [0x0, 0x80, 0x0]"
    got = await transfer(dut, STATUS, 3)
    assert got == [0x00, 0x00, 0x00], f"the second STATUS returned {[hex(b) for b in got]}; expected [0x0, 0x0, 0x0]"
    dut._log.info("Done: the pins, ID and STATUS as expected")
