//============================================================================
//
//  UPLFramebuffer.sv — game top level: clocks, ROMs, the shared CPU / sound chip pool and the boards.
//  Copyright (C) 2026 Rodimus
//
//    60 / 10 = 6.0 MHz = XTAL 12 / 2 -> main Z80 + pixel clock
//    60 /  5 = 12  MHz = XTAL 12     -> xxmissio pixel clock (512 wide)
//    60 / 12 = 5.0 MHz = 5 MHz XTAL  -> sound Z80
//    60 / 40 = 1.5 MHz = XTAL 12 / 8 -> both YM2203
//
//============================================================================

module UPLFramebuffer
(
    input                reset,
    input                por_reset,     // power-on only; never includes ioctl_download
    input                clk_60m,

    // ---- controls, assembled into MAME port order by the wrapper (active low)
    input          [7:0] keycoin,
    input          [7:0] pad1,
    input          [7:0] pad2,
    input          [7:0] dsw1,
    input          [7:0] dsw2,

    // ---- video
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,
    output               ce_pix,
    output         [7:0] video_r, video_g, video_b,

    // ---- audio
    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ---- ROM download
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,
    input                ioctl_download,
    output               ioctl_wait,

    output         [7:0] set_id,

    input                crt_flip,
    input  signed  [3:0] h_adj,          // CRT position: sync moved 2 px per step (+ = picture right)
    input  signed  [3:0] v_adj,          //               sync moved 1 line per step (+ = picture down)
    input                pause,

    input                rd_auto,        // 1 = use the measured SDRAM read latch
    input          [1:0] rd_mode,        // manual override / fallback: 0=Early 1=Normal 2=Late
    input                rd_recal,       // pulse: SDRAM clock phase moved, re-measure the latch
    input                ph_auto,        // phase calibration enabled (OSD Auto)
    input                ld_hold,        // status[0], held across the MRA load
    output         [6:0] ph_req_val,     // requested DPS position
    output               ph_req_tgl,     // request strobe (toggle); rd_recal is the ack
    output               cal_hold,       // hold the game in reset while calibrating

    // ---- SDRAM
    inout  [15:0] SDRAM_DQ,
    output [12:0] SDRAM_A,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output  [1:0] SDRAM_BA,
    output        SDRAM_nCS,
    output        SDRAM_nWE,
    output        SDRAM_nRAS,
    output        SDRAM_nCAS,
    output        SDRAM_CKE,
    output        SDRAM_CLK
);

//------------------------------------------------------- Clock enables -------------------------------------------------------//

// All four rates are exact integer divides of the 60 MHz fabric - no fractional
// cen, no jitter. div4 advances once per cen_cpu pulse, so cen_ym is 6/4 MHz.
reg [3:0] div10 = 4'd0;   // mod-10 -> 6 MHz
reg [3:0] div12 = 4'd0;   // mod-12 -> 5 MHz
reg [1:0] div4  = 2'd0;   // mod-4 of the 6 MHz tick -> 1.5 MHz

