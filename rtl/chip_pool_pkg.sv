//============================================================================
//
//  chip_pool_pkg — bus types for a multi-board core's shared CPU / sound chip pool (canonical; same file in every core)
//  Copyright (C) 2026 Rodimus
//
//  Only one board runs at a time, so the CPUs and sound chips are instanced once in rtl/konami82_board.sv
//  and the active board drives them through these buses (selected by variant). *_i = board to chip,
//  *_o = chip to every board. Reset is the core reset.
//
//============================================================================

package chip_pool_pkg;

// Z80 (T80s, Mode 0, T2Write 1, IOWait 1; WAIT_n / BUSRQ_n inactive)
typedef struct packed {
    logic        ce;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80_o_t;

// MC6809E (mc6809is; HALT / DMABREQ inactive)
typedef struct packed {
    logic        fall_e;
    logic        fall_q;
    logic        irq_n;
    logic        firq_n;
    logic        nmi_n;
    logic  [7:0] d;
} m6809_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        rw;
    logic        lic;
} m6809_o_t;

// AY-3-8910 (jt49_bus, sel = 1)
typedef struct packed {
    logic        ce;
    logic        bdir;
    logic        bc1;
    logic  [7:0] din;
    logic  [7:0] ioa_in;
    logic  [7:0] iob_in;
} ay_i_t;

typedef struct packed {
    logic  [7:0] dout;
    logic  [7:0] a;
    logic  [7:0] b;
    logic  [7:0] c;
    logic  [7:0] iob_out;
} ay_o_t;

// Z80 (T80s, Mode 0, T2Write 1, IOWait 1; WAIT_n / BUSRQ_n inactive; outputs on z80_o_t). RESET_n is on the bus:
// ninjakd2's main CPU holds its sound CPU and both YM2203 in reset (control +01 bit 4)
typedef struct packed {
    logic        reset_n;
    logic        ce;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80r_i_t;

// YM2203 (jt03, YM2203_LUMPED 0). rst is on the bus: ninjakd2's sound reset. The SSG is AY-3-8910 register- and
// port-compatible, so the pair can also stand in for two AY8910s
typedef struct packed {
    logic        rst;
    logic        ce;
    logic        cs_n;
    logic        wr_n;
    logic        addr;
    logic  [7:0] din;
    logic  [7:0] ioa_in;
    logic  [7:0] iob_in;
} ym2203_i_t;

typedef struct packed {
    logic  [7:0] dout;
    logic        irq_n;
    logic  [7:0] ioa_out;
    logic  [7:0] iob_out;
    logic        ioa_oe;                // port is an output (SSG register 7 bit 6 / 7)
    logic        iob_oe;
    logic  [9:0] psg_snd;               // SSG only, unsigned
    logic [15:0] snd;                   // FM + SSG, signed
} ym2203_o_t;

// Dual-port RAM block (dpram_dc, true dual port, both ports read/write). One bus shape for every pooled RAM:
// each instance uses the low widthad address bits and its width_a data bits; be is used by the 32-bit ones only
typedef struct packed {
    logic [13:0] a_addr;
    logic        a_we;
    logic  [3:0] a_be;
    logic [31:0] a_din;
    logic [13:0] b_addr;
    logic        b_we;
    logic  [3:0] b_be;
    logic [31:0] b_din;
} dpram_i_t;

typedef struct packed {
    logic [31:0] a_q;
    logic [31:0] b_q;
} dpram_o_t;

endpackage
