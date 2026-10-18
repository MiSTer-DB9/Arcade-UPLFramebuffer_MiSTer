//============================================================================
//
//  nova2001_board.sv — UPL "orthogonal palette" boards, MAME nova2001.cpp (variant):
//    0 UPL-83005 Nova 2001: Z80 @ 3 MHz, 2x AY-3-8910 @ 2 MHz, fg + bg tilemaps, palette PROM
//    1 UPL-85003 Penguin-Kun Wars: as Nova, AYs @ 1.5 MHz read all inputs, bg tilemap only
//    2 UPL-84003 Ninjakun: 2x Z80 on one bus, AYs @ 3 MHz, palette RAM, scrolled bg window for the CPUs
//    3 UPL-85004 Raiders5: 2x Z80 on one bus, AYs @ 1.5 MHz, palette RAM, Penguin-Kun Wars sprite format
//  Sprites go into a single-buffered 256x256x4 framebuffer. Nova 2001 from its schematic (Claude/upl_schematic_facts.md)
//  and MAME; the others have no schematic, so MAME plus the Nova 2001 timing.
//  CPUs, AYs (the shared YM2203 pair's SSGs) and RAMs are the shared pool in rtl/UPLFramebuffer.sv.
//  Copyright (C) 2026 Rodimus
//
//============================================================================

module nova2001_board
(
    input                clk,            // 60 MHz fabric
    input          [3:0] pix_ph,         // top's mod-10 phase; 0 = 6 MHz pixel enable
    input                reset,
    input                pause,
    input          [1:0] variant,        // 0 Nova 2001, 1 Penguin-Kun Wars, 2 Ninjakun, 3 Raiders5

    // ---- controls, ninjakd2 port order from the wrapper (active low)
    input          [7:0] keycoin,        // 0 start1, 1 start2, 3 service, 6 coin1
    input          [7:0] pad1,           // 0 right, 1 left, 2 down, 3 up, 4 attack, 5 jump
    input          [7:0] pad2,
    input          [7:0] dsw1,
    input          [7:0] dsw2,

    input                crt_flip,

    // ---- program ROM 0000-7FFF (rom_main_fixed), second ROM (rom_snd_lo: pkunwar E000, ninjakun sub 0000),
    //      gfx (rom_main_bank, 1-clock read: gfx1 at 0, gfx2 at 0x8000)
    output        [15:0] maincpu_addr,
    input          [7:0] maincpu_data,
    output        [15:0] aux_addr,
    input          [7:0] aux_data,
    output        [17:0] gfx_addr,
    input          [7:0] gfx_data,

    // ---- MRA download: the palette PROM is index 0 at 0x10000 (Nova 2001) or index 11 (Penguin-Kun Wars)
    input                ioctl_wr,
    input          [7:0] ioctl_index,
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,

    // ---- video / audio
    output reg           HSync, VSync,
    output reg           HBlank, VBlank,
    output reg     [7:0] R, G, B,
    output signed [15:0] sound,

    // ---- shared chips (rtl/UPLFramebuffer.sv)
    output chip_pool_pkg::z80r_i_t         z80_i,     // CPU 1
    input  chip_pool_pkg::z80_o_t          z80_o,
    output chip_pool_pkg::z80r_i_t         z80b_i,    // CPU 2 (Ninjakun / Raiders5; held in reset otherwise)
    input  chip_pool_pkg::z80_o_t          z80b_o,
    output chip_pool_pkg::ym2203_i_t [1:0] ym_i,      // 0 = ay1, 1 = ay2
    input  chip_pool_pkg::ym2203_o_t [1:0] ym_o,
    output chip_pool_pkg::dpram_i_t        fg_i,      // ram2k_0: fg VRAM
    input  chip_pool_pkg::dpram_o_t        fg_o,
    output chip_pool_pkg::dpram_i_t        bg_i,      // ram8k_0: bg VRAM
    input  chip_pool_pkg::dpram_o_t        bg_o,
    output chip_pool_pkg::dpram_i_t        spr_i,     // ram8k_1: sprite RAM
    input  chip_pool_pkg::dpram_o_t        spr_o,
    output chip_pool_pkg::dpram_i_t        sh_i,      // ram8k_2: shared CPU RAM 0x000, palette RAM 0x800 (Ninjakun / Raiders5)
    input  chip_pool_pkg::dpram_o_t        sh_o,
    output chip_pool_pkg::dpram_i_t        work_i,    // ram8k_3: work RAM (Nova / Penguin-Kun Wars)
    input  chip_pool_pkg::dpram_o_t        work_o,
    output chip_pool_pkg::dpram_i_t        fb_i,      // ram_fb: sprite framebuffer, one pixel per byte lane
    input  chip_pool_pkg::dpram_o_t        fb_o
);

