//============================================================================
//
//  xxmissio_board.sv — UPL XX Mission (1986), MAME upl/xxmissio.cpp. No schematic exists (wiring sheet only:
//  Claude/upl_schematic_facts.md), so everything here is from MAME:
//    2x Z80 @ 3 MHz with their own ROMs (sub ROM banked 8 x 16K), 2x YM2203 @ 1.5 MHz (FM in use), 12 MHz pixel clock,
//    512x192 visible (ROT90), 16x8 tiles: fg (no scroll) + bg (scrolled by ym2's port A / B), 64 sprites of 32x16,
//    768-entry BBGGRRII palette RAM. CPUs, YM pair and RAMs are the shared pool in rtl/UPLFramebuffer.sv; the bg is
//    the ninjakd2 board's BGLAYER (XX mode) on the tile1 SDRAM client.
//  Copyright (C) 2026 Rodimus
//
//============================================================================

module xxmissio_board
(
    input                clk,            // 60 MHz fabric
    input          [3:0] pix_ph,         // top's mod-10 phase: 0 and 5 = 12 MHz pixel enables
    input                cen_ym,         // 1.5 MHz, both YM2203 (12 MHz / 8)
    input                reset,
    input                pause,

    // ---- controls, ninjakd2 port order from the wrapper (active low)
    input          [7:0] keycoin,        // 0 start1, 1 start2, 6 coin1
    input          [7:0] pad1,           // 0 right, 1 left, 2 down, 3 up, 4 shoot 1, 5 shoot 2
    input          [7:0] pad2,
    input          [7:0] dsw1,
    input          [7:0] dsw2,

    input                crt_flip,
    input  signed  [3:0] h_adj,          // CRT position: + = sync 4 px earlier = picture right
    input  signed  [3:0] v_adj,          //               + = sync 1 line earlier = picture down

    // ---- main ROM 0000-7FFF (rom_main_fixed), sub ROM 0000-3FFF (rom_snd_lo), and the bank image (rom_main_bank,
    //      1-clock read): sub banks at 0x00000, chars / sprites at 0x20000
    output        [15:0] maincpu_addr,
    input          [7:0] maincpu_data,
    output        [15:0] aux_addr,
    input          [7:0] aux_data,
    output reg    [17:0] gfx_addr,
    input          [7:0] gfx_data,

    // ---- bg tiles (SDRAM tile1, MRA index 7)
    output        [18:0] tile_addr,
    output               tile_req,
    input                tile_ack,
    input          [7:0] tile_data,

    // ---- video / audio
    output reg           HSync, VSync,
    output reg           HBlank, VBlank,
    output reg     [7:0] R, G, B,
    output signed [15:0] sound,

    // ---- shared chips (rtl/UPLFramebuffer.sv)
    output chip_pool_pkg::z80r_i_t         z80_i,     // main CPU
    input  chip_pool_pkg::z80_o_t          z80_o,
    output chip_pool_pkg::z80r_i_t         z80b_i,    // sub CPU
    input  chip_pool_pkg::z80_o_t          z80b_o,
    output chip_pool_pkg::ym2203_i_t [1:0] ym_i,      // 0 = ym1 (DSW ports), 1 = ym2 (scroll ports)
    input  chip_pool_pkg::ym2203_o_t [1:0] ym_o,
    output chip_pool_pkg::dpram_i_t        fg_i,      // ram2k_0: fg VRAM
    input  chip_pool_pkg::dpram_o_t        fg_o,
    output chip_pool_pkg::dpram_i_t        bg_i,      // ram8k_0: bg VRAM
    input  chip_pool_pkg::dpram_o_t        bg_o,
    output chip_pool_pkg::dpram_i_t        spr_i,     // ram8k_1: sprite RAM
    input  chip_pool_pkg::dpram_o_t        spr_o,
    output chip_pool_pkg::dpram_i_t        pal_i,     // ram8k_2: palette RAM 0x000-0x2FF
    input  chip_pool_pkg::dpram_o_t        pal_o,
    output chip_pool_pkg::dpram_i_t        work_i,    // ram8k_3: the two 4K work RAMs
    input  chip_pool_pkg::dpram_o_t        work_o,
    output chip_pool_pkg::dpram_i_t        fb_i,      // ram_fb: sprite line buffers
    input  chip_pool_pkg::dpram_o_t        fb_o
);

