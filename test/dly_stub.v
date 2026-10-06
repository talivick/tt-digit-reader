// RTL simulation stand-in for the delay cell the teach ring instantiates (chip plan 6.16).
// The gate-level build reads the PDK's own model; this file is never listed in info.yaml.
module sky130_fd_sc_hd__dlygate4sd3_1 (input A, output X);
	assign X = A;
endmodule
