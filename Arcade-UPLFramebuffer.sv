//============================================================================
//
// UPLFramebuffer for MiSTer
// Copyright (C) 2026 Rodimus
// Based on Tutankham core structure
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: USER_OSD + per-pin push-pull mask, USER_IO widened to 8 bits
	output        USER_OSD,
	output  [7:0] USER_PP,
	input   [7:0] USER_IN,
	output  [7:0] USER_OUT,
	// [MiSTer-DB9 END]

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: USER_PP driven by wrapper; USER_OUT driven by joydb (USER_OUT_DRIVE) below
assign USER_PP = USER_PP_DRIVE;
// [MiSTer-DB9 END]
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// SDRAM pins are driven by the controller inside upl_rom - tie-off removed.

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio_l, audio_r;
assign AUDIO_L = pause_cpu ? 16'd0 : audio_l;
assign AUDIO_R = pause_cpu ? 16'd0 : audio_r;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0; // no mix, true stereo

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

///////////////////////////////////////////////////

wire [1:0] ar = status[14:13];

// set_id: MRA index 5, captured inside upl_rom and exposed by the game top.
//   0x00-0x0C ninjakd2 / mnight / arkarea / robokid (ROT0)   0x0D-0x0F omegaf (ROT270)
//   0x10-0x19 nova2001.cpp (ROT0)                             0x1A xxmissio (ROT90)
wire [7:0] set_id;
wire is_xx       = (set_id == 8'h1A);
wire is_vertical = ((set_id >= 8'h0D) && (set_id <= 8'h0F)) | is_xx;

// Aspect keys off the same split as screen_rotate, so the two can never disagree.
wire horz = ~is_vertical | status[12];

assign VIDEO_ARX = horz ? ((!ar) ? 12'd4 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = horz ? ((!ar) ? 12'd3 : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"UPLFRAMEBUFFER;;",
	"P1,Video Options;",
	"P1ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[35:32],H Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[39:36],V Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"P2,Pause Options;",
	"P2OP,Pause when OSD is open,On,Off;",
	"P2OQ,Dim video after 10s,On,Off;",
	"-;",
	"P3,High Score Options;",
	"P3OR,Autosave Hiscores,Off,On;",
	"-;",
	"OJL,SDRAM Rd Latch,Auto,Normal,Early,Late,Later;",
	"OSV,SDRAM Clk Phase,Auto,0.0ns,1.0ns,2.1ns,3.1ns,4.2ns,5.2ns,6.3ns,7.3ns,8.3ns,9.4ns,10.4ns,11.5ns,12.5ns,13.5ns,14.6ns;",
	"-;",
	// [MiSTer-DB9-Pro BEGIN] - Saturn-first joy_type (canonical bit notation)
	"O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"O[125],UserIO Players, 1 Player,2 Players;",
	// [MiSTer-DB9-Pro END]
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Attack,Jump,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire        ioctl_wait;

wire [15:0] joystick_0, joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joydb wrapper
wire         CLK_JOY = CLK_50M;                 // Assign clock between 40-50Mhz
wire   [1:0] joy_type_raw    = status[127:126]; // 0=Off, 1=Saturn, 2=DB9MD, 3=DB15
wire         joy_2p          = status[125];
// SNAC cores: replace 1'b0 with the core's SNAC enable expression so SNAC
// preempts the joydb wrapper on shared USER_IO pins. Default 1'b0 is no-op.
wire         snac_active     = 1'b0;
// MT32-pi cores on primary USER_IO: replace 1'b0 with the core's MT32-active
// expression (e.g. `mt32_use` under `ifndef SECOND_MT32`, `~mt32_disable` for
// TRS-80's inverted polarity). Suppresses the OSD-open autodetect probe so it
// doesn't read the RPi's I2C master traffic as a ghost Saturn signature.
wire         mt32_primary_active = 1'b0;
wire   [1:0] joy_type        = snac_active ? 2'd0 : joy_type_raw;
wire         joy_db9md_en    = (joy_type == 2'd2);
wire         joy_db15_en     = (joy_type == 2'd3);
wire         joy_any_en      = |joy_type;
// [MiSTer-DB9 END]

// [MiSTer-DB9-Pro BEGIN] - Saturn key gate
wire         saturn_unlocked;                   // driven by hps_io UIO_DB9_KEY (0xFE)
// [MiSTer-DB9-Pro END]

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joydb wrapper wires + instance
wire   [7:0] USER_OUT_DRIVE;
wire   [7:0] USER_PP_DRIVE;
wire  [15:0] joydb_1, joydb_2;
wire         joydb_1ena, joydb_2ena;
wire  [15:0] joy_raw_payload;
// Programmable-remap matrix (joydb_remap inside joydb): clk_sys carries the
// 0xFD selector load (HPS-bus domain). joydb_*_mapped are the MiSTer-standard
// joystick words the core consumes at its joy0_USB merge point. db9_remap_*
// are driven by the hps_io instance (see the .db9_remap_* bindings there).
// Until a core consumes joydb_*_mapped (Layer B), the matrix stays at identity
// and synthesis prunes it -- binding these is dormant + fleet-safe.
wire  [15:0] joydb_1_mapped, joydb_2_mapped;
wire         db9_remap_cmd;
wire   [5:0] db9_remap_byte_cnt;
wire  [15:0] db9_remap_din;

// [MiSTer-DB9 BEGIN] - DB9 remap factory default (used until Main_MiSTer streams UIO 0xFD)
// Derived from CONF_STR J1, same rule as db9_map.cpp; lets the core work on a stock MiSTer binary.
// DB15:  Attack=A, Jump=B, Coin=SELECT, Start 1P=START, Start 2P=D, Pause=E
// DB9MD: Attack=B, Jump=C, Coin=MODE, Start 1P=START, Start 2P=X, Pause=Y
wire  [35:0] db9_remap_default_db15  = 36'hFFF87AB54;
wire  [35:0] db9_remap_default_db9md = 36'hFFF87AB65;
// [MiSTer-DB9 END]
joydb joydb (
  .clk             ( CLK_JOY         ),
  .clk_sys         ( CLK_60M            ),
  .USER_IN         ( USER_IN         ),
  .OSD_STATUS          ( OSD_STATUS          ),
  .snac_active         ( snac_active         ),
  .mt32_primary_active ( mt32_primary_active ),
  .joy_type        ( joy_type        ),
  .joy_2p          ( joy_2p          ),
  .saturn_unlocked ( saturn_unlocked ),
  .USER_OUT_DRIVE  ( USER_OUT_DRIVE  ),
  .USER_PP_DRIVE   ( USER_PP_DRIVE   ),
  .USER_OSD        ( USER_OSD        ),
  .joydb_1         ( joydb_1         ),
  .joydb_2         ( joydb_2         ),
  .joydb_1ena      ( joydb_1ena      ),
  .joydb_2ena      ( joydb_2ena      ),
  .remap_cmd       ( db9_remap_cmd      ),
  .remap_byte_cnt  ( db9_remap_byte_cnt ),
  .remap_din       ( db9_remap_din      ),
  .remap_default_db15  ( db9_remap_default_db15  ),
  .remap_default_db9md ( db9_remap_default_db9md ),
  .joydb_1_mapped  ( joydb_1_mapped     ),
  .joydb_2_mapped  ( joydb_2_mapped     ),
  .joy_raw         ( joy_raw_payload )
);

assign USER_OUT = USER_OUT_DRIVE;
// [MiSTer-DB9 END]

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: rename USB joystick wires
wire [31:0] joystick_0_USB, joystick_1_USB;
// [MiSTer-DB9 END]

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_60M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0_USB),
	.joystick_1(joystick_1_USB),
	.ps2_key(ps2_key),
	// [MiSTer-DB9 BEGIN] - DB9/SNAC8 support: joy_raw
	.joy_raw(joy_raw_payload),
	// programmable remap matrix selector load (UIO_DB9_MAP 0xFD)
	.db9_remap_cmd(db9_remap_cmd),
	.db9_remap_byte_cnt(db9_remap_byte_cnt),
	.db9_remap_din(db9_remap_din),
	// [MiSTer-DB9 END]
	// [MiSTer-DB9-Pro BEGIN] - Saturn key gate
	.saturn_unlocked(saturn_unlocked)
	// [MiSTer-DB9-Pro END]
);

// [MiSTer-DB9-Pro BEGIN] - DB controllers muted while OSD is open
// joydb_*_mapped is already in MiSTer-standard J1 order, identical to the USB
// joystick word, so it replaces the USB input as-is.
assign joystick_0 = joydb_1ena ? (OSD_STATUS ? 16'b0 : joydb_1_mapped) : joystick_0_USB;
assign joystick_1 = joydb_2ena ? (OSD_STATUS ? 16'b0 : joydb_2_mapped) : joydb_1ena ? joystick_0_USB : joystick_1_USB;
// [MiSTer-DB9-Pro END]

////////////////////   CLOCKS   ///////////////////
//   Fabric 60.000 MHz = 50 MHz refclk x 12/10 (integer PLL: M=12, N=1, C=10).
//     60 / 10 = 6.0 MHz = XTAL 12 / 2 -> main Z80 + pixel clock
//     60 / 12 = 5.0 MHz = 5 MHz XTAL  -> sound Z80
//     60 / 40 = 1.5 MHz = XTAL 12 / 8 -> both YM2203
wire CLK_60M;
wire locked;

wire        CLK_SDRAM;           // 60 MHz, same as CLK_60M at phase step 0
wire [63:0] reconfig_to_pll, reconfig_from_pll;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_60M),
    .outclk_1(CLK_SDRAM),
    .locked(locked),
    .reconfig_to_pll(reconfig_to_pll),
    .reconfig_from_pll(reconfig_from_pll)
);

// SDRAM clock phase. One DPS step = 1/8 VCO period = 208 ps (600 MHz VCO), 80 per
// 60 MHz period; each manual OSD step is 5. Position 0 reproduces the old fixed clock.
// OSD Auto: upl_rom sweeps all 80 after each ROM load and requests the centre of the
// widest clean window; each request is acked by flipping ph_tgl, moved or not.
wire        cfg_waitrequest;
reg         cfg_write = 1'b0;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
    .mgmt_clk(CLK_50M),
    .mgmt_reset(1'b0),
    .mgmt_waitrequest(cfg_waitrequest),
    .mgmt_read(1'b0),
    .mgmt_readdata(),
    .mgmt_write(cfg_write),
    .mgmt_address(cfg_address),
    .mgmt_writedata(cfg_data),
    .reconfig_to_pll(reconfig_to_pll),
    .reconfig_from_pll(reconfig_from_pll)
);

reg   [3:0] ph_s1 = 4'd0, ph_s2 = 4'd0;
reg   [6:0] ph_cur = 7'd0, ph_tgt = 7'd0;
reg   [2:0] ph_st = 3'd0;
reg   [3:0] ph_dly = 4'd0;
reg         ph_tgl = 1'b0;      // flips once per completed phase move
wire        ph_auto = (status[31:28] == 4'd0);
wire  [6:0] cal_ph;
wire        cal_tgl, cal_hold;
reg   [2:0] rq_s = 3'd0;
reg         rq_pend = 1'b0;
reg   [6:0] rq_val = 7'd0;
wire        ph_auto50 = (ph_s2 == 4'd0);
wire  [3:0] ph_km1 = ph_s2 - 4'd1;
wire  [6:0] man_want = {1'b0, ph_km1, 2'b00} + {3'd0, ph_km1};
wire  [6:0] ph_want = ph_auto50 ? rq_val : man_want;
wire        ph_go   = ph_auto50 ? rq_pend : (man_want != ph_cur);

always @(posedge CLK_50M) begin
    ph_s1 <= status[31:28];
    ph_s2 <= ph_s1;
    if (cfg_write) begin
        if (!cfg_waitrequest) cfg_write <= 1'b0;   // held until accepted
    end else begin
        case (ph_st)
            3'd0: if (!cfg_waitrequest && ph_go) begin
                if (ph_auto50) rq_pend <= 1'b0;
                if (ph_want == ph_cur) ph_tgl <= ~ph_tgl;   // already there: ack only
                else begin
                    ph_tgt <= ph_want;
                    cfg_address <= 6'd0; cfg_data <= 32'd0; cfg_write <= 1'b1;   // waitrequest mode
                    ph_st <= 3'd1;
                end
            end
            3'd1: begin   // DPS: [15:0] shifts, [20:16] counter C1, [21] up
                cfg_address <= 6'd6;
                cfg_data    <= (ph_tgt > ph_cur) ? {10'd0, 1'b1, 5'd1, 9'd0, ph_tgt - ph_cur}
                                                 : {10'd0, 1'b0, 5'd1, 9'd0, ph_cur - ph_tgt};
                cfg_write   <= 1'b1;
                ph_st <= 3'd2;
            end
            3'd2: begin
                cfg_address <= 6'd2; cfg_data <= 32'd0; cfg_write <= 1'b1;   // start
                ph_dly <= 4'd0;
                ph_st <= 3'd3;
            end
            3'd3: begin   // give waitrequest time to rise before trusting it low
                ph_dly <= ph_dly + 4'd1;
                if (&ph_dly) ph_st <= 3'd4;
            end
            3'd4: if (!cfg_waitrequest) begin
                ph_cur <= ph_tgt;
                ph_tgl <= ~ph_tgl;
                ph_st  <= 3'd0;
            end
            default: ph_st <= 3'd0;
        endcase
    end
    // Calibration request from the SDRAM domain; cal_ph is stable before the toggle.
    rq_s <= {rq_s[1:0], cal_tgl};
    if (rq_s[2] ^ rq_s[1]) begin rq_pend <= 1'b1; rq_val <= cal_ph; end
end

// Phase moved: re-measure the read latch in the SDRAM domain.
reg [2:0] ph_tgl_s = 3'd0;
always @(posedge CLK_60M) ph_tgl_s <= {ph_tgl_s[1:0], ph_tgl};
wire rd_recal = ph_tgl_s[2] ^ ph_tgl_s[1];

assign CLK_VIDEO = CLK_60M;

// cal_hold keeps the game in reset through the phase sweep
wire reset = RESET | status[0] | buttons[1] | ioctl_download | cal_hold;

// SDRAM power-on reset. Must exclude ioctl_download: a reset including it holds the
// load FSM idle for the whole transfer and no byte lands. High ~15 cycles, then low.
reg  [3:0] por_cnt = 4'd0;
wire       por_reset = ~&por_cnt;
always @(posedge CLK_60M) if (por_reset) por_cnt <= por_cnt + 1'b1;

///////////////////         Keyboard           //////////////////

// CTL-2026-10-25: original keyboard block, replaced by ctl_keyboard below
// reg btn_up       = 0;
// reg btn_down     = 0;
// reg btn_left     = 0;
// reg btn_right    = 0;
// reg btn_attack   = 0;
// reg btn_jump     = 0;
// reg btn_coin1    = 0;
// reg btn_coin2    = 0;
// reg btn_1p_start = 0;
// reg btn_2p_start = 0;
// reg btn_pause    = 0;
// reg btn_service  = 0;
//
// wire pressed = ~ps2_key[9];
// wire [7:0] code = ps2_key[7:0];
// always @(posedge CLK_60M) begin
// 	reg old_state;
// 	old_state <= ps2_key[10];
// 	if(old_state != ps2_key[10]) begin
// 		case(code)
// 			'h16: btn_1p_start <= pressed; // 1 = Player 1 Start
// 			'h1E: btn_2p_start <= pressed; // 2 = Player 2 Start
// 			'h2E: btn_coin1    <= pressed; // 5 = Coin Input 1
// 			'h36: btn_coin2    <= pressed; // 6 = Coin Input 2
// 			'h4D: btn_pause    <= pressed; // P = Pause
// 			'h46: btn_service  <= pressed; // 9 = Test Advance
//
// 			'h75: btn_up       <= pressed; // up         = Up
// 			'h72: btn_down     <= pressed; // down       = Down
// 			'h6B: btn_left     <= pressed; // left       = Left
// 			'h74: btn_right    <= pressed; // right      = Right
// 			'h14: btn_attack   <= pressed; // ctrl       = Attack
// 			'h12: btn_jump     <= pressed; // left shift = Jump
// 		endcase 
// 	end
// end
// CTL-2026-10-25: keyboard -> controllers.sv ctl_keyboard. Keys now act on PRESS (the old `~ps2_key[9]` made them act
// on release and stay held). Extended bit ignored = STD_EXT 0, as before. Extra-key table: left Shift (0x12, level,
// either extended form) -> kbx[0] = Jump. No toggle keys, so pause changes nothing.
wire        pause_cpu;   // CTL-2026-10-25: declared here (was in PAUSE SYSTEM below) so ctl_keyboard can take it
wire [12:0] kb;
wire  [0:0] kbx;
ctl_keyboard #(.NX(1), .NXO(1), .XKEYS({24'h10_12_00})) keyboard
	(.clk(CLK_60M), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb), .kbx(kbx));
wire btn_up       = kb[0];    // up         = Up
wire btn_down     = kb[1];    // down       = Down
wire btn_left     = kb[2];    // left       = Left
wire btn_right    = kb[3];    // right      = Right
wire btn_attack   = kb[4];    // ctrl       = Attack
wire btn_jump     = kbx[0];   // left shift = Jump
wire btn_1p_start = kb[6];    // 1 = Player 1 Start
wire btn_2p_start = kb[7];    // 2 = Player 2 Start
wire btn_coin1    = kb[8];    // 5 = Coin Input 1
wire btn_coin2    = kb[9];    // 6 = Coin Input 2
wire btn_service  = kb[10];   // 9 = Test Advance
wire btn_pause    = kb[12];   // P = Pause

//////////////////  Game select (mod byte, MRA <rom index="5">)  ///////////////////////////

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

// Every UPL set here is 2-button (ninjakd2.cpp INPUT_PORTS common / common_2p).

//Player 1
wire m_up1      = btn_up        | joystick_0[3];
wire m_down1    = btn_down      | joystick_0[2];
wire m_left1    = btn_left      | joystick_0[1];
wire m_right1   = btn_right     | joystick_0[0];
wire m_attack1  = btn_attack    | joystick_0[4];
wire m_jump1    = btn_jump      | joystick_0[5];

//Player 2 (cocktail)
wire m_up2      = btn_up        | joystick_1[3];
wire m_down2    = btn_down      | joystick_1[2];
wire m_left2    = btn_left      | joystick_1[1];
wire m_right2   = btn_right     | joystick_1[0];
wire m_attack2  = btn_attack    | joystick_1[4];
wire m_jump2    = btn_jump      | joystick_1[5];

//Start/Coin
wire m_coin1    = btn_coin1     | joystick_0[6];
wire m_coin2    = btn_coin2     | joystick_1[6];
wire m_start1   = btn_1p_start  | joystick_0[7];
wire m_start2   = btn_2p_start  | joystick_0[8];
wire m_pause    = btn_pause     | joystick_0[9];

//Service Mode
wire m_service  = btn_service                  ;

// Hook for a 180 deg control transform if a set ever needs it; unused on UPL.
wire ctrl_flip_ud = 1'b0;

wire m_up1_c   = ctrl_flip_ud ? m_down1 : m_up1;
wire m_down1_c = ctrl_flip_ud ? m_up1   : m_down1;
wire m_up2_c   = ctrl_flip_ud ? m_down2 : m_up2;
wire m_down2_c = ctrl_flip_ud ? m_up2   : m_down2;

wire m_left1_c  = ctrl_flip_ud ? m_right1 : m_left1;
wire m_right1_c = ctrl_flip_ud ? m_left1  : m_right1;
wire m_left2_c  = ctrl_flip_ud ? m_right2 : m_left2;
wire m_right2_c = ctrl_flip_ud ? m_left2  : m_right2;

// MAME port assembly (ninjakd2.cpp:1156). All UPL inputs are IP_ACTIVE_LOW.
//   KEYCOIN: 0 START1  1 START2  4 SERVICE  6 COIN1  7 COIN2
//   PAD:     0 RIGHT   1 LEFT    2 DOWN     3 UP     4 BUTTON1  5 BUTTON2
wire [7:0] keycoin_port = ~{m_coin2, m_coin1, 1'b0, m_service, 1'b0, 1'b0, m_start2, m_start1};
wire [7:0] pad1_port    = ~{2'b00, m_jump1, m_attack1, m_up1_c, m_down1_c, m_left1_c, m_right1_c};
wire [7:0] pad2_port    = ~{2'b00, m_jump2, m_attack2, m_up2_c, m_down2_c, m_left2_c, m_right2_c};

// Hiscore is DISABLED: restore corrupts loaded data, cause not found. Tied off here,
// and index 3 is commented out in every MRA. To re-enable, instantiate hiscore (the
// standard block is in any sibling core), drive the wires below, and restore index 3.
wire [15:0] hs_address      = 16'd0;
wire  [7:0] hs_data_in      = 8'd0;
wire  [7:0] hs_data_out     = 8'd0;       // hiscore disabled; nothing drives this
wire        hs_write_enable = 1'b0;
wire        hs_access_read  = 1'b0;
wire        hs_access_write = 1'b0;
wire        hs_pause        = 1'b0;
wire        hs_configured   = 1'b0;
assign      ioctl_din       = 8'd0;
assign      ioctl_upload_req = 1'b0;

// PAUSE SYSTEM
// wire pause_cpu;   // CTL-2026-10-25: moved up to the keyboard block
wire [23:0] rgb_out;
pause #(8,8,8,60) pause
(
	.*,
	.clk_sys(CLK_60M),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

///////////////                 Video                  ////////////////

wire hblank, vblank;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;

// omegaf (set_id 0x0D-0x0F) is ROT270, xxmissio (0x1A) ROT90; every other UPL set here is ROT0.
wire rotate_ccw  = ~is_xx;                                  // ROT270 = counter-clockwise
wire no_rotate   = ~is_vertical | status[12] | direct_video;
wire flip        = status[11];
screen_rotate screen_rotate(.*);

arcade_video #(512,24) arcade_video                         // xxmissio is 512 wide
(
	.*,

	.clk_video(CLK_60M),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[17:15])
);

// DIP switch
reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_60M) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [7:0] sw0 = dip_sw[0];

// OSD lists Auto,Normal,Early,Late,Later; upl_rom encodes 0=Early 1=Normal 2=Late
// 3=Later. Auto measures the latch after the ROM download, Normal is the fallback.
wire       rd_auto = (status[21:19] == 3'd0);
wire [1:0] rd_mode = (status[21:19] == 3'd2) ? 2'd0 :
                     (status[21:19] == 3'd3) ? 2'd2 :
                     (status[21:19] == 3'd4) ? 2'd3 : 2'd1;

UPLFramebuffer uplframebuffer_inst
(
	.reset(reset),
	.por_reset(por_reset),
	.clk_60m(CLK_60M),

	.keycoin(keycoin_port),
	.pad1(pad1_port),
	.pad2(pad2_port),
	.dsw1(dip_sw[0]),
	.dsw2(dip_sw[1]),

	.set_id(set_id),

	.video_hsync(hs),
	.video_vsync(vs),
	.video_vblank(vblank),
	.video_hblank(hblank),
	.ce_pix(ce_pix),

	.video_r(r),
	.video_g(g),
	.video_b(b),

	.sound_l(audio_l),
	.sound_r(audio_r),

	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_download(ioctl_download),
	.ioctl_wait(ioctl_wait),

	.crt_flip(status[22]),          // CRT Flip
	.h_adj(status[35:32]),          // CRT position: + moves the picture right, 2 px per step
	.v_adj(status[39:36]),          //               + moves it down, 1 line per step

	.pause(pause_cpu),

	.rd_auto(rd_auto),
	.rd_mode(rd_mode),
	.rd_recal(rd_recal),
	.ph_auto(ph_auto),
	.ld_hold(status[0]),
	.ph_req_val(cal_ph),
	.ph_req_tgl(cal_tgl),
	.cal_hold(cal_hold),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	// SDRAM_CLK is driven from CLK_SDRAM below
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK()
);

// SDRAM_CLK: same inverted DDR output as sdram.sv's, on the phase-steppable CLK_SDRAM.
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(CLK_SDRAM),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);


endmodule