//------------------------------------------------------- Clocks / timing ------------------------------------------------------//

// Pixel x = {pair, odd}: the even pixel spans pix_ph 1-5, the odd one 6-9 and 0, so the pair counter steps at phase 0.
// k = clock within the current pixel (0-4); 4 is the pixel enable.
reg  [2:0] k;
always_comb begin
    case (pix_ph)
        4'd1, 4'd6: k = 3'd0;
        4'd2, 4'd7: k = 3'd1;
        4'd3, 4'd8: k = 3'd2;
        4'd4, 4'd9: k = 3'd3;
        default:    k = 3'd4;
    endcase
end
wire       odd = (pix_ph >= 4'd6) | (pix_ph == 4'd0);
wire       ce12 = (k == 3'd4);

// H: 768 pixels at 12 MHz (2x the 6 MHz UPL boards' 384), 0-511 visible. V: 264 lines, 32-223 visible (MAME visarea).
// Neither total is documented (no schematic): same line and frame rate as the other UPL boards #inferred.
reg [8:0] pc = 9'd0;                         // pixel pair 0-383
reg [8:0] vc = 9'd0;                         // line 0-263 = MAME y for 0-255
wire [9:0] hc = {pc, odd};

wire pair_end = (pix_ph == 4'd0);
wire line_end = pair_end && (pc == 9'd383);

always_ff @(posedge clk) begin
    if (reset) begin
        pc <= 9'd0; vc <= 9'd0;
    end else if (pair_end) begin
        pc <= (pc == 9'd383) ? 9'd0 : pc + 9'd1;
        if (pc == 9'd383) vc <= (vc == 9'd263) ? 9'd0 : vc + 9'd1;
    end
end

wire hblank = hc[9];                                     // 512-767
wire vblank = (vc < 9'd32) || (vc >= 9'd224);
wire disp   = ~hblank & ~vblank;

// Syncs centred in blanking (front / back porch 72 / 120 px, 27 / 42 lines). The OSD position moves the sync only.
wire [9:0] hs_on = 10'd584 - {{4{h_adj[3]}}, h_adj, 2'b00};
wire [8:0] vs_on = 9'd251 - {{5{v_adj[3]}}, v_adj};
wire hsync = (hc >= hs_on) && (hc < hs_on + 10'd64);
wire vsync = (vc >= vs_on) && (vc < vs_on + 9'd3);

// CPUs: 3 MHz each (12 MHz / 4) on opposite 6 MHz phases, one shared bus as on the Ninjakun board.
reg h0 = 1'b0;
always_ff @(posedge clk) if (pair_end) h0 <= ~h0;
wire cen_cpu  = pair_end &  h0;              // main
wire cen_cpu2 = pair_end & ~h0;              // sub

//------------------------------------------------------- CPU bus --------------------------------------------------------------//

// Each CPU owns the bus for the 10 clocks that end with its own clock enable, so a BRAM read addressed in the owner's
// window is valid when it samples DI and every write lands on the owner's cen.
wire who2 = ~h0;

wire [15:0] A        = who2 ? z80b_o.a    : z80_o.a;
wire  [7:0] cpu_dout = who2 ? z80b_o.dout : z80_o.dout;
wire        mreq     = who2 ? (~z80b_o.mreq_n & z80b_o.rfsh_n) : (~z80_o.mreq_n & z80_o.rfsh_n);
wire        rd       = who2 ? ~z80b_o.rd_n : ~z80_o.rd_n;
wire        wr       = who2 ? ~z80b_o.wr_n : ~z80_o.wr_n;
wire        int_ack  = who2 ? (~z80b_o.m1_n & ~z80b_o.iorq_n) : (~z80_o.m1_n & ~z80_o.iorq_n);

wire cen_bus = pair_end;
wire wr_cen  = cen_bus & wr;                 // RAMs take every cen of the write (same data); latches are levels

// MAME base_map (both CPUs): 8000-8003 YM2203 x2, A000 P1, A001 P2, A002 status (r) / CPU-to-CPU (w), A003 flip,
// C000 fg, C800 bg (scroll window), D000 sprites, D800-DAFF palette.
// main: 0000-7FFF ROM, E000 workram1, F000 workram2. sub: 0000-3FFF ROM, 4000-7FFF bank, 8006 bank select,
// E000 workram2, F000 workram1.
wire cs_rom_m = mreq & ~who2 & ~A[15];
wire cs_rom_s = mreq &  who2 & (A[15:14] == 2'b00);
wire cs_bank  = mreq &  who2 & (A[15:14] == 2'b01);
wire cs_ym    = mreq & (A[15:2] == 14'h2000);
wire cs_bksel = mreq &  who2 & (A == 16'h8006);
wire cs_io    = mreq & (A[15:2] == 14'h2800);
wire cs_fg    = mreq & (A[15:11] == 5'b11000);
wire cs_bg    = mreq & (A[15:11] == 5'b11001);
wire cs_spr   = mreq & (A[15:11] == 5'b11010);
wire cs_pal   = mreq & (A[15:10] == 6'b110110);
wire cs_work  = mreq & (A[15:13] == 3'b111);

assign maincpu_addr = {1'b0, A[14:0]};
assign aux_addr     = {2'b00, A[13:0]};

reg [2:0] bank = 3'd0;
reg       flip = 1'b0;
always_ff @(posedge clk) begin
    if (reset) begin
        bank <= 3'd0; flip <= 1'b0;
    end else begin
        if (wr_cen & cs_bksel)                   bank <= cpu_dout[2:0];
        if (wr_cen & cs_io & (A[1:0] == 2'd3))   flip <= cpu_dout[0];
    end
end
wire flip_screen = flip ^ crt_flip;

// Status / interrupts (MAME status_m_w / status_s_w / interrupt_m / interrupt_s). Both IRQs are HOLD_LINE: held until
// the CPU acknowledges (both run IM 1; MAME still answers the acknowledge with 0x10).
//   main IRQ: VBLANK start, or the sub CPU writing 0x80. sub IRQ: 2 x 60 Hz periodic, or the main CPU writing 0x40.
// MAME's periodic timer is frame-locked (Ninjakun measured its 4 x 60 Hz one on VBLANK start), so the sub IRQ fires on
// lines 224 and 96 #inferred.
reg [5:2] stat = 4'd0;
reg       irq_m = 1'b0, irq_s = 1'b0;
wire      st_wr     = wr_cen & cs_io & (A[1:0] == 2'd2);
wire      line_tick = line_end & ~pause;                  // vc steps to the next line here
wire      vbl_start = line_tick && (vc == 9'd223);
wire      sub_tick  = line_tick && ((vc == 9'd223) || (vc == 9'd95));

always_ff @(posedge clk) begin
    if (reset) begin
        stat <= 4'd0; irq_m <= 1'b0; irq_s <= 1'b0;
    end else begin
        if (cen_cpu  & int_ack) irq_m <= 1'b0;
        if (cen_cpu2 & int_ack) irq_s <= 1'b0;
        if (st_wr & ~who2) begin
            if (cpu_dout == 8'h00) stat[5] <= 1'b1;
            if (cpu_dout == 8'h40) begin stat[3] <= 1'b0; irq_s <= 1'b1; end
            if (cpu_dout == 8'h80) stat[2] <= 1'b1;
        end
        if (st_wr &  who2) begin
            if (cpu_dout == 8'h00) stat[4] <= 1'b1;
            if (cpu_dout == 8'h40) stat[3] <= 1'b1;
            if (cpu_dout == 8'h80) begin stat[2] <= 1'b0; irq_m <= 1'b1; end
        end
        if (vbl_start) begin stat[5] <= 1'b0; irq_m <= 1'b1; end
        if (sub_tick)  begin stat[4] <= 1'b0; irq_s <= 1'b1; end
    end
end

// Inputs, active low (MAME INPUT_PORTS xxmissio). STATUS bit 1 = /VBLANK, bits 0, 6, 7 never set.
wire [7:0] in_p1  = {1'b1, keycoin[0], pad1[5], pad1[4], pad1[0], pad1[1], pad1[2], pad1[3]};
wire [7:0] in_p2  = {keycoin[6], keycoin[1], pad2[5], pad2[4], pad2[0], pad2[1], pad2[2], pad2[3]};
wire [7:0] in_st  = {2'b00, stat, ~vblank, 1'b0};

reg [7:0] cpu_din;
always_comb begin
    if      (int_ack)   cpu_din = 8'h10;
    else if (cs_rom_m)  cpu_din = maincpu_data;
    else if (cs_rom_s)  cpu_din = aux_data;
    else if (cs_bank)   cpu_din = gfx_data;
    else if (cs_ym)     cpu_din = A[1] ? ym_o[1].dout : ym_o[0].dout;
    else if (cs_io)     cpu_din = (A[1:0] == 2'd0) ? in_p1 : (A[1:0] == 2'd1) ? in_p2 :
                                  (A[1:0] == 2'd2) ? in_st : 8'hFF;
    else if (cs_fg)     cpu_din = fg_o.a_q[7:0];
    else if (cs_bg)     cpu_din = bg_o.a_q[7:0];
    else if (cs_spr)    cpu_din = spr_o.a_q[7:0];
    else if (cs_pal)    cpu_din = pal_o.a_q[7:0];
    else if (cs_work)   cpu_din = work_o.a_q[7:0];
    else                cpu_din = 8'hFF;
end

assign z80_i.reset_n = ~reset;
assign z80_i.ce      = cen_cpu & ~pause;
assign z80_i.int_n   = ~irq_m;
assign z80_i.nmi_n   = 1'b1;
assign z80_i.di      = cpu_din;

assign z80b_i.reset_n = ~reset;
assign z80b_i.ce      = cen_cpu2 & ~pause;
assign z80b_i.int_n   = ~irq_s;
assign z80b_i.nmi_n   = 1'b1;
assign z80b_i.di      = cpu_din;

//------------------------------------------------------- YM2203 x2 ------------------------------------------------------------//

// jt03 takes a write strobe exactly one clk wide; A0 = address / data, A1 = chip. The bus changes owner every 10
// clocks, so each CPU strobes once, on its first cen of the write.
wire ym_sel = cs_ym & wr;
reg [1:0] ym_done = 2'b00;
always_ff @(posedge clk) begin
    if (cen_cpu)  ym_done[0] <= ym_sel;
    if (cen_cpu2) ym_done[1] <= ym_sel;
end
wire ym_wr = cen_bus & ym_sel & ~ym_done[who2] & ~reset;

genvar yi;
generate
    for (yi = 0; yi < 2; yi = yi + 1) begin : ym
        wire sel = (A[1] == (yi == 1));
        assign ym_i[yi].rst  = reset;
        assign ym_i[yi].ce   = cen_ym;
        assign ym_i[yi].cs_n = ~(ym_wr & sel);
        assign ym_i[yi].wr_n = ~(ym_wr & sel);
        assign ym_i[yi].addr = A[0];
        assign ym_i[yi].din  = cpu_dout;
    end
endgenerate

// ym1 reads DSW1 / DSW2, ym2 writes the bg scroll. A port set as input reads back 0xFF (MAME writes 0xFF to the
// callback when the port turns to input, and at reset).
assign ym_i[0].ioa_in = dsw1;
assign ym_i[0].iob_in = dsw2;
assign ym_i[1].ioa_in = 8'hFF;
assign ym_i[1].iob_in = 8'hFF;

wire [7:0] xscroll = ym_o[1].ioa_oe ? ym_o[1].ioa_out : 8'hFF;
wire [7:0] yscroll = ym_o[1].iob_oe ? ym_o[1].iob_out : 8'hFF;

// jt03's snd already carries jotego's FM / SSG balance: sum and halve, as the ninjakd2 sound board.
wire signed [16:0] snd_sum = {ym_o[0].snd[15], ym_o[0].snd} + {ym_o[1].snd[15], ym_o[1].snd};
assign sound = pause ? 16'sd0 : snd_sum[16:1];

//------------------------------------------------------- RAM ports ------------------------------------------------------------//

// Port A = CPU bus. The CPUs see the bg map through a window shifted by the x scroll (MAME bgram_r / bgram_w).
wire [4:0]  bg_wx  = A[4:0] + xscroll[7:3];

assign fg_i.a_addr   = {3'd0, A[10:0]};             assign fg_i.a_we   = wr_cen & cs_fg;
assign bg_i.a_addr   = {3'd0, A[10:5], bg_wx};      assign bg_i.a_we   = wr_cen & cs_bg;
assign spr_i.a_addr  = {3'd0, A[10:0]};             assign spr_i.a_we  = wr_cen & cs_spr;
assign pal_i.a_addr  = {4'd0, A[9:0]};              assign pal_i.a_we  = wr_cen & cs_pal;
assign work_i.a_addr = {1'b0, A[12] ^ who2, A[11:0]}; assign work_i.a_we = wr_cen & cs_work;   // sub sees the halves swapped

assign fg_i.a_be   = 4'hF;  assign fg_i.a_din   = {24'd0, cpu_dout};
assign bg_i.a_be   = 4'hF;  assign bg_i.a_din   = {24'd0, cpu_dout};
assign spr_i.a_be  = 4'hF;  assign spr_i.a_din  = {24'd0, cpu_dout};
assign pal_i.a_be  = 4'hF;  assign pal_i.a_din  = {24'd0, cpu_dout};
assign work_i.a_be = 4'hF;  assign work_i.a_din = {24'd0, cpu_dout};

assign fg_i.b_we   = 1'b0;  assign fg_i.b_be   = 4'hF;  assign fg_i.b_din   = 32'd0;
assign bg_i.b_we   = 1'b0;  assign bg_i.b_be   = 4'hF;  assign bg_i.b_din   = 32'd0;
assign spr_i.b_we  = 1'b0;  assign spr_i.b_be  = 4'hF;  assign spr_i.b_din  = 32'd0;
assign pal_i.b_we  = 1'b0;  assign pal_i.b_be  = 4'hF;  assign pal_i.b_din  = 32'd0;
assign work_i.b_we = 1'b0;  assign work_i.b_be = 4'hF;  assign work_i.b_din = 32'd0;
assign work_i.b_addr = 14'd0;

// chars_sprites (MAME ROM_LOAD16_BYTE xx8 / xx6, xx9 / xx7) is loaded file by file at bank image 0x20000:
// MAME byte b -> {b[16] pair, b[0] odd file, b[15:1]}.
function automatic [17:0] cs_map(input [16:0] b);
    cs_map = {1'b1, b[16], b[0], b[15:1]};
endfunction

//------------------------------------------------------- bg (BGLAYER, SDRAM) --------------------------------------------------//

// MAME scrolldx(2, 12): tilemap x = screen x + 2 * xscroll - 2, flipped (511 - x) + 2 * xscroll - 12. y has no offset.
wire [15:0] bg_sx = {7'd0, xscroll, 1'b0} - (flip_screen ? 16'd12 : 16'd2);
wire [15:0] bg_sy = {8'd0, yscroll};

wire [3:0]  bg_color, bg_pix;
wire [18:0] bg_rom;
wire [12:0] bg_vaddr;

UPLFramebuffer_BGLAYER #(.HW(10), .H_TOTAL(10'd768), .V_TOTAL(9'd264), .W_LAST(10'd511), .XX(1)) bg_layer
(
    .clk(clk), .cen_pix(ce12), .reset(reset),
    .fetch_en((vc >= 9'd30) && (vc < 9'd224)), .en(1'b1),
    .h_cnt(hc), .v_cnt(vc), .flip_screen(flip_screen),
    .gfx_robokid(1'b0), .is_omegaf(1'b0), .bg_mnight(1'b0),
    .scrollx(bg_sx), .scrolly(bg_sy),
    .vram_addr(bg_vaddr), .vram_data(bg_o.b_q[7:0]),
    .rom_addr(bg_rom), .rom_req(tile_req), .rom_ack(tile_ack), .rom_data(tile_data),
    .color(bg_color), .pix(bg_pix)
);
assign bg_i.b_addr = {1'b0, bg_vaddr};

// tiles (ROM_LOAD16_BYTE xx10 / xx11) loaded file by file: MAME byte b -> {b[0] odd file, b[15:1]}.
assign tile_addr = {3'b000, bg_rom[0], bg_rom[15:1]};

//------------------------------------------------------- fg (fixed slots, BRAM) -----------------------------------------------//

// Fetched one pixel pair ahead: ph1 code, ph2 attribute, ph3 gfx byte (2 pixels), handed over at the pair boundary.
wire [8:0] pc_n = (pc == 9'd383) ? 9'd0 : pc + 9'd1;
wire [8:0] vc_n = (pc == 9'd383) ? ((vc == 9'd263) ? 9'd0 : vc + 9'd1) : vc;
wire [8:0] fx_n = flip_screen ? (9'd510 - {pc_n[7:0], 1'b0}) : {pc_n[7:0], 1'b0};   // tilemap x of the pair's byte
wire [7:0] fy_n = flip_screen ? (8'd255 - vc_n[7:0]) : vc_n[7:0];
wire [9:0] fg_idx = {fy_n[7:3], fx_n[8:4]};

reg [7:0] fg_code_n, fg_attr_n, fg_byte_n, fg_byte;
reg [2:0] fg_col;

assign fg_i.b_addr = {3'd0, (pix_ph == 4'd2), fg_idx};
wire [16:0] fg_b = {3'b000, fg_code_n, fy_n[2:0], fx_n[3:1]};    // 64 bytes per 16x8 char, 8 per row

always_ff @(posedge clk) begin
    if (pix_ph == 4'd2) fg_code_n <= fg_o.b_q[7:0];
    if (pix_ph == 4'd3) fg_attr_n <= fg_o.b_q[7:0];
    if (pix_ph == 4'd4) fg_byte_n <= gfx_data;
    if (pair_end) begin fg_byte <= fg_byte_n; fg_col <= fg_attr_n[2:0]; end
end

// screen-even pixel = high nibble, flipped = low nibble
wire [3:0] fg_pen = (hc[0] ^ flip_screen) ? fg_byte[3:0] : fg_byte[7:4];

//------------------------------------------------------- Sprites (line buffer) ------------------------------------------------//

// During line vc the engine draws line vc + 1 into line buffer (vc + 1) & 1 of ram_fb, in MAME order (sprite 0 first,
// later sprites on top). Record at 0x20 * n: {code, x, y, attr: 0-2 colour, 4 flip x, 5 flip y, 6 code bit 8}.
// MAME draw_sprites: x = byte1 * 2 - 8 (flipped 474 - byte1 * 2), wrapping mod 512; y = byte2 (flipped 240 - y).
// x is always even, so each gfx byte (2 pixels) is one write with two byte lanes. Buffer bytes = {0, colour, pen}.
localparam [2:0] S_IDLE = 3'd0, S_REC = 3'd1, S_ATTR = 3'd2, S_EVAL = 3'd3, S_FETCH = 3'd4, S_WRITE = 3'd5;

reg [2:0] s_st = S_IDLE;
reg [5:0] s_num;
reg [1:0] s_byte;
reg [7:0] s_code, s_x, s_y, s_attr;
reg [3:0] s_c;                                  // gfx byte column 0-15 (left to right on screen)
reg [8:0] s_tl;                                 // target line
reg [3:0] s_r;                                  // sprite row on the target line

assign spr_i.b_addr = {3'd0, s_num, 3'b000, s_byte};

wire       s_fx = s_attr[4] ^ flip_screen;
wire       s_fy = s_attr[5] ^ flip_screen;
wire [7:0] s_py = flip_screen ? (8'd240 - s_y) : s_y;
wire [7:0] s_dy = s_tl[7:0] - s_py;
wire [8:0] s_px = flip_screen ? (9'd474 - {s_x, 1'b0}) : ({s_x, 1'b0} - 9'd8);
wire [8:0] s_X  = s_px + {4'd0, s_c, 1'b0};

wire [3:0]  s_rr = s_fy ? ~s_r : s_r;
wire [3:0]  s_gb = s_fx ? ~s_c : s_c;
wire [16:0] s_b  = {s_attr[6], s_code, s_rr[3], s_gb[3], s_rr[2:0], s_gb[2:0]};   // 256 bytes per 32x16 sprite

// gfx port: ph9 = sub CPU bank read (sampled at ph0), ph3 = fg, the rest the sprite engine.
wire s_slot = (pix_ph != 4'd3) && (pix_ph != 4'd9);

always_comb begin
    if      (pix_ph == 4'd9) gfx_addr = {1'b0, bank, A[13:0]};
    else if (pix_ph == 4'd3) gfx_addr = cs_map(fg_b);
    else                     gfx_addr = cs_map(s_b);
end

wire line_start = (pix_ph == 4'd1) && (pc == 9'd0);          // first clock of a line, vc already stepped

always_ff @(posedge clk) begin
    if (reset) begin
        s_st <= S_IDLE;
    end else if (line_start) begin
        s_tl   <= (vc == 9'd263) ? 9'd0 : vc + 9'd1;
        s_num  <= 6'd0;
        s_byte <= 2'd0;
        s_st   <= S_REC;
    end else begin
        case (s_st)
            S_REC: begin                                    // byte s_byte addressed, s_byte - 1 arriving
                case (s_byte)
                    2'd1: s_code <= spr_o.b_q[7:0];
                    2'd2: s_x    <= spr_o.b_q[7:0];
                    2'd3: s_y    <= spr_o.b_q[7:0];
                    default: ;
                endcase
                s_byte <= s_byte + 2'd1;
                if (s_byte == 2'd3) s_st <= S_ATTR;
            end
            S_ATTR: begin s_attr <= spr_o.b_q[7:0]; s_st <= S_EVAL; end
            S_EVAL: begin
                s_r <= s_dy[3:0];
                s_c <= 4'd0;
                if ((s_dy[7:4] == 4'd0) && !s_tl[8]) s_st <= S_FETCH;
                else if (s_num == 6'd63)              s_st <= S_IDLE;
                else begin s_num <= s_num + 6'd1; s_byte <= 2'd0; s_st <= S_REC; end
            end
            S_FETCH: if (s_slot) s_st <= S_WRITE;
            S_WRITE: begin
                if (s_c != 4'd15) begin s_c <= s_c + 4'd1; s_st <= S_FETCH; end
                else if (s_num == 6'd63) s_st <= S_IDLE;
                else begin s_num <= s_num + 6'd1; s_byte <= 2'd0; s_st <= S_REC; end
            end
            default: s_st <= S_IDLE;
        endcase
    end
end

// The byte addressed in S_FETCH arrives in S_WRITE. Screen-left pixel = high nibble, flipped = low nibble.
wire [3:0] s_pl = s_fx ? gfx_data[3:0] : gfx_data[7:4];
wire [3:0] s_pr = s_fx ? gfx_data[7:4] : gfx_data[3:0];
wire [7:0] s_vl = {1'b0, s_attr[2:0], s_pl};
wire [7:0] s_vr = {1'b0, s_attr[2:0], s_pr};
wire [1:0] s_be = {s_pr != 4'd0, s_pl != 4'd0};

assign fb_i.a_addr = {6'd0, s_tl[0], s_X[8:2]};
assign fb_i.a_we   = (s_st == S_WRITE) && (s_be != 2'b00);
assign fb_i.a_be   = s_X[1] ? {s_be, 2'b00} : {2'b00, s_be};
assign fb_i.a_din  = {s_vr, s_vl, s_vr, s_vl};

// Display side: read at k = 0, erase the word at k = 2 of its fourth pixel, every line, so each buffer starts empty.
assign fb_i.b_addr = {6'd0, vc[0], hc[8:2]};
assign fb_i.b_we   = ~hc[9] && (hc[1:0] == 2'd3) && (k == 3'd2);
assign fb_i.b_be   = 4'hF;
assign fb_i.b_din  = 32'd0;

//------------------------------------------------------- Mixer / palette ------------------------------------------------------//

// Everything for pixel hc is sampled at k = 1, the palette RAM is addressed at k = 2 and read at the pixel enable.
// Draw order (MAME screen_update): bg, sprites, fg; pen 0 transparent on sprites and fg.
// Palette: sprites 0x000 + colour * 16, fg 0x100 + colour * 16, bg 0x200 + colour * 16.
reg  [9:0] pal_idx;
wire [7:0] sp = fb_o.b_q[{hc[1:0], 3'b000} +: 8];
always_ff @(posedge clk) begin
    if (k == 3'd1) begin
        if      (fg_pen != 4'd0)    pal_idx <= {3'b010, fg_col, fg_pen};
        else if (sp[3:0] != 4'd0)   pal_idx <= {2'b00, sp};
        else                        pal_idx <= {2'b10, bg_color, bg_pix};
    end
end
assign pal_i.b_addr = {4'd0, pal_idx};

// BBGGRRII: each gun = {hi, lo, I1, I0} (MAME xxmissio_state::BBGGRRII).
wire [7:0] pq = pal_o.b_q[7:0];
wire [3:0] r4 = {pq[3:2], pq[1:0]};
wire [3:0] g4 = {pq[5:4], pq[1:0]};
wire [3:0] b4 = {pq[7:6], pq[1:0]};

always_ff @(posedge clk) begin
    if (ce12) begin
        R <= disp ? {r4, r4} : 8'd0;
        G <= disp ? {g4, g4} : 8'd0;
        B <= disp ? {b4, b4} : 8'd0;
        HBlank <= hblank;
        VBlank <= vblank;
        HSync  <= hsync;
        VSync  <= vsync;
    end
end

endmodule