always_ff @(posedge clk_60m) begin
    div10 <= (div10 == 4'd9)  ? 4'd0 : div10 + 4'd1;
    div12 <= (div12 == 4'd11) ? 4'd0 : div12 + 4'd1;
    if (div10 == 4'd9) div4 <= (div4 == 2'd3) ? 2'd0 : div4 + 2'd1;
end

wire cen_cpu = (div10 == 4'd0);                    // 6.0 MHz  main Z80
wire cen_pix = (div10 == 4'd0);                    // 6.0 MHz  pixel clock
wire cen_snd = (div12 == 4'd0);                    // 5.0 MHz  sound Z80
wire cen_ym  = (div10 == 4'd0) && (div4 == 2'd0);  // 1.5 MHz  both YM2203

// xxmissio (set_id 0x1A) shifts 512 pixels per line: 12 MHz, both phases of div10.
wire is_xx = (set_id == 8'h1A);
assign ce_pix = is_xx ? ((div10 == 4'd0) || (div10 == 4'd5)) : cen_pix;

//------------------------------------------------------- ROM regions ---------------------------------------------------------//

wire [15:0] maincpu_addr;   wire [3:0] maincpu_bank;   wire [7:0] maincpu_data;
wire [15:0] nk_maincpu_addr, nv_maincpu_addr, xx_maincpu_addr;
wire [17:0] nv_gfx_addr, xx_gfx_addr;  wire [7:0] gfx_data;

// Board select from the MRA's set id: 0x00-0x0F ninjakd2.cpp, 0x10-0x19 nova2001.cpp (0x10-0x12 Nova 2001,
// 0x13-0x15 Penguin-Kun Wars, 0x16 Ninjakun, 0x17-0x19 Raiders5), 0x1A xxmissio.cpp. The unselected boards are held
// in reset.
wire       is_nova    = (set_id >= 8'h10) && (set_id <= 8'h19);
wire [1:0] nv_variant = (set_id <= 8'h12) ? 2'd0 : (set_id <= 8'h15) ? 2'd1 : (set_id == 8'h16) ? 2'd2 : 2'd3;
assign maincpu_addr  = is_xx ? xx_maincpu_addr : is_nova ? nv_maincpu_addr : nk_maincpu_addr;
// pkunwar's E000-FFFF ROM and the XX Mission sub CPU's 0000-3FFF sit in the sound CPU ROM BRAM (MRA index 1).
assign audiocpu_addr = is_xx ? xx_aux_addr : is_nova ? nv_aux_addr : nk_audiocpu_addr;
assign audiocpu_m1   = (is_nova | is_xx) ? 1'b0 : nk_audiocpu_m1;
wire [15:0] audiocpu_addr;  wire audiocpu_m1;          wire [7:0] audiocpu_data;
wire [15:0] nk_audiocpu_addr, nv_aux_addr, xx_aux_addr; wire nk_audiocpu_m1;
wire [14:0] char_addr;      wire char_req, char_ack;   wire [7:0] char_data;
wire [18:0] tile1_addr;     wire tile1_req, tile1_ack; wire [7:0] tile1_data;
wire [18:0] nk_tile1_addr, xx_tile1_addr;              wire nk_tile1_req, xx_tile1_req;
assign tile1_addr = is_xx ? xx_tile1_addr : nk_tile1_addr;     // XX Mission bg tiles
assign tile1_req  = is_xx ? xx_tile1_req  : nk_tile1_req;
wire [18:0] tile2_addr;     wire tile2_req, tile2_ack; wire [7:0] tile2_data;
wire [18:0] tile3_addr;     wire tile3_req, tile3_ack; wire [7:0] tile3_data;
wire [17:0] spr_addr;       wire spr_req, spr_ack;     wire [7:0] spr_data;
wire [15:0] pcm_addr;       wire pcm_req, pcm_ack;     wire [7:0] pcm_data;

upl_rom rom
(
    .clk(clk_60m),
    .por_reset(por_reset),
    .rd_auto(rd_auto),
    .rd_mode(rd_mode),
    .recal(rd_recal),
    .ph_auto(ph_auto),
    .ld_hold(ld_hold),
    .ph_req_val(ph_req_val),
    .ph_req_tgl(ph_req_tgl),
    .cal_hold(cal_hold),

    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),
    .ioctl_wait(ioctl_wait),

    .set_id(set_id),

    .maincpu_addr(maincpu_addr), .maincpu_bank(maincpu_bank), .maincpu_data(maincpu_data),
    .gfx_sel(is_nova | is_xx), .gfx_addr(is_xx ? xx_gfx_addr : nv_gfx_addr), .gfx_data(gfx_data),
    .audiocpu_addr(audiocpu_addr), .audiocpu_m1(audiocpu_m1), .audiocpu_data(audiocpu_data),

    .char_addr(char_addr),  .char_req(char_req),  .char_ack(char_ack),  .char_data(char_data),
    .spr_addr(spr_addr), .spr_req(spr_req), .spr_ack(spr_ack), .spr_data(spr_data),
    .tile1_addr(tile1_addr), .tile1_req(tile1_req), .tile1_ack(tile1_ack), .tile1_data(tile1_data),
    .tile2_addr(tile2_addr), .tile2_req(tile2_req), .tile2_ack(tile2_ack), .tile2_data(tile2_data),
    .tile3_addr(tile3_addr), .tile3_req(tile3_req), .tile3_ack(tile3_ack), .tile3_data(tile3_data),
    .pcm_addr(pcm_addr), .pcm_req(pcm_req), .pcm_ack(pcm_ack), .pcm_data(pcm_data),

    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);

//------------------------------------------------------- Shared chips --------------------------------------------------------//

// One instance per role (rtl/chip_pool_pkg.sv). The active board drives the *_i bus; *_o fans out to every board.

// z80r_0: ninjakd2 main, Nova 2001 main, XX Mission main
chip_pool_pkg::z80r_i_t nk_z80r_0_i, nv_z80r_0_i, xx_z80r_0_i, z80r_0_i;
chip_pool_pkg::z80_o_t  z80r_0_o;
assign z80r_0_i = is_xx ? xx_z80r_0_i : is_nova ? nv_z80r_0_i : nk_z80r_0_i;

wire [15:0] z80r_0_a;
wire  [7:0] z80r_0_do;
wire        z80r_0_m1_n, z80r_0_mreq_n, z80r_0_iorq_n, z80r_0_rd_n, z80r_0_wr_n, z80r_0_rfsh_n;

T80s z80r_0
(
    .RESET_n(z80r_0_i.reset_n), .CLK(clk_60m), .CEN(z80r_0_i.ce), .WAIT_n(1'b1),
    .INT_n(z80r_0_i.int_n), .NMI_n(z80r_0_i.nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .M1_n(z80r_0_m1_n), .MREQ_n(z80r_0_mreq_n), .IORQ_n(z80r_0_iorq_n), .RD_n(z80r_0_rd_n),
    .WR_n(z80r_0_wr_n), .RFSH_n(z80r_0_rfsh_n), .HALT_n(), .BUSAK_n(),
    .A(z80r_0_a), .DI(z80r_0_i.di), .DO(z80r_0_do)
);

assign z80r_0_o.a = z80r_0_a;           assign z80r_0_o.dout = z80r_0_do;
assign z80r_0_o.m1_n = z80r_0_m1_n;     assign z80r_0_o.mreq_n = z80r_0_mreq_n; assign z80r_0_o.iorq_n = z80r_0_iorq_n;
assign z80r_0_o.rd_n = z80r_0_rd_n;     assign z80r_0_o.wr_n = z80r_0_wr_n;     assign z80r_0_o.rfsh_n = z80r_0_rfsh_n;

// z80r_1: ninjakd2 sound, Ninjakun / Raiders5 second CPU, XX Mission sub
chip_pool_pkg::z80r_i_t nk_z80r_1_i, nv_z80r_1_i, xx_z80r_1_i, z80r_1_i;
chip_pool_pkg::z80_o_t  z80r_1_o;
assign z80r_1_i = is_xx ? xx_z80r_1_i : is_nova ? nv_z80r_1_i : nk_z80r_1_i;

wire [15:0] z80r_1_a;
wire  [7:0] z80r_1_do;
wire        z80r_1_m1_n, z80r_1_mreq_n, z80r_1_iorq_n, z80r_1_rd_n, z80r_1_wr_n, z80r_1_rfsh_n;

T80s z80r_1
(
    .RESET_n(z80r_1_i.reset_n), .CLK(clk_60m), .CEN(z80r_1_i.ce), .WAIT_n(1'b1),
    .INT_n(z80r_1_i.int_n), .NMI_n(z80r_1_i.nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .M1_n(z80r_1_m1_n), .MREQ_n(z80r_1_mreq_n), .IORQ_n(z80r_1_iorq_n), .RD_n(z80r_1_rd_n),
    .WR_n(z80r_1_wr_n), .RFSH_n(z80r_1_rfsh_n), .HALT_n(), .BUSAK_n(),
    .A(z80r_1_a), .DI(z80r_1_i.di), .DO(z80r_1_do)
);

assign z80r_1_o.a = z80r_1_a;           assign z80r_1_o.dout = z80r_1_do;
assign z80r_1_o.m1_n = z80r_1_m1_n;     assign z80r_1_o.mreq_n = z80r_1_mreq_n; assign z80r_1_o.iorq_n = z80r_1_iorq_n;
assign z80r_1_o.rd_n = z80r_1_rd_n;     assign z80r_1_o.wr_n = z80r_1_wr_n;     assign z80r_1_o.rfsh_n = z80r_1_rfsh_n;

// ym2203 0-1: ninjakd2 sound board, Nova 2001 AY-3-8910 pair (SSG only), XX Mission (FM)
chip_pool_pkg::ym2203_i_t [1:0] nk_ym2203_i, nv_ym2203_i, xx_ym2203_i, ym2203_i;
chip_pool_pkg::ym2203_o_t [1:0] ym2203_o;
assign ym2203_i = is_xx ? xx_ym2203_i : is_nova ? nv_ym2203_i : nk_ym2203_i;

genvar yi;
generate
    for (yi = 0; yi < 2; yi = yi + 1) begin : ym
        wire signed [15:0] snd;
        wire         [9:0] psg_snd;
        wire         [7:0] dout, ioa_out, iob_out;
        wire               irq_n, ioa_oe, iob_oe;

        jt03 ym2203
        (
            .rst    (ym2203_i[yi].rst),
            .clk    (clk_60m),
            .cen    (ym2203_i[yi].ce),
            .din    (ym2203_i[yi].din),
            .addr   (ym2203_i[yi].addr),
            .cs_n   (ym2203_i[yi].cs_n),
            .wr_n   (ym2203_i[yi].wr_n),
            .dout   (dout),
            .irq_n  (irq_n),
            .IOA_in (ym2203_i[yi].ioa_in),
            .IOB_in (ym2203_i[yi].iob_in),
            .IOA_out(ioa_out), .IOB_out(iob_out), .IOA_oe(ioa_oe), .IOB_oe(iob_oe),
            .psg_A  (), .psg_B  (), .psg_C  (),
            .fm_snd (), .psg_snd(psg_snd),
            .snd    (snd),
            .snd_sample(),
            .debug_view()
        );

        assign ym2203_o[yi].dout    = dout;
        assign ym2203_o[yi].irq_n   = irq_n;
        assign ym2203_o[yi].ioa_out = ioa_out;
        assign ym2203_o[yi].iob_out = iob_out;
        assign ym2203_o[yi].ioa_oe  = ioa_oe;
        assign ym2203_o[yi].iob_oe  = iob_oe;
        assign ym2203_o[yi].psg_snd = psg_snd;
        assign ym2203_o[yi].snd     = snd;
    end
endgenerate

// Shared RAMs. Every dpram_dc in a board's video / work path that another board can reuse lives here.
//   ram2k_0  2K x 8    ninjakd2 fg VRAM                          Nova fg VRAM                  XX Mission fg VRAM
//   ram8k_0  8K x 8    ninjakd2 bg VRAM layer 0                  Nova bg VRAM                  XX Mission bg VRAM
//   ram8k_1  8K x 8    ninjakd2 bg VRAM layer 1                  Nova sprite RAM               XX Mission sprite RAM
//   ram8k_2  8K x 8    ninjakd2 bg VRAM layer 2                  Ninjakun / Raiders5 shared RAM 0x000, palette 0x800
//                                                                                              XX Mission palette RAM
//   ram8k_3  8K x 8    ninjakd2 work RAM incl. sprite list       Nova work RAM                 XX Mission work RAM x2
//   ram_fb   16K x 32  ninjakd2 sprite framebuffer (byteena)     Nova sprite framebuffer, one pixel per byte
//                                                                                              XX Mission sprite line buffers
chip_pool_pkg::dpram_i_t       nk_ram2k_0_i, nv_ram2k_0_i, xx_ram2k_0_i, ram2k_0_i;
chip_pool_pkg::dpram_o_t       ram2k_0_o;
chip_pool_pkg::dpram_i_t [3:0] nk_ram8k_i, ram8k_i;
chip_pool_pkg::dpram_i_t       nv_ram8k_0_i, nv_ram8k_1_i, nv_ram8k_2_i, nv_ram8k_3_i;
chip_pool_pkg::dpram_i_t       xx_ram8k_0_i, xx_ram8k_1_i, xx_ram8k_2_i, xx_ram8k_3_i;
chip_pool_pkg::dpram_o_t [3:0] ram8k_o;
chip_pool_pkg::dpram_i_t       nk_ram_fb_i, nv_ram_fb_i, xx_ram_fb_i, ram_fb_i;
chip_pool_pkg::dpram_o_t       ram_fb_o;
assign ram2k_0_i  = is_xx ? xx_ram2k_0_i : is_nova ? nv_ram2k_0_i : nk_ram2k_0_i;
assign ram8k_i[0] = is_xx ? xx_ram8k_0_i : is_nova ? nv_ram8k_0_i : nk_ram8k_i[0];
assign ram8k_i[1] = is_xx ? xx_ram8k_1_i : is_nova ? nv_ram8k_1_i : nk_ram8k_i[1];
assign ram8k_i[2] = is_xx ? xx_ram8k_2_i : is_nova ? nv_ram8k_2_i : nk_ram8k_i[2];
assign ram8k_i[3] = is_xx ? xx_ram8k_3_i : is_nova ? nv_ram8k_3_i : nk_ram8k_i[3];
assign ram_fb_i   = is_xx ? xx_ram_fb_i  : is_nova ? nv_ram_fb_i  : nk_ram_fb_i;

wire [7:0] ram2k_0_qa, ram2k_0_qb;

dpram_dc #(.widthad_a(11), .width_a(8)) ram2k_0
(
    .clock_a(clk_60m), .address_a(ram2k_0_i.a_addr[10:0]), .data_a(ram2k_0_i.a_din[7:0]),
    .wren_a(ram2k_0_i.a_we), .q_a(ram2k_0_qa),
    .clock_b(clk_60m), .address_b(ram2k_0_i.b_addr[10:0]), .data_b(ram2k_0_i.b_din[7:0]),
    .wren_b(ram2k_0_i.b_we), .q_b(ram2k_0_qb)
);

assign ram2k_0_o.a_q = {24'd0, ram2k_0_qa};
assign ram2k_0_o.b_q = {24'd0, ram2k_0_qb};

genvar ri;
generate
    for (ri = 0; ri < 4; ri = ri + 1) begin : r8k
        wire [7:0] qa, qb;

        dpram_dc #(.widthad_a(13), .width_a(8)) ram8k
        (
            .clock_a(clk_60m), .address_a(ram8k_i[ri].a_addr[12:0]), .data_a(ram8k_i[ri].a_din[7:0]),
            .wren_a(ram8k_i[ri].a_we), .q_a(qa),
            .clock_b(clk_60m), .address_b(ram8k_i[ri].b_addr[12:0]), .data_b(ram8k_i[ri].b_din[7:0]),
            .wren_b(ram8k_i[ri].b_we), .q_b(qb)
        );

        assign ram8k_o[ri].a_q = {24'd0, qa};
        assign ram8k_o[ri].b_q = {24'd0, qb};
    end
endgenerate

wire [31:0] ram_fb_qa, ram_fb_qb;

dpram_dc #(.widthad_a(14), .width_a(32)) ram_fb
(
    .clock_a(clk_60m), .address_a(ram_fb_i.a_addr), .data_a(ram_fb_i.a_din),
    .wren_a(ram_fb_i.a_we), .byteena_a(ram_fb_i.a_be), .q_a(ram_fb_qa),
    .clock_b(clk_60m), .address_b(ram_fb_i.b_addr), .data_b(ram_fb_i.b_din),
    .wren_b(ram_fb_i.b_we), .byteena_b(ram_fb_i.b_be), .q_b(ram_fb_qb)
);

assign ram_fb_o.a_q = ram_fb_qa;
assign ram_fb_o.b_q = ram_fb_qb;

//------------------------------------------------------- Boards --------------------------------------------------------------//

wire signed [15:0] nk_sound, nv_sound, xx_sound;
wire        nk_hsync, nk_vsync, nk_hblank, nk_vblank, nv_hsync, nv_vsync, nv_hblank, nv_vblank;
wire        xx_hsync, xx_vsync, xx_hblank, xx_vblank;
wire  [7:0] nk_r, nk_g, nk_b, nv_r, nv_g, nv_b, xx_r, xx_g, xx_b;

ninjakd2_board ninjakd2_b
(
    .clk(clk_60m),
    .cen_cpu(cen_cpu), .cen_pix(cen_pix), .cen_snd(cen_snd), .cen_ym(cen_ym),
    .reset(reset | is_nova | is_xx),
    .pause(pause),

    .set_id(set_id),

    .keycoin(keycoin), .pad1(pad1), .pad2(pad2), .dsw1(dsw1), .dsw2(dsw2),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),

    .maincpu_addr(nk_maincpu_addr), .maincpu_bank(maincpu_bank), .maincpu_data(maincpu_data),
    .audiocpu_addr(nk_audiocpu_addr), .audiocpu_m1(nk_audiocpu_m1), .audiocpu_data(audiocpu_data),
    .char_addr(char_addr),  .char_req(char_req),  .char_ack(char_ack),  .char_data(char_data),
    .tile1_addr(nk_tile1_addr), .tile1_req(nk_tile1_req), .tile1_ack(tile1_ack), .tile1_data(tile1_data),
    .tile2_addr(tile2_addr), .tile2_req(tile2_req), .tile2_ack(tile2_ack), .tile2_data(tile2_data),
    .tile3_addr(tile3_addr), .tile3_req(tile3_req), .tile3_ack(tile3_ack), .tile3_data(tile3_data),
    .spr_addr(spr_addr), .spr_req(spr_req), .spr_ack(spr_ack), .spr_data(spr_data),
    .pcm_addr(pcm_addr), .pcm_req(pcm_req), .pcm_ack(pcm_ack), .pcm_data(pcm_data),

    .HSync(nk_hsync), .VSync(nk_vsync),
    .HBlank(nk_hblank), .VBlank(nk_vblank),
    .R(nk_r), .G(nk_g), .B(nk_b),
    .sound(nk_sound),

    .z80r_0_i(nk_z80r_0_i), .z80r_0_o(z80r_0_o),
    .z80r_1_i(nk_z80r_1_i), .z80r_1_o(z80r_1_o),
    .ym2203_i(nk_ym2203_i), .ym2203_o(ym2203_o),
    .ram2k_0_i(nk_ram2k_0_i), .ram2k_0_o(ram2k_0_o),
    .ram8k_i(nk_ram8k_i), .ram8k_o(ram8k_o),
    .ram_fb_i(nk_ram_fb_i), .ram_fb_o(ram_fb_o)
);

nova2001_board nova2001_b
(
    .clk(clk_60m),
    .pix_ph(div10),
    .reset(reset | ~is_nova),
    .pause(pause),
    .variant(nv_variant),

    .keycoin(keycoin), .pad1(pad1), .pad2(pad2), .dsw1(dsw1), .dsw2(dsw2),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),

    .maincpu_addr(nv_maincpu_addr), .maincpu_data(maincpu_data),
    .aux_addr(nv_aux_addr), .aux_data(audiocpu_data),
    .gfx_addr(nv_gfx_addr), .gfx_data(gfx_data),

    .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr), .ioctl_data(ioctl_data),

    .HSync(nv_hsync), .VSync(nv_vsync),
    .HBlank(nv_hblank), .VBlank(nv_vblank),
    .R(nv_r), .G(nv_g), .B(nv_b),
    .sound(nv_sound),

    .z80_i(nv_z80r_0_i), .z80_o(z80r_0_o),
    .z80b_i(nv_z80r_1_i), .z80b_o(z80r_1_o),
    .ym_i(nv_ym2203_i), .ym_o(ym2203_o),
    .fg_i(nv_ram2k_0_i), .fg_o(ram2k_0_o),
    .bg_i(nv_ram8k_0_i), .bg_o(ram8k_o[0]),
    .spr_i(nv_ram8k_1_i), .spr_o(ram8k_o[1]),
    .sh_i(nv_ram8k_2_i), .sh_o(ram8k_o[2]),
    .work_i(nv_ram8k_3_i), .work_o(ram8k_o[3]),
    .fb_i(nv_ram_fb_i), .fb_o(ram_fb_o)
);

xxmissio_board xxmissio_b
(
    .clk(clk_60m),
    .pix_ph(div10),
    .cen_ym(cen_ym),
    .reset(reset | ~is_xx),
    .pause(pause),

    .keycoin(keycoin), .pad1(pad1), .pad2(pad2), .dsw1(dsw1), .dsw2(dsw2),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),

    .maincpu_addr(xx_maincpu_addr), .maincpu_data(maincpu_data),
    .aux_addr(xx_aux_addr), .aux_data(audiocpu_data),
    .gfx_addr(xx_gfx_addr), .gfx_data(gfx_data),
    .tile_addr(xx_tile1_addr), .tile_req(xx_tile1_req), .tile_ack(tile1_ack), .tile_data(tile1_data),

    .HSync(xx_hsync), .VSync(xx_vsync),
    .HBlank(xx_hblank), .VBlank(xx_vblank),
    .R(xx_r), .G(xx_g), .B(xx_b),
    .sound(xx_sound),

    .z80_i(xx_z80r_0_i), .z80_o(z80r_0_o),
    .z80b_i(xx_z80r_1_i), .z80b_o(z80r_1_o),
    .ym_i(xx_ym2203_i), .ym_o(ym2203_o),
    .fg_i(xx_ram2k_0_i), .fg_o(ram2k_0_o),
    .bg_i(xx_ram8k_0_i), .bg_o(ram8k_o[0]),
    .spr_i(xx_ram8k_1_i), .spr_o(ram8k_o[1]),
    .pal_i(xx_ram8k_2_i), .pal_o(ram8k_o[2]),
    .work_i(xx_ram8k_3_i), .work_o(ram8k_o[3]),
    .fb_i(xx_ram_fb_i), .fb_o(ram_fb_o)
);

assign video_hsync  = is_xx ? xx_hsync  : is_nova ? nv_hsync  : nk_hsync;
assign video_vsync  = is_xx ? xx_vsync  : is_nova ? nv_vsync  : nk_vsync;
assign video_hblank = is_xx ? xx_hblank : is_nova ? nv_hblank : nk_hblank;
assign video_vblank = is_xx ? xx_vblank : is_nova ? nv_vblank : nk_vblank;
assign video_r      = is_xx ? xx_r      : is_nova ? nv_r      : nk_r;
assign video_g      = is_xx ? xx_g      : is_nova ? nv_g      : nk_g;
assign video_b      = is_xx ? xx_b      : is_nova ? nv_b      : nk_b;
assign sound_l      = is_xx ? xx_sound  : is_nova ? nv_sound  : nk_sound;
assign sound_r      = is_xx ? xx_sound  : is_nova ? nv_sound  : nk_sound;

endmodule