wire v_nova = (variant == 2'd0);
wire pkw    = (variant == 2'd1);
wire v_nk   = (variant == 2'd2);
wire v_r5   = (variant == 2'd3);
wire dual   = v_nk | v_r5;                   // two CPUs, palette RAM
wire pk_spr = pkw | v_r5;                    // Penguin-Kun Wars sprite record

//------------------------------------------------------- Clocks / timing ------------------------------------------------------//

wire cen_pix = (pix_ph == 4'd0);

// 0H: CPU 1 runs on every other pixel clock (12 MHz / 4), CPU 2 on the others.
reg h0 = 1'b0;
always_ff @(posedge clk) if (cen_pix) h0 <= ~h0;
wire cen_cpu  = cen_pix &  h0;
wire cen_cpu2 = cen_pix & ~h0 & dual;

// AY clock: Nova 2 MHz, Ninjakun 3 MHz, Penguin-Kun Wars / Raiders5 1.5 MHz (MAME). jt03's SSG runs at cen / 2 with
// the reset prescaler (verilator/ssg_clk), so cen = 4 / 6 / 3 MHz = 60 / 15, 10, 20.
wire [4:0] ay_div = v_nova ? 5'd14 : v_nk ? 5'd9 : 5'd19;
reg  [4:0] div_ay = 5'd0;
always_ff @(posedge clk) div_ay <= (div_ay >= ay_div) ? 5'd0 : div_ay + 5'd1;
wire cen_ay = (div_ay == 5'd0);

// H: x = 0-255 active, 256-383 blank, HSYNC 320-351 (schematic P = 192-223). HTOTAL 384 #inferred.
// V: the 9-bit counter of the schematic, V_LOAD-511. V[7:0] 32-223 active; bit 8 low = VSYNC lines.
// It steps at HSYNC start. VTOTAL = 512 - V_LOAD = 264 #inferred (the load is not readable; 260 is the other option).
localparam [8:0] V_LOAD = 9'd248;

reg [8:0] hc = 9'd0;
reg [8:0] v9 = 9'd256;

always_ff @(posedge clk) begin
    if (cen_pix) begin
        hc <= (hc == 9'd383) ? 9'd0 : hc + 9'd1;
        if (hc == 9'd319) v9 <= (v9 == 9'd511) ? V_LOAD : v9 + 9'd1;
    end
end

wire [7:0] v8      = v9[7:0];
wire       vsync_l = ~v9[8];
wire       vblank  = ~v9[8] | (v8 < 8'd32) | (v8 >= 8'd224);
wire       hblank  = hc[8];
wire       hsync   = (hc >= 9'd320) && (hc < 9'd352);
wire       disp    = ~vblank & ~hblank;

//------------------------------------------------------- CPU bus --------------------------------------------------------------//

// The two Z80s share one bus. Each owns it for the 10 clocks that end with its own clock enable (CPU 1 while h0 = 1,
// CPU 2 while h0 = 0), so a BRAM read addressed in the owner's window is valid when it samples DI and every write lands
// on the owner's cen. Single-CPU boards keep CPU 1 on the bus.
wire who2 = dual & ~h0;

wire [15:0] A        = who2 ? z80b_o.a    : z80_o.a;
wire  [7:0] cpu_dout = who2 ? z80b_o.dout : z80_o.dout;
wire        mreq     = who2 ? (~z80b_o.mreq_n & z80b_o.rfsh_n) : (~z80_o.mreq_n & z80_o.rfsh_n);
wire        rd       = who2 ? ~z80b_o.rd_n   : ~z80_o.rd_n;
wire        wr       = who2 ? ~z80b_o.wr_n   : ~z80_o.wr_n;
wire        iorq     = who2 ? ~z80b_o.iorq_n : ~z80_o.iorq_n;
wire        int_ack  = who2 ? (~z80b_o.m1_n & ~z80b_o.iorq_n) : (~z80_o.m1_n & ~z80_o.iorq_n);

wire cen_bus = dual ? cen_pix : cen_cpu;     // the owner's clock enable
wire wr_cen  = cen_bus & wr;                 // RAMs take every cen of the write (same data); latches are levels

// Nova 2001 (schematic): 0000 ROM, 8000 watchdog clear, A000 fg, A800 bg, B000 sprites, B800 flip,
// C000-DFFF I/O (A[3:0] decoded, mirrored /16), E000-FFFF work RAM (2K mirrored).
// Penguin-Kun Wars (MAME pkunwar_map): 0000 ROM, 8000 sprites, 8800 bg, A000-A003 AYs, C000 work RAM, E000 ROM,
// I/O port 00 flip.
// Ninjakun (both CPUs): 0000-1FFF ROM (CPU 2: its own), 2000-7FFF main ROM, 8000-8003 AYs, A000-A003 inputs / A002 latch /
// A003 flip, C000 fg, C800 bg (scroll window), D000 sprites, D800-D9FF palette, E000-E7FF shared (CPU 2 halves swapped).
// Raiders5: CPU 1 0000 ROM, 8000 sprites, 8800 fg, 9000 bg (scroll window), A000-A002 scroll x / y / flip, C000-C003 AYs,
// D000-D1FF palette, E000 shared; CPU 2 0000-3FFF = main ROM 4000-7FFF, 8000-8003 AYs, A000 shared, E000-E002 as A000-A002.
wire r5c1 = v_r5 & ~who2;
wire r5c2 = v_r5 &  who2;

wire cs_rom   = mreq & (v_nk ? (~A[15] & (~who2 | (A[14:13] != 2'b00))) : r5c2 ? (A[15:14] == 2'b00) : ~A[15]);
wire cs_aux   = mreq & ((pkw & (A[15:13] == 3'b111)) | (v_nk & who2 & (A[15:13] == 3'b000)));
wire cs_stnpd = mreq & v_nova & (A[15:13] == 3'b100);
wire cs_fg    = mreq & ((v_nova & (A[15:11] == 5'b10100)) | (v_nk & (A[15:11] == 5'b11000)) | (r5c1 & (A[15:11] == 5'b10001)));
wire cs_bg    = mreq & ((v_nova & (A[15:11] == 5'b10101)) | (pkw  & (A[15:11] == 5'b10001)) |
                        (v_nk   & (A[15:11] == 5'b11001)) | (r5c1 & (A[15:11] == 5'b10010)));
wire cs_spr   = mreq & ((v_nova & (A[15:11] == 5'b10110)) | (pkw  & (A[15:11] == 5'b10000)) |
                        (v_nk   & (A[15:11] == 5'b11010)) | (r5c1 & (A[15:11] == 5'b10000)));
wire cs_flip  = mreq & v_nova & (A[15:11] == 5'b10111);
wire cs_io    = mreq & v_nova & (A[15:13] == 3'b110);
wire cs_pay   = mreq & ((pkw & (A[15:2] == 14'h2800)) | (v_nk & (A[15:2] == 14'h2000)) |
                        (r5c1 & (A[15:2] == 14'h3000)) | (r5c2 & (A[15:2] == 14'h2000)));
wire cs_work  = mreq & ((pkw & (A[15:11] == 5'b11000)) | (v_nova & (A[15:13] == 3'b111)));
wire cs_share = mreq & (((v_nk | r5c1) & (A[15:11] == 5'b11100)) | (r5c2 & (A[15:11] == 5'b10100)));
wire cs_pal   = mreq & ((v_nk & (A[15:9] == 7'b1101100)) | (r5c1 & (A[15:9] == 7'b1101000)));
wire cs_nkio  = mreq & v_nk & (A[15:2] == 14'h2800);                                   // A000-A003
wire cs_r5reg = mreq & ((r5c1 & (A[15:2] == 14'h2800)) | (r5c2 & (A[15:2] == 14'h3800))); // A000 / E000 - +2

// AY selects. Nova: C000/C001 data, C002/C003 address, chip = A0. The others: +0/+2 address, +1/+3 data, chip = A1.
wire io_ay_d  = (cs_io & (A[2:1] == 2'b00)) | (cs_pay &  A[0]);
wire io_ay_a  = (cs_io & (A[2:1] == 2'b01)) | (cs_pay & ~A[0]);
wire ay_chip  = v_nova ? A[0] : A[1];
wire io_ack   = cs_io & (A[2:1] == 2'b10);                   // C004/C005: IRQ acknowledge, read or write
wire io_in    = cs_io & (A[2:1] == 2'b11);                   // C006 IN0, C007 IN1, C00E IN2

// 2732 at 6000 (Nova): A12 is not connected, 7000-7FFF mirrors 6000-6FFF. Raiders5 CPU 2 runs from main ROM 4000-7FFF.
assign maincpu_addr = r5c2 ? {2'b01, A[13:0]} : {1'b0, A[14:13], A[12] & (~v_nova | ~(A[14] & A[13])), A[11:0]};
assign aux_addr     = {3'd0, A[12:0]};

// Flip. Nova B800: D0 = 0 -> flipped. pkunwar port 00, Raiders5 A002 / E002, Ninjakun CPU 1 A003: D0 = 1.
// Ninjakun CPU 2 A003: D0 = 0 (MAME nova2001_flipscreen_w).
reg flip = 1'b0;
always_ff @(posedge clk) begin
    if (wr_cen & cs_flip)                                    flip <= ~cpu_dout[0];
    if (wr_cen & pkw & iorq & ~int_ack & (A[7:0] == 8'h00))  flip <=  cpu_dout[0];
    if (wr_cen & cs_r5reg & (A[1:0] == 2'd2))                flip <=  cpu_dout[0];
    if (wr_cen & cs_nkio & (A[1:0] == 2'd3))                 flip <=  cpu_dout[0] ^ who2;
end
wire flip_screen = flip ^ crt_flip;

// Ninjakun A002 CPU-to-CPU latch (MAME ninjakun_cpu1/2_io_A002_w), read back as IN2 bits 2-3.
reg [1:0] nk_ctrl = 2'd0;
always_ff @(posedge clk) begin
    if (reset) nk_ctrl <= 2'd0;
    else if (wr_cen & cs_nkio & (A[1:0] == 2'd2)) begin
        if (~who2) begin
            if (cpu_dout == 8'h80) nk_ctrl[0] <= 1'b1;
            if (cpu_dout == 8'h40) nk_ctrl[1] <= 1'b0;
        end else begin
            if (cpu_dout == 8'h40) nk_ctrl[1] <= 1'b1;
            if (cpu_dout == 8'h80) nk_ctrl[0] <= 1'b0;
        end
    end
end

// Raiders5 scroll registers (A000 / A001, CPU 2 E000 / E001).
reg [7:0] r5_sx = 8'd0, r5_sy = 8'd0;
always_ff @(posedge clk) begin
    if (wr_cen & cs_r5reg & (A[1:0] == 2'd0)) r5_sx <= cpu_dout;
    if (wr_cen & cs_r5reg & (A[1:0] == 2'd1)) r5_sy <= cpu_dout;
end

// IRQ set on VBLANK rising (line 224). Nova: 4F, cleared only by touching C004/C005 (the Z80 acknowledge does not).
// The others: MAME's irq0_line_hold, cleared by the acknowledge.
reg vbl_d = 1'b0;
reg irq   = 1'b0;
always_ff @(posedge clk) begin
    vbl_d <= vblank;
    if (reset)                                         irq <= 1'b0;
    else if (cen_cpu & io_ack & (rd | wr))             irq <= 1'b0;
    else if (cen_cpu & ~v_nova & ~who2 & int_ack)      irq <= 1'b0;
    else if (vblank & ~vbl_d)                          irq <= 1'b1;
end

// CPU 2 IRQ: MAME periodic 4 x 60 Hz ("?"). With MAME's exact 60 Hz frame that is frame-locked, and measured in MAME
// it lands on VBLANK start (Ninjakun's scroll write is 1.5 lines after it, CPU 1's vblank work 7.5): lines 224, 32,
// 96, 160. A free-running or differently phased IRQ lets Ninjakun set the bg scroll in the middle of CPU 1's attribute
// pass through the scrolled window (garbled playfield, sim vs MAME). Cleared by its acknowledge.
wire line_start = cen_pix && (hc == 9'd319);                    // v9 steps here
wire irq2_line  = v9[8] && (v8[5:0] == 6'd31);                  // the line before 32 / 96 / 160 / 224
reg  irq2 = 1'b0;
always_ff @(posedge clk) begin
    if (reset | ~dual)              irq2 <= 1'b0;
    else if (cen_cpu2 & int_ack)    irq2 <= 1'b0;
    else if (line_start & irq2_line & ~pause) irq2 <= 1'b1;
end

// Watchdog 4D (Nova): at each VBLANK end, reload 8 if the IRQ was acknowledged, else count. Bit 3 low holds the CPU
// (and the AYs) in reset, so 8 un-acked frames trip it for about 8 frames. Any 8000-9FFF access clears it to 0 at once.
// Frozen while paused: the stopped CPU cannot acknowledge, so the OSD / pause must not trip it.
reg [3:0] wdog = 4'd8;
always_ff @(posedge clk) begin
    if (reset | ~v_nova)                wdog <= 4'd8;
    else if (pause)                     ;
    else if (cs_stnpd)                  wdog <= 4'd0;
    else if (~vblank & vbl_d)           wdog <= irq ? wdog + 4'd1 : 4'd8;
end
wire cpu_reset = reset | ~wdog[3];

// Coin pulse. Nova 2001's program reboots itself (jp 0000) when COIN stays low for about 7 frames or more, and a held
// button does exactly that (sim: 10 / 30 frames held -> reset, 3 -> credit). Each press becomes one pulse: MAME's
// PORT_IMPULSE(4) (Nova) / (5) (Raiders5). Counted on VBLANK starts, held while paused.
wire       coin_btn = ~keycoin[6];
reg        coin_btn_d = 1'b0;
reg  [2:0] coin_cnt   = 3'd0;
always_ff @(posedge clk) begin
    coin_btn_d <= coin_btn;
    if (reset)                                 coin_cnt <= 3'd0;
    else if (coin_btn & ~coin_btn_d)           coin_cnt <= v_r5 ? 3'd5 : 3'd4;
    else if (~pause & vblank & ~vbl_d & (coin_cnt != 3'd0)) coin_cnt <= coin_cnt - 3'd1;
end
wire coin_n = ~(coin_cnt != 3'd0);

// Inputs (active low unless noted). VBLANK reads as /VBLANK on every board (Nova schematic; matches MAME in sim).
wire [7:0] in0 = {pad1[4], pad1[5], 2'b11, pad1[0], pad1[1], pad1[2], pad1[3]};
wire [7:0] in1 = {pad2[4], pad2[5], 2'b11, pad2[0], pad2[1], pad2[2], pad2[3]};
wire [7:0] in2 = {~vblank, 4'b1111, keycoin[1], keycoin[0], coin_n};

wire [7:0] pk_in0 = {~vblank, 1'b1, keycoin[0], 2'b11, pad1[4], pad1[0], pad1[1]};
wire [7:0] pk_in1 = {keycoin[6], keycoin[3], keycoin[1], 2'b11, pad2[4], pad2[0], pad2[1]};

// Ninjakun: IN0 / IN1 bits 6-7 and the IN1 service / coin bits are active high; IN2 = {latch, /VBLANK, 0}.
wire [7:0] nk_in0 = {2'b00, keycoin[0], 1'b1, pad1[4], pad1[5], pad1[0], pad1[1]};
wire [7:0] nk_in1 = {~keycoin[6], ~keycoin[3], keycoin[1], 1'b1, pad2[4], pad2[5], pad2[0], pad2[1]};
wire [7:0] nk_in2 = {4'b0000, nk_ctrl, ~vblank, 1'b0};

wire [7:0] r5_in0 = {~vblank, 1'b1, keycoin[0], pad1[4], pad1[3], pad1[2], pad1[0], pad1[1]};
wire [7:0] r5_in1 = {coin_n, keycoin[3], keycoin[1], pad2[4], pad2[3], pad2[2], pad2[0], pad2[1]};

reg [7:0] cpu_din;
always_comb begin
    if      (int_ack)            cpu_din = 8'hFF;              // nothing drives the bus in INTACK
    else if (cs_rom)             cpu_din = maincpu_data;
    else if (cs_aux)             cpu_din = aux_data;
    else if (cs_fg)              cpu_din = fg_o.a_q[7:0];
    else if (cs_bg)              cpu_din = bg_o.a_q[7:0];
    else if (cs_spr)             cpu_din = spr_o.a_q[7:0];
    else if (cs_work)            cpu_din = work_o.a_q[7:0];
    else if (cs_share | cs_pal)  cpu_din = sh_o.a_q[7:0];
    else if (io_ay_d)            cpu_din = ay_chip ? ym_o[1].dout : ym_o[0].dout;
    else if (io_in)              cpu_din = (A[3:0] == 4'h6) ? in0 : (A[3:0] == 4'h7) ? in1 :
                                           (A[3:0] == 4'hE) ? in2 : 8'hFF;
    else if (cs_nkio)            cpu_din = (A[1:0] == 2'd0) ? nk_in0 : (A[1:0] == 2'd1) ? nk_in1 :
                                           (A[1:0] == 2'd2) ? nk_in2 : 8'hFF;
    else                         cpu_din = 8'hFF;
end

assign z80_i.reset_n = ~cpu_reset;
assign z80_i.ce      = cen_cpu & ~pause;
assign z80_i.int_n   = ~irq;
assign z80_i.nmi_n   = 1'b1;
assign z80_i.di      = cpu_din;

assign z80b_i.reset_n = ~(reset | ~dual);
assign z80b_i.ce      = cen_cpu2 & ~pause;
assign z80b_i.int_n   = ~irq2;
assign z80b_i.nmi_n   = 1'b1;
assign z80b_i.di      = cpu_din;

//------------------------------------------------------- AY-3-8910 x2 ---------------------------------------------------------//

// jt03 takes a write strobe exactly one clk wide; addr 0 = register select, 1 = data. Reads hold addr 1, so dout is
// the selected SSG register (jt12_dout registers it every clk). One CPU: strobe on the select's rising edge. Two CPUs:
// the bus changes owner every 10 clocks, so each CPU strobes once, on its first cen of the write.
wire ay_sel = (io_ay_d | io_ay_a) & wr;
reg  ay_sel_d = 1'b0;
always_ff @(posedge clk) ay_sel_d <= ay_sel;

reg [1:0] ay_done = 2'b00;                   // per CPU: this write has been strobed
always_ff @(posedge clk) begin
    if (cen_cpu)  ay_done[0] <= ay_sel;
    if (cen_cpu2) ay_done[1] <= ay_sel;
end
wire ay_wr = (dual ? (cen_bus & ay_sel & ~ay_done[who2]) : (ay_sel & ~ay_sel_d)) & ~cpu_reset;

genvar ai;
generate
    for (ai = 0; ai < 2; ai = ai + 1) begin : ay
        wire sel = ay_chip ? (ai == 1) : (ai == 0);
        assign ym_i[ai].rst    = cpu_reset;
        assign ym_i[ai].ce     = cen_ay;
        assign ym_i[ai].cs_n   = ~(ay_wr & sel);
        assign ym_i[ai].wr_n   = ~(ay_wr & sel);
        assign ym_i[ai].addr   = ~io_ay_a;
        assign ym_i[ai].din    = cpu_dout;
    end
endgenerate

// Ports. Nova: ay1 drives the bg scroll, ay2 reads DSW1 / DSW2. pkunwar / Raiders5: ay1 reads IN0 / IN1, ay2 reads
// IN2 (a DIP bank: MRA dip byte 2) / DSW1. Ninjakun: ay1 reads DSW1 / DSW2, ay2 drives the bg scroll.
assign ym_i[0].ioa_in = pkw ? pk_in0 : v_r5 ? r5_in0 : v_nk ? dsw1 : 8'hFF;
assign ym_i[0].iob_in = pkw ? pk_in1 : v_r5 ? r5_in1 : v_nk ? dsw2 : 8'hFF;
assign ym_i[1].ioa_in = (pkw | v_r5) ? dsw2 : v_nk ? 8'hFF : dsw1;
assign ym_i[1].iob_in = (pkw | v_r5) ? dsw1 : v_nk ? 8'hFF : dsw2;

// An AY port set as input floats; the scroll bus is pulled up, so 0xFF until the game makes it an output
// (MAME agrees: bg at -1 through the Nova boot tests). Raiders5 latches its scroll directly; pkunwar has none.
wire [7:0] ay_sx = v_nk ? (ym_o[1].ioa_oe ? ym_o[1].ioa_out : 8'hFF) : (ym_o[0].ioa_oe ? ym_o[0].ioa_out : 8'hFF);
wire [7:0] ay_sy = v_nk ? (ym_o[1].iob_oe ? ym_o[1].iob_out : 8'hFF) : (ym_o[0].iob_oe ? ym_o[0].iob_out : 8'hFF);
wire [7:0] scroll_x = pkw ? 8'd0 : v_r5 ? r5_sx : ay_sx;
wire [7:0] scroll_y = pkw ? 8'd0 : v_r5 ? r5_sy : ay_sy;

// All six channels are shorted together on the board. Two 10-bit SSG sums, centred, x16.
wire [10:0] ay_sum = {1'b0, ym_o[0].psg_snd} + {1'b0, ym_o[1].psg_snd};
assign sound = pause ? 16'sd0 : $signed({1'b0, ay_sum, 4'd0}) - 16'sd16384;

//------------------------------------------------------- Palette PROM ---------------------------------------------------------//

// Both windows feed the same 32 bytes. A pkunwar index 0 also covers 0x10000-0x1001F (gfx), but its index 11 comes
// later in the MRA and overwrites them; Nova sends no index 11.
reg [7:0] prom [0:31];
always_ff @(posedge clk)
    if (ioctl_wr && (((ioctl_index == 8'd0)  && (ioctl_addr[24:5] == 20'h00800)) ||
                     ((ioctl_index == 8'd11) && (ioctl_addr[24:5] == 20'h00000))))
        prom[ioctl_addr[4:0]] <= ioctl_data;

//------------------------------------------------------- RAM ports ------------------------------------------------------------//

// Port A = CPU bus. Port B = video (fg / bg map, sprite list, palette) and the framebuffer readout / erase.
wire [10:0] a11 = A[10:0];

// Ninjakun / Raiders5 see the bg map through a window offset by the scroll registers (MAME ninjakun_bg_videoram_r/w).
wire [9:0]  bg_win  = a11[9:0] + {scroll_y[7:3], scroll_x[7:3]};
wire [10:0] bg_cpu  = dual ? {a11[10], bg_win} : a11;

// Ninjakun CPU 2 sees the two shared 1K halves swapped. Palette RAM sits at 0x800.
wire [12:0] sh_cpu  = cs_pal ? {4'b0100, A[8:0]} : {2'b00, a11[10] ^ (v_nk & who2), a11[9:0]};

assign fg_i.a_addr   = {3'd0, a11};     assign fg_i.a_we   = wr_cen & cs_fg;
assign bg_i.a_addr   = {3'd0, bg_cpu};  assign bg_i.a_we   = wr_cen & cs_bg;
assign spr_i.a_addr  = {3'd0, a11};     assign spr_i.a_we  = wr_cen & cs_spr;
assign work_i.a_addr = {3'd0, a11};     assign work_i.a_we = wr_cen & cs_work;
assign sh_i.a_addr   = {1'b0, sh_cpu};  assign sh_i.a_we   = wr_cen & (cs_share | cs_pal);

assign fg_i.a_be   = 4'hF;  assign fg_i.a_din   = {24'd0, cpu_dout};
assign bg_i.a_be   = 4'hF;  assign bg_i.a_din   = {24'd0, cpu_dout};
assign spr_i.a_be  = 4'hF;  assign spr_i.a_din  = {24'd0, cpu_dout};
assign work_i.a_be = 4'hF;  assign work_i.a_din = {24'd0, cpu_dout};
assign sh_i.a_be   = 4'hF;  assign sh_i.a_din   = {24'd0, cpu_dout};

assign fg_i.b_we   = 1'b0;  assign fg_i.b_be   = 4'hF;  assign fg_i.b_din   = 32'd0;
assign bg_i.b_we   = 1'b0;  assign bg_i.b_be   = 4'hF;  assign bg_i.b_din   = 32'd0;
assign spr_i.b_we  = 1'b0;  assign spr_i.b_be  = 4'hF;  assign spr_i.b_din  = 32'd0;
assign work_i.b_we = 1'b0;  assign work_i.b_be = 4'hF;  assign work_i.b_din = 32'd0;
assign sh_i.b_we   = 1'b0;  assign sh_i.b_be   = 4'hF;  assign sh_i.b_din   = 32'd0;
assign work_i.b_addr = 14'd0;

// The gfx regions are loaded file by file. MAME rearranges them at load, decoded here on read with one mapping:
// Nova / Ninjakun ROM_LOAD16_BYTE (8K pairs: byte g -> {g[14] pair, g[0] odd file, g[13:1]}) and the pkunwar /
// Raiders5 lineswap_gfx_roms bit 13 (16K files: g -> {g[15:14], g[0], g[13:1]}). gfx2 sits at 0x8000: only the
// Ninjakun / Raiders5 regions use it, and theirs are 32K or less, so g[15] is free there.
function automatic [17:0] gfx_map(input gfx2, input [15:0] g);
    gfx_map = {2'b00, g[15] | gfx2, g[14], g[0], g[13:1]};
endfunction

//------------------------------------------------------- Display fetch --------------------------------------------------------//

// One pixel per 10 clocks, all reads in the slot (BRAM q is valid the clock after the address):
//   ph1 map codes + fb word   ph2 attrs   ph3 fg gfx byte   ph4 bg gfx byte   ph6 erase / palette RAM   ph9 output
wire [7:0] xf = hc[7:0] ^ {8{flip_screen}};
wire [7:0] yf = v8      ^ {8{flip_screen}};

// Ninjakun / Raiders5 bg sits 7 px left of MAME's raw scroll (VIDEO_START scrolldx(7, 0)).
wire [7:0] bx = xf + scroll_x - (dual ? 8'd7 : 8'd0);
wire [7:0] by = yf + scroll_y;

wire [9:0] fg_idx = {yf[7:3], xf[7:3]};
wire [9:0] bg_idx = {by[7:3], bx[7:3]};

reg  [7:0] fg_code, fg_attr, bg_code, bg_attr, fg_byte, bg_byte;
reg [31:0] fb_word;

wire attr_ph = (pix_ph >= 4'd2);
assign fg_i.b_addr = {3'd0, attr_ph, fg_idx};
assign bg_i.b_addr = {3'd0, attr_ph, bg_idx};

// Tile codes (each tile = code*32 + row*4 + px/2 in its gfx region):
//   fg  Nova / Raiders5: gfx1 code 0-255 (Raiders5's layout8x8_part covers the same first quarter); Ninjakun: 9 bits, attr[5]
//   bg  Nova: gfx1 0x4000 + code; pkunwar: gfx1, attr[2:0] = code bits 8-10; Ninjakun: gfx2, attr[7:6]; Raiders5: gfx2, attr[0]
wire [10:0] fg_code11 = v_nk ? {2'b00, fg_attr[5], fg_code} : {3'b000, fg_code};
wire [10:0] bg_code11 = pkw  ? {bg_attr[2:0], bg_code} : v_nk ? {1'b0, bg_attr[7:6], bg_code} :
                        v_r5 ? {2'b00, bg_attr[0], bg_code} : {3'b010, bg_code};
wire [15:0] fg_g = {fg_code11, yf[2:0], xf[2:1]};
wire [15:0] bg_g = {bg_code11, by[2:0], bx[2:1]};

always_ff @(posedge clk) begin
    case (pix_ph)
        4'd2: begin fg_code <= fg_o.b_q[7:0]; bg_code <= bg_o.b_q[7:0]; fb_word <= fb_o.b_q; end
        4'd3: begin fg_attr <= fg_o.b_q[7:0]; bg_attr <= bg_o.b_q[7:0]; end
        4'd4: fg_byte <= gfx_data;
        4'd5: bg_byte <= gfx_data;
        default: ;
    endcase
end

wire [3:0] fg_pen = xf[0] ? fg_byte[3:0] : fg_byte[7:4];
wire [3:0] bg_pen = bx[0] ? bg_byte[3:0] : bg_byte[7:4];
wire [3:0] sp_pen = fb_word[{xf[1:0], 3'b000} +: 4];

wire [3:0] fg_col = v_r5 ? fg_attr[7:4] : fg_attr[3:0];
wire [3:0] bg_col = (pkw | v_r5) ? bg_attr[7:4] : bg_attr[3:0];

// Orthogonal palette (PROM boards): pen 1 takes the attribute colour (sprites had it substituted when written).
wire [3:0] fg_pix = (fg_pen == 4'd1) ? fg_col : fg_pen;
wire [3:0] bg_pix = (bg_pen == 4'd1) ? bg_col : bg_pen;

// Priority as MAME draws it. Nova / Raiders5: fg over sprites over bg; the Nova schematic's FG priority bit (attr bit 4)
// is not used: its gate type is ambiguous and MAME found the literal reading wrong (Claude/upl_schematic_facts.md sec. 5).
// pkunwar: sprites over bg, except opaque pixels of bg tiles with attr bit 3 set (MAME's category 1 pass).
// Ninjakun: fg tiles with attr bit 4 set go under the sprites (category 1), the rest over.
wire        fg_op  = ~pkw & (fg_pen != 4'd0);
wire        fg_lo  = v_nk & fg_attr[4];
wire        bg_hi  = pkw & bg_attr[3] & (bg_pen != 4'd0);
wire        sp_op  = (sp_pen != 4'd0) & ~bg_hi;
wire [1:0]  layer  = (fg_op & ~fg_lo) ? 2'd0 : sp_op ? 2'd1 : fg_op ? 2'd0 : 2'd2;   // 0 fg, 1 sprite, 2 bg

// PROM boards: 32 entries, {bg, pen-or-colour}. RAM boards (Ninjakun / Raiders5): fg 0x000 + colour*16 + pen, bg 0x100 +,
// sprites the orthogonal sprite palette = RAM entry (pen 1 ? colour : pen), which the stored nibble already is.
wire [4:0]  pal_a  = (layer == 2'd0) ? {1'b0, fg_pix} : (layer == 2'd1) ? {1'b0, sp_pen} : {1'b1, bg_pix};
wire [8:0]  pal_r  = (layer == 2'd0) ? {1'b0, fg_col, fg_pen} : (layer == 2'd1) ? {5'd0, sp_pen} : {1'b1, bg_col, bg_pen};
assign sh_i.b_addr = {3'b001, 2'b00, pal_r};                 // 0x800 + entry
wire [7:0]  pal_q  = dual ? sh_o.b_q[7:0] : prom[pal_a];

// BBGGRRII: each gun = {hi, lo, I1, I0}, MAME's linear approximation of the 470R/1K/2.2K/4.7K DAC.
wire [3:0] r4 = {pal_q[3:2], pal_q[1:0]};
wire [3:0] g4 = {pal_q[5:4], pal_q[1:0]};
wire [3:0] b4 = {pal_q[7:6], pal_q[1:0]};

always_ff @(posedge clk) begin
    if (pix_ph == 4'd9) begin
        R <= disp ? {r4, r4} : 8'd0;
        G <= disp ? {g4, g4} : 8'd0;
        B <= disp ? {b4, b4} : 8'd0;
        HBlank <= hblank;
        VBlank <= vblank;
        HSync  <= hsync;
        VSync  <= vsync_l;
    end
end

//------------------------------------------------------- Sprites --------------------------------------------------------------//

// On each VBLANK line one sprite is drawn into the framebuffer: index {/5V, V[4:0]}, so V 224-255 draws 0-31 and V 0-31
// draws 32-63 (the VSYNC lines repeat 24-31 with writes blocked). Higher indices land on top, as in MAME. The display
// reads each word and erases it after its fourth pixel, so every frame starts empty.
// Record bytes arrive one clock after their address: S_REC steps byte 0-3 (capturing the previous one), S_ATTR takes
// byte 3. Then per row / column pair: S_FETCH addresses the gfx byte, S_WAIT takes it, S_PIX0/1 write its two pixels.
localparam [2:0] S_IDLE = 3'd0, S_REC = 3'd1, S_ATTR = 3'd2, S_FETCH = 3'd3, S_WAIT = 3'd4, S_PIX0 = 3'd5, S_PIX1 = 3'd6;

reg  [2:0] s_st = S_IDLE;
reg  [1:0] s_byte = 2'd0;
reg  [7:0] s_code, s_x, s_y, s_attr;
reg  [7:0] s_r_c;                 // {row 0-15, 1'b0, column pair 0-7}
reg  [7:0] s_gbyte;
reg        s_lane;

wire [5:0] s_idx = {~v8[5], v8[4:0]};
assign spr_i.b_addr = {3'd0, s_idx, 3'b000, s_byte};

// Record: Nova / Ninjakun {code, x, y, attr: 0-3 colour, 4 flip x, 5 flip y, 6 x MSB, 7 disable};
// pkunwar / Raiders5 {code[5:0] flip y flip x, x, y, attr: 0-2 code[8:6], 3 disable, 4-7 colour}, no x MSB (wraps at
// 256). Raiders5's gfx1 holds 256 sprites, so its code wraps at 8 bits.
wire [8:0] s_code9 = pk_spr ? {s_attr[2:0] & {~v_r5, 2'b11}, s_code[7:2]} : {1'b0, s_code};
wire       s_fx    = pk_spr ? s_code[0] : s_attr[4];
wire       s_fy    = pk_spr ? s_code[1] : s_attr[5];
wire [3:0] s_color = pk_spr ? s_attr[7:4] : s_attr[3:0];
wire       s_off   = pk_spr ? s_attr[3] : s_attr[7];

wire [3:0] s_row  = s_r_c[7:4];
wire [2:0] s_pair = s_r_c[2:0];
wire [3:0] s_ry   = s_fy ? ~s_row : s_row;
wire [3:0] s_col  = {s_pair, s_lane};                       // column of the pixel being written
wire [3:0] s_cx   = s_fx ? ~s_col : s_col;

// 16x16 layout: code*128 + (y >= 8)*64 + (x >= 8)*32 + (y & 7)*4 + (x & 7)/2
wire [3:0]  s_cx_pair = s_fx ? ~{s_pair, 1'b0} : {s_pair, 1'b0};   // the byte holds columns 2n / 2n+1
wire [15:0] s_g = {s_code9, s_ry[3], s_cx_pair[3], s_ry[2:0], s_cx_pair[2:1]};

wire [3:0] s_pen  = s_cx[0] ? s_gbyte[3:0] : s_gbyte[7:4];
wire [3:0] s_pix  = (s_pen == 4'd1) ? s_color : s_pen;
wire [8:0] s_px   = {1'b0, s_x} + {5'd0, s_col};
wire [7:0] s_py   = s_y + {4'd0, s_row};
wire       s_we   = (s_pen != 4'd0) && (pk_spr || (s_px[8] == s_attr[6])) && !s_off && !vsync_l;

wire s_start = cen_pix && (hc == 9'd0) && vblank;

always_ff @(posedge clk) begin
    if (reset) begin
        s_st <= S_IDLE;
    end else begin
        case (s_st)
            S_IDLE: if (s_start) begin s_byte <= 2'd0; s_st <= S_REC; end
            S_REC: begin
                case (s_byte)
                    2'd1: s_code <= spr_o.b_q[7:0];
                    2'd2: s_x    <= spr_o.b_q[7:0];
                    2'd3: s_y    <= spr_o.b_q[7:0];
                    default: ;
                endcase
                s_byte <= s_byte + 2'd1;
                if (s_byte == 2'd3) s_st <= S_ATTR;
            end
            S_ATTR:  begin s_attr <= spr_o.b_q[7:0]; s_r_c <= 8'd0; s_st <= S_FETCH; end
            S_FETCH: s_st <= S_WAIT;
            S_WAIT:  begin s_gbyte <= gfx_data; s_lane <= 1'b0; s_st <= S_PIX0; end
            S_PIX0:  begin s_lane <= 1'b1; s_st <= S_PIX1; end
            S_PIX1: begin
                if (s_r_c == 8'hF7) s_st <= S_IDLE;
                else begin
                    s_r_c <= (s_r_c[2:0] == 3'd7) ? {s_r_c[7:4] + 4'd1, 4'd0} : s_r_c + 8'd1;
                    s_st  <= S_FETCH;
                end
            end
            default: s_st <= S_IDLE;
        endcase
    end
end

// gfx port: sprites own it on VBLANK lines (the schematic's ROM mux, S = /VBLANK), the display otherwise.
// Sprites and fg tiles are always gfx1; the Ninjakun / Raiders5 bg is gfx2.
wire disp_bg_ph = (pix_ph >= 4'd4);
assign gfx_addr = gfx_map(~vblank & disp_bg_ph & dual, vblank ? s_g : disp_bg_ph ? bg_g : fg_g);

// Framebuffer: port A = sprite writes (byte lane = x[1:0]), port B = display read + erase.
wire s_wr_now = (s_st == S_PIX0 || s_st == S_PIX1) && s_we;

assign fb_i.a_addr = {s_py, s_px[7:2]};
assign fb_i.a_we   = s_wr_now;
assign fb_i.a_be   = 4'b0001 << s_px[1:0];
assign fb_i.a_din  = {4{4'd0, s_pix}};

wire erase = disp && (pix_ph == 4'd6) && (xf[1:0] == (flip_screen ? 2'd0 : 2'd3));

assign fb_i.b_addr = {yf, xf[7:2]};
assign fb_i.b_we   = erase;
assign fb_i.b_be   = 4'hF;
assign fb_i.b_din  = 32'd0;

endmodule
