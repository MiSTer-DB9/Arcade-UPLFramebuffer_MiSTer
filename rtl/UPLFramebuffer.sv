//============================================================================
//
//  UPLFramebuffer.sv — game top level: clocks, ROMs, the shared CPU / sound chip pool and the boards.
//  Copyright (C) 2026 Rodimus
//
//    60 / 10 = 6.0 MHz = XTAL 12 / 2 -> main Z80 + pixel clock
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

assign ce_pix = cen_pix;

//------------------------------------------------------- ROM regions ---------------------------------------------------------//

wire [15:0] maincpu_addr;   wire [3:0] maincpu_bank;   wire [7:0] maincpu_data;
wire [15:0] audiocpu_addr;  wire audiocpu_m1;          wire [7:0] audiocpu_data;
wire [14:0] char_addr;      wire char_req, char_ack;   wire [7:0] char_data;
wire [18:0] tile1_addr;     wire tile1_req, tile1_ack; wire [7:0] tile1_data;
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

// z80r_0: ninjakd2 main
chip_pool_pkg::z80r_i_t nk_z80r_0_i, z80r_0_i;
chip_pool_pkg::z80_o_t  z80r_0_o;
assign z80r_0_i = nk_z80r_0_i;

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

// z80r_1: ninjakd2 sound
chip_pool_pkg::z80r_i_t nk_z80r_1_i, z80r_1_i;
chip_pool_pkg::z80_o_t  z80r_1_o;
assign z80r_1_i = nk_z80r_1_i;

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

// ym2203 0-1: ninjakd2 sound board
chip_pool_pkg::ym2203_i_t [1:0] nk_ym2203_i, ym2203_i;
chip_pool_pkg::ym2203_o_t [1:0] ym2203_o;
assign ym2203_i = nk_ym2203_i;

genvar yi;
generate
    for (yi = 0; yi < 2; yi = yi + 1) begin : ym
        wire signed [15:0] snd;
        wire         [9:0] psg_snd;
        wire         [7:0] dout, ioa_out, iob_out;
        wire               irq_n;

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
            .IOA_out(ioa_out), .IOB_out(iob_out), .IOA_oe(), .IOB_oe(),
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
        assign ym2203_o[yi].psg_snd = psg_snd;
        assign ym2203_o[yi].snd     = snd;
    end
endgenerate

//------------------------------------------------------- Boards --------------------------------------------------------------//

wire signed [15:0] nk_sound;

ninjakd2_board ninjakd2_b
(
    .clk(clk_60m),
    .cen_cpu(cen_cpu), .cen_pix(cen_pix), .cen_snd(cen_snd), .cen_ym(cen_ym),
    .reset(reset),
    .pause(pause),

    .set_id(set_id),

    .keycoin(keycoin), .pad1(pad1), .pad2(pad2), .dsw1(dsw1), .dsw2(dsw2),
    .crt_flip(crt_flip),

    .maincpu_addr(maincpu_addr), .maincpu_bank(maincpu_bank), .maincpu_data(maincpu_data),
    .audiocpu_addr(audiocpu_addr), .audiocpu_m1(audiocpu_m1), .audiocpu_data(audiocpu_data),
    .char_addr(char_addr),  .char_req(char_req),  .char_ack(char_ack),  .char_data(char_data),
    .tile1_addr(tile1_addr), .tile1_req(tile1_req), .tile1_ack(tile1_ack), .tile1_data(tile1_data),
    .tile2_addr(tile2_addr), .tile2_req(tile2_req), .tile2_ack(tile2_ack), .tile2_data(tile2_data),
    .tile3_addr(tile3_addr), .tile3_req(tile3_req), .tile3_ack(tile3_ack), .tile3_data(tile3_data),
    .spr_addr(spr_addr), .spr_req(spr_req), .spr_ack(spr_ack), .spr_data(spr_data),
    .pcm_addr(pcm_addr), .pcm_req(pcm_req), .pcm_ack(pcm_ack), .pcm_data(pcm_data),

    .HSync(video_hsync), .VSync(video_vsync),
    .HBlank(video_hblank), .VBlank(video_vblank),
    .R(video_r), .G(video_g), .B(video_b),
    .sound(nk_sound),

    .z80r_0_i(nk_z80r_0_i), .z80r_0_o(z80r_0_o),
    .z80r_1_i(nk_z80r_1_i), .z80r_1_o(z80r_1_o),
    .ym2203_i(nk_ym2203_i), .ym2203_o(ym2203_o)
);

assign sound_l = nk_sound;
assign sound_r = nk_sound;

endmodule
