// The delay cell that the teach ring instantiates, as a plain wire for the RTL simulation. The gate-level simulation
// reads the PDK's own model of the cell, so this file is not among the chip's sources in info.yaml.
module sky130_fd_sc_hd__dlygate4sd3_1 (input A, output X);
    assign X = A;
endmodule
