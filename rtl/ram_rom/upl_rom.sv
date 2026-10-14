//============================================================================
//
//  upl_rom.sv — ROM storage for the UPL framebuffer hardware.
//
//  CPU ROMs live in BRAM; graphics, PCM and PROMs live in SDRAM. Region base
//  addresses and the MRA index map are fixed here and in releases/*.mra.
//
//============================================================================

module upl_rom
(
    input                clk,             // 60 MHz fabric; also clocks the SDRAM controller
    input                por_reset,       // power-on ONLY. Must never include ioctl_download.

    // SDRAM read latch. sdram.sv uses BURST_LENGTH=4, so which burst word the
    // completion cycle holds depends on the board's data timing. rd_auto picks it
    // by measurement; rd_mode is the manual override and the fallback.
    input                rd_auto,       // 1 = use the detected latch when detection succeeded
    input          [1:0] rd_mode,       // 0 = Early, 1 = Normal, 2 = Late
    // DIAG-REVERT-2026-10-13: recal added — pulse re-runs the latch probe (SDRAM clock phase moved)
    input                recal,
    // DIAG-REVERT-2026-10-13: SDRAM clock phase calibration ports added
    input                ph_auto,       // OSD phase = Auto: sweep after each ROM load
    input                ld_hold,       // status[0]: Main holds it across the whole MRA load
    output reg     [6:0] ph_req_val,    // requested DPS position 0-79 (208 ps steps)
    output reg           ph_req_tgl,    // flips once per request; recal is the ack
    output               cal_hold,      // sweep pending or running: hold the game in reset

    // ---- ROM download
    input                ioctl_download,
    input          [7:0] ioctl_index,
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    output               ioctl_wait,

    output reg     [7:0] set_id,

    // ---- main CPU ROM (BRAM): 0000-7FFF fixed, 8000-BFFF banked
    input         [15:0] maincpu_addr,
    input          [3:0] maincpu_bank,
    output         [7:0] maincpu_data,

    // ---- sound CPU ROM (BRAM). M1 fetches below 8000 come from the decrypted
    //      opcode half on the sets that ship one (ninjakd2a/ninjakd2b).
    input         [15:0] audiocpu_addr,
    input                audiocpu_m1,
    output         [7:0] audiocpu_data,

    // ---- SDRAM-backed read ports. Hold req until ack; data is valid with ack.
    input         [14:0] char_addr,   input char_req,   output char_ack,   output [7:0] char_data,
    input         [17:0] spr_addr,    input spr_req,    output spr_ack,    output [7:0] spr_data,
    input         [18:0] tile1_addr,  input tile1_req,  output tile1_ack,  output [7:0] tile1_data,
    input         [18:0] tile2_addr,  input tile2_req,  output tile2_ack,  output [7:0] tile2_data,
    input         [18:0] tile3_addr,  input tile3_req,  output tile3_ack,  output [7:0] tile3_data,
    input         [15:0] pcm_addr,    input pcm_req,    output pcm_ack,    output [7:0] pcm_data,

    // ---- SDRAM pins
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

    // MRA index map (must match releases/*.mra)
    //   0 maincpu   1 soundcpu   2 chars   5 set-id
    //   6 sprites   7 tiles1     8 tiles2  9 tiles3   10 pcm   11 proms
    localparam [7:0] IDX_MAIN = 8'd0,  IDX_SND  = 8'd1,  IDX_CHAR = 8'd2,
                     IDX_SET  = 8'd5,  IDX_SPR  = 8'd6,  IDX_TIL1 = 8'd7,
                     IDX_TIL2 = 8'd8,  IDX_TIL3 = 8'd9,  IDX_PCM  = 8'd10,
                     IDX_PROM = 8'd11, IDX_KEY  = 8'd12;

    // SDRAM region bases (byte addresses)
    localparam [23:0] SDR_CHAR = 24'h000000,   // 32K
                      SDR_SPR  = 24'h040000,   // 256K
                      SDR_TIL1 = 24'h080000,   // 512K
                      SDR_TIL2 = 24'h100000,   // 512K
                      SDR_TIL3 = 24'h180000,   // 512K
                      SDR_PCM  = 24'h200000,   // 64K
                      SDR_PROM = 24'h210000;   // 2K

    wire in_sdram = (ioctl_index == IDX_CHAR) || (ioctl_index == IDX_SPR)  ||
                    (ioctl_index == IDX_TIL1) || (ioctl_index == IDX_TIL2) ||
                    (ioctl_index == IDX_TIL3) || (ioctl_index == IDX_PCM)  ||
                    (ioctl_index == IDX_PROM);

    reg [23:0] dl_base;
    always_comb begin
        case (ioctl_index)
            IDX_CHAR: dl_base = SDR_CHAR;
            IDX_SPR : dl_base = SDR_SPR;
            IDX_TIL1: dl_base = SDR_TIL1;
            IDX_TIL2: dl_base = SDR_TIL2;
            IDX_TIL3: dl_base = SDR_TIL3;
            IDX_PCM : dl_base = SDR_PCM;
            IDX_PROM: dl_base = SDR_PROM;
            default : dl_base = 24'd0;
        endcase
    end

    // Game select byte (MRA index 5)
    always_ff @(posedge clk)
        if (ioctl_wr && ioctl_index == IDX_SET) set_id <= ioctl_data;

    // ninjakd2a / ninjakd2b ship a pre-decrypted opcode half; every other set
    // runs opcodes and data from the same image.
    wire use_opcodes = (set_id == 8'h01) || (set_id == 8'h02);

    // MC8123 sets never use the pre-decrypted opcode ROM (01/02 bootlegs only), so
    // rom_snd_opcodes holds the key instead and costs no extra block RAM.
    wire mc8123 = (set_id == 8'h00) || (set_id == 8'h03)
               || (set_id == 8'h04) || (set_id == 8'h05);

    // Main CPU ROM (BRAM). 0x0000-0x7FFF fixed, bank image from download offset 0x8000.
    wire [18:0] mc_off      = ioctl_addr[18:0];
    wire        mc_is_fixed = (mc_off < 19'h08000);
    wire [18:0] mc_bank_off = mc_off - 19'h08000;
    wire        mc_wr       = ioctl_wr && (ioctl_index == IDX_MAIN);

    wire [7:0] mc_fixed_q, mc_bank_q;

    dpram_dc #(.widthad_a(15), .width_a(8)) rom_main_fixed
    (
        .clock_a(clk), .address_a(maincpu_addr[14:0]),
        .data_a(8'd0), .wren_a(1'b0), .q_a(mc_fixed_q),
        .clock_b(clk), .address_b(mc_off[14:0]),
        .data_b(ioctl_data), .wren_b(mc_wr && mc_is_fixed), .q_b()
    );

    dpram_dc #(.widthad_a(18), .width_a(8)) rom_main_bank
    (
        .clock_a(clk), .address_a({maincpu_bank, maincpu_addr[13:0]}),
        .data_a(8'd0), .wren_a(1'b0), .q_a(mc_bank_q),
        .clock_b(clk), .address_b(mc_bank_off[17:0]),
        .data_b(ioctl_data), .wren_b(mc_wr && !mc_is_fixed), .q_b()
    );

    assign maincpu_data = maincpu_addr[15] ? mc_bank_q : mc_fixed_q;

    // Sound CPU ROM (BRAM). 0x00000-0x0FFFF data, 0x10000-0x17FFF opcodes.
    wire [16:0] sc_off   = ioctl_addr[16:0];
    wire        sc_is_op = sc_off[16];
    wire        sc_wr    = ioctl_wr && (ioctl_index == IDX_SND);

    wire [7:0] sc_op_q, sc_lo_q, sc_hi_q;

    // SND decodes cs_rom = (A[15:14] != 2'b11), so only 0000-BFFF is reachable.
    // Split 32K+16K to free 16 M10K blocks; the MRA's C000-FFFF bytes land nowhere.
    dpram_dc #(.widthad_a(15), .width_a(8)) rom_snd_lo          // 0000-7FFF
    (
        .clock_a(clk), .address_a(audiocpu_addr[14:0]),
        .data_a(8'd0), .wren_a(1'b0), .q_a(sc_lo_q),
        .clock_b(clk), .address_b(sc_off[14:0]),
        .data_b(ioctl_data), .wren_b(sc_wr && !sc_is_op && !sc_off[15]), .q_b()
    );

    dpram_dc #(.widthad_a(14), .width_a(8)) rom_snd_hi          // 8000-BFFF
    (
        .clock_a(clk), .address_a(audiocpu_addr[13:0]),
        .data_a(8'd0), .wren_a(1'b0), .q_a(sc_hi_q),
        .clock_b(clk), .address_b(sc_off[13:0]),
        .data_b(ioctl_data), .wren_b(sc_wr && !sc_is_op && (sc_off[15:14] == 2'b10)), .q_b()
    );

    wire [7:0] sc_data_q = audiocpu_addr[15] ? sc_hi_q : sc_lo_q;

    // MC8123 key index: bitswap<12>(addr,15,14,13,12,11,10,8,6,4,2,1,0). Bit 11 is
    // addr[15], always 0 over the encrypted 0000-7FFF, so the MRA packs the two live
    // 2K halves back to back: opcode table then data table, 4K total.
    wire [10:0] tbl_num = {audiocpu_addr[14], audiocpu_addr[13], audiocpu_addr[12],
                           audiocpu_addr[11], audiocpu_addr[10], audiocpu_addr[8],
                           audiocpu_addr[6],  audiocpu_addr[4],  audiocpu_addr[2],
                           audiocpu_addr[1],  audiocpu_addr[0]};

    wire [14:0] sc_op_addr = mc8123 ? {3'd0, ~audiocpu_m1, tbl_num} : audiocpu_addr[14:0];
    wire        key_wr     = ioctl_wr && (ioctl_index == IDX_KEY);

    dpram_dc #(.widthad_a(15), .width_a(8)) rom_snd_opcodes
    (
        .clock_a(clk), .address_a(sc_op_addr),
        .data_a(8'd0), .wren_a(1'b0), .q_a(sc_op_q),
        // Opcodes occupy 0x10000-0x17FFF of a 0x20000 region the MRA fills, so bit 15
        // must gate the write or 0x18000+ aliases onto 0x0000. MC8123 sets: key RAM.
        .clock_b(clk),
        .address_b(key_wr ? {3'd0, ioctl_addr[11:0]} : sc_off[14:0]),
        .data_b(ioctl_data),
        .wren_b(key_wr || (sc_wr && sc_is_op && !sc_off[15])), .q_b()
    );

    // In-flight decrypt. m1 is stable for the whole Z80 cycle, so it both addresses
    // the key and selects the table.
    wire [7:0] sc_dec;

    UPLFramebuffer_MC8123 mc8123_dec
    (
        .val   (sc_data_q),
        .key   (sc_op_q),
        .opcode(audiocpu_m1),
        .dec   (sc_dec)
    );

    // 0x8000-0xBFFF is not encrypted (MAME decodes only the first 0x8000).
    assign audiocpu_data = mc8123 ? (audiocpu_addr[15] ? sc_data_q : sc_dec)
                         : (use_opcodes && audiocpu_m1 && !audiocpu_addr[15])
                           ? sc_op_q : sc_data_q;

    // SDRAM. Read clients round-robin; writes always win so downloads never stall.
    wire [5:0] req = {pcm_req, tile3_req, tile2_req, tile1_req, spr_req, char_req};

    reg  [2:0] rr    = 3'd0;   // rotating priority pointer
    reg  [2:0] cur   = 3'd0;   // client currently being served
    reg  [5:0] ack_r = 6'd0;
    reg  [7:0] rd_q  = 8'd0;

    // A client acked last cycle cannot drop req until the cycle after, so mask it
    // out here rather than burn an arbiter slot the guards below would veto.
    wire [5:0] req_eff = req & ~ack_r;

    // Rotating scan from rr. No modulo: a non-power-of-2 '%' synthesizes a divider.
    reg [2:0] pick;
    reg       pick_v;
    reg [2:0] scan;
    integer   k;
    always_comb begin
        pick   = 3'd0;
        pick_v = 1'b0;
        scan   = rr;
        for (k = 0; k < 6; k = k + 1) begin
            if (!pick_v && req_eff[scan]) begin
                pick   = scan;
                pick_v = 1'b1;
            end
            scan = (scan == 3'd5) ? 3'd0 : (scan + 3'd1);
        end

        // char (client 0) jumps the queue: it is the only client with no lookahead,
        // and its fg FSM hands rowbits to the display whether the fetch completed or
        // not. Demand is bounded at 4 accesses per group, so it cannot starve the rest.
        if (req_eff[3'd0]) begin
            pick   = 3'd0;
            pick_v = 1'b1;
        end
    end

    // gfx_unscramble, in flight (ninjakd2.cpp:2249 lineswap_gfx_roms). MAME rotates
    // the low (bit+1) address bits left at load:
    //   da[bit:1] = sa[bit-1:0], da[0] = sa[bit]; bits above `bit` unchanged.
    // SDRAM holds the raw ROM and the inverse rotate is applied here. chars rotate
    // about bit 13, sprites and tiles1 about bit 14. set_id 00-08 only; robokid and
    // omegaf use empty_init and are not scrambled.
    wire gfx_scr = (set_id <= 8'h08);

    wire [14:0] char_sa  = gfx_scr ? {char_addr[14],     char_addr[0],  char_addr[13:1]}   : char_addr;
    wire [17:0] spr_sa   = gfx_scr ? {spr_addr[17:15],   spr_addr[0],   spr_addr[14:1]}    : spr_addr;
    wire [18:0] tile1_sa = gfx_scr ? {tile1_addr[18:15], tile1_addr[0], tile1_addr[14:1]}  : tile1_addr;

    reg [23:0] cli_byte;
    always_comb begin
        case (pick)
            3'd0: cli_byte = SDR_CHAR + {9'd0,  char_sa};
            3'd1: cli_byte = SDR_SPR  + {6'd0,  spr_sa};
            3'd2: cli_byte = SDR_TIL1 + {5'd0,  tile1_sa};
            3'd3: cli_byte = SDR_TIL2 + {5'd0,  tile2_addr};
            3'd4: cli_byte = SDR_TIL3 + {5'd0,  tile3_addr};
            default: cli_byte = SDR_PCM + {8'd0, pcm_addr};
        endcase
    end

    // 16-bit read cache: every SDRAM word holds two bytes this hardware will ask
    // for, so every second byte fetch becomes a free hit. Pairing differs by set —
    // unscrambled clients pair (da, da+1), scrambled ones (da, da+2) since
    // sa[0] = da[1] — so TWO slots per client are needed to cover the 4-byte row
    // fetches without thrashing. Contents are ROM; only a download invalidates.
    // CACHE_EN = 0 falls back to one SDRAM read per byte.
    localparam CACHE_EN = 1'b1;

    reg [22:0] c_tag [0:5][0:1];
    reg [15:0] c_dat [0:5][0:1];
    reg  [1:0] c_vld [0:5];
    reg        c_lru [0:5];
    integer    ci;

    wire [22:0] pick_wa = cli_byte[23:1];
    wire c_h0  = CACHE_EN && c_vld[pick][0] && (c_tag[pick][0] == pick_wa);
    wire c_h1  = CACHE_EN && c_vld[pick][1] && (c_tag[pick][1] == pick_wa);
    wire c_hit = pick_v && (c_h0 || c_h1);
    wire [15:0] c_word = c_h0 ? c_dat[pick][0] : c_dat[pick][1];

    reg  [26:1] sd_addr;
    reg  [15:0] sd_din;
    reg   [1:0] sd_bs;
    reg         sd_rd, sd_wr, sd_refresh, sd_busy, sd_was_rd, sd_lsb;
    reg         sd_old_ready;
    reg   [8:0] sd_refresh_cnt;

    // Latch every download byte on arrival whatever sd_busy is doing; a strobe
    // landing on a busy cycle is otherwise lost.
    reg         wr_pend;
    reg  [23:0] wr_addr;
    reg   [7:0] wr_data;

    // Deferred read capture for RD_LATE; cur/sd_lsb are snapshotted because the
    // arbiter may start another read next cycle.
    reg         rd_pend = 1'b0;
    reg   [1:0] rd_cnt  = 2'd0;
    reg   [2:0] rd_cur  = 3'd0;
    reg         rd_lsbp = 1'b0;

    wire        sd_ready;
    wire [15:0] sd_dout;

    localparam [1:0] RD_EARLY = 2'd0, RD_NORMAL = 2'd1,
                     RD_LATE  = 2'd2, RD_LATER  = 2'd3;

    // sd_dout is a register of SDRAM_DQ, so a one-deep delay gives burst word 0.
    reg [15:0] sd_dout_d1;
    always_ff @(posedge clk) sd_dout_d1 <= sd_dout;

    // ---- read-latch auto-detect --------------------------------------------
    // Downloads are single byte writes, so SDRAM contents are correct whatever the
    // latch does. Reads burst 4 words and wrap inside the aligned 4-word block, so a
    // board presenting data one cycle early returns word (p+1)%4 for a read of word p.
    // One reference block whose four words are pairwise distinct therefore separates
    // the three candidate sample points: for every phase exactly one returns the word
    // that was written. Falls back to rd_mode if no such block is seen or a read hangs.
    wire [23:0] dl_a = dl_base + ioctl_addr[23:0];
    wire        dl_byte = ioctl_wr && in_sdram;

    reg [63:0] dl_blk;
    reg [22:0] blk_wa;
    reg        blk_rdy;
    always_ff @(posedge clk) begin
        if (dl_byte) dl_blk <= {dl_blk[55:0], ioctl_data};
        if (dl_byte && (dl_a[2:0] == 3'd7)) blk_wa <= {dl_a[23:3], 2'b00};
        blk_rdy <= dl_byte && (dl_a[2:0] == 3'd7);
    end

    // dl_blk holds b0..b7 oldest-first once the 8th byte has shifted in.
    wire [15:0] blk_w0 = {dl_blk[55:48], dl_blk[63:56]};
    wire [15:0] blk_w1 = {dl_blk[39:32], dl_blk[47:40]};
    wire [15:0] blk_w2 = {dl_blk[23:16], dl_blk[31:24]};
    wire [15:0] blk_w3 = {dl_blk[ 7: 0], dl_blk[15: 8]};
    wire blk_distinct = (blk_w0 != blk_w1) && (blk_w0 != blk_w2) && (blk_w0 != blk_w3)
                     && (blk_w1 != blk_w2) && (blk_w1 != blk_w3) && (blk_w2 != blk_w3);

    reg [22:0] ref_wa;
    reg [15:0] ref_w [0:3];
    reg        ref_vld;
    always_ff @(posedge clk) begin
        if (por_reset) ref_vld <= 1'b0;
        else if (blk_rdy && !ref_vld && blk_distinct) begin
            ref_wa   <= blk_wa;
            ref_w[0] <= blk_w0; ref_w[1] <= blk_w1;
            ref_w[2] <= blk_w2; ref_w[3] <= blk_w3;
            ref_vld  <= 1'b1;
        end
    end

    // ---- SDRAM clock phase calibration (DIAG-REVERT-2026-10-13: whole section added) ----
    // The char ROM (index 2, SDRAM 0x000000, 32K in every set) is checksummed as it
    // downloads. Once the load has gone quiet, all 80 DPS positions are tried: the
    // region is read back at each, checksummed at all four latch points, and the
    // position passes for a latch when that checksum matches. The centre of the
    // widest passing run (circular, per latch) is requested. Nothing passes -> 0,
    // the pre-calibration clock. The latch probe re-runs on the final move.
    // DIAG-REVERT-2026-10-13b: Fletcher-32 replaced by CRC-32, originals commented below. A wrong latch
    // returns each 4-word burst rotated, which additive sums can cancel on regular data.
    // reg  [31:0] ref_s1, ref_s2;
    // wire [31:0] ref_s1n = ref_s1 + {16'd0, ref_w16};
    function automatic [31:0] crc_step(input [31:0] c, input [15:0] d);   // CRC-32 0x04C11DB7
        integer i;
        reg [31:0] r;
        begin
            r = c;
            for (i = 15; i >= 0; i = i - 1)
                r = {r[30:0], 1'b0} ^ ((r[31] ^ d[i]) ? 32'h04C11DB7 : 32'd0);
            crc_step = r;
        end
    endfunction
    reg  [31:0] ref_crc;
    reg  [14:0] ref_cnt;
    wire [15:0] ref_w16 = {ioctl_data, dl_blk[7:0]};   // odd byte arriving, even byte before it
    wire        ref_wd  = dl_byte && (ioctl_index == IDX_CHAR) && ioctl_addr[0] && !ref_cnt[14];
    wire        ref_ok  = (ref_cnt[14:10] != 5'd0);    // at least 1K words
    always_ff @(posedge clk) begin
        if (dl_byte && (ioctl_index == IDX_CHAR) && (ioctl_addr[23:0] == 24'd0)) begin
            // ref_s1 <= 32'd0; ref_s2 <= 32'd0; ref_cnt <= 15'd0;
            ref_crc <= 32'hFFFFFFFF; ref_cnt <= 15'd0;
        end else if (ref_wd) begin
            // ref_s1 <= ref_s1n; ref_s2 <= ref_s2 + ref_s1n; ref_cnt <= ref_cnt + 15'd1;
            ref_crc <= crc_step(ref_crc, ref_w16); ref_cnt <= ref_cnt + 15'd1;
        end
    end

    localparam [2:0] CS_IDLE = 3'd0, CS_REQ = 3'd1, CS_TGL = 3'd2, CS_WACK = 3'd3,
                     CS_SETTLE = 3'd4, CS_READ = 3'd5, CS_EVAL = 3'd6, CS_PICK = 3'd7;
    reg   [2:0] cal_st;
    reg         cal_busy, cal_pend, cal_fin, cal_abrt, cal_inflight, sd_cal, ph_auto_d;
    reg   [6:0] cal_p, cal_home, cal_tgt;
    reg  [14:0] cal_w;
    reg   [7:0] cal_set;
    reg  [21:0] cal_to;
    reg  [20:0] cal_quiet;
    reg   [1:0] cal_dly;
    reg  [15:0] cal_e, cal_n, cal_l;
    // DIAG-REVERT-2026-10-13b: original below
    // reg  [31:0] cs1 [0:3];
    // reg  [31:0] cs2 [0:3];
    reg  [31:0] cs_crc [0:3];
    // Run trackers per latch (0 Early, 1 Normal, 2 Late, 3 Later).
    reg   [6:0] t_cur [0:3], t_curs [0:3], t_first [0:3], t_best [0:3], t_bests [0:3];
    reg   [3:0] t_open;

    assign cal_hold = cal_busy || (cal_pend && ph_auto && ref_ok);

    wire [15:0] cal_cw [0:3];
    assign cal_cw[0] = cal_e;     // completion -1
    assign cal_cw[1] = cal_n;     // completion
    assign cal_cw[2] = cal_l;     // completion +1
    assign cal_cw[3] = sd_dout;   // completion +2 (valid when cal_dly == 1)

    // DIAG-REVERT-2026-10-13b: original below
    // wire [3:0] cal_pass = {(cs1[3] == ref_s1) && (cs2[3] == ref_s2),
    //                        (cs1[2] == ref_s1) && (cs2[2] == ref_s2),
    //                        (cs1[1] == ref_s1) && (cs2[1] == ref_s2),
    //                        (cs1[0] == ref_s1) && (cs2[0] == ref_s2)};
    wire [3:0] cal_pass = {cs_crc[3] == ref_crc, cs_crc[2] == ref_crc,
                           cs_crc[1] == ref_crc, cs_crc[0] == ref_crc};

    // Widest run per latch, including one that wraps 79 -> 0.
    reg  [6:0] pk_len [0:3];
    reg  [6:0] pk_st  [0:3];
    reg  [6:0] pk_blen, pk_bst;
    reg  [7:0] pk_mid;
    integer    li;
    always_comb begin
        for (li = 0; li < 4; li = li + 1) begin
            if ((t_cur[li] != 7'd0) && (t_first[li] != 7'd0) && (t_first[li] != 7'd80) &&
                ((t_cur[li] + t_first[li]) > t_best[li])) begin
                pk_len[li] = t_cur[li] + t_first[li];
                pk_st[li]  = t_curs[li];
            end else begin
                pk_len[li] = t_best[li];
                pk_st[li]  = t_bests[li];
            end
        end
        // Preference on ties: Normal, Early, Late, Later.
        pk_blen = pk_len[1]; pk_bst = pk_st[1];
        if (pk_len[0] > pk_blen) begin pk_blen = pk_len[0]; pk_bst = pk_st[0]; end
        if (pk_len[2] > pk_blen) begin pk_blen = pk_len[2]; pk_bst = pk_st[2]; end
        if (pk_len[3] > pk_blen) begin pk_blen = pk_len[3]; pk_bst = pk_st[3]; end
        pk_mid = {1'b0, pk_bst} + {2'b00, pk_blen[6:1]};
        if (pk_mid >= 8'd80) pk_mid = pk_mid - 8'd80;
    end

    // DIAG-REVERT-2026-10-13: original below
    // reg         probing, sd_probe, det_ok, dl_d;
    reg         probing, sd_probe, det_ok, dl_d, prb_req;
    reg   [1:0] prb_dly;
    reg   [1:0] prb_ph, rd_det;
    reg   [3:0] prb_ok;                 // {Later, Late, Normal, Early} still matching
    reg  [15:0] prb_wd, prb_e, prb_n, prb_l;
    reg  [15:0] prb_to;

    wire [3:0] prb_ok_nxt = {prb_ok[3] && (sd_dout == prb_wd),   // completion +2
                             prb_ok[2] && (prb_l   == prb_wd),   // completion +1
                             prb_ok[1] && (prb_n   == prb_wd),   // completion
                             prb_ok[0] && (prb_e   == prb_wd)};  // completion -1

    wire [1:0] rd_sel = (rd_auto && det_ok) ? rd_det : rd_mode;

    wire [15:0] sd_dout_sel = (rd_sel == RD_EARLY) ? sd_dout_d1 : sd_dout;

    // DIAG-REVERT-2026-10-13: original below — cal_busy holds the HPS while an aborted sweep restores the phase
    // assign ioctl_wait = sd_busy || (ioctl_wr && in_sdram);
    assign ioctl_wait = sd_busy || (ioctl_wr && in_sdram) || cal_busy;

    // A hit needs no SDRAM cycle, so it can be served while another client's read is
    // in flight. rd_q/ack_r are shared: one ack per cycle, and a completion wins.
    wire sd_complete = sd_busy && sd_ready && !sd_rd && !sd_wr;
    wire comp_ack    = (sd_complete && sd_was_rd && (rd_sel < RD_LATE)) || rd_pend;
    // DIAG-REVERT-2026-10-13: original below
    // wire serve_hit   = c_hit && !comp_ack && !ack_r[pick] && !ioctl_download && !probing;
    wire serve_hit   = c_hit && !comp_ack && !ack_r[pick] && !ioctl_download && !probing && !cal_busy;

    always_ff @(posedge clk) begin
        // por_reset ONLY: a reset including ioctl_download would idle this FSM for
        // the whole transfer and no byte would land.
        if (por_reset) begin
            sd_rd <= 0; sd_wr <= 0; sd_refresh <= 0; sd_busy <= 0; sd_was_rd <= 0;
            sd_refresh_cnt <= 9'd0; sd_old_ready <= 1'b1; wr_pend <= 1'b0; ack_r <= 6'd0;
            rd_pend <= 1'b0;
            probing <= 1'b0; sd_probe <= 1'b0; prb_dly <= 2'd0; det_ok <= 1'b0;
            // DIAG-REVERT-2026-10-13: original below
            // rd_cnt <= 2'd0; dl_d <= 1'b0;
            rd_cnt <= 2'd0; dl_d <= 1'b0; prb_req <= 1'b0;
            // DIAG-REVERT-2026-10-13: calibration state init added
            cal_st <= CS_IDLE; cal_busy <= 1'b0; cal_pend <= 1'b0; cal_fin <= 1'b0;
            cal_abrt <= 1'b0; cal_inflight <= 1'b0; sd_cal <= 1'b0; cal_dly <= 2'd0;
            cal_home <= 7'd0; cal_quiet <= 21'd0; ph_auto_d <= 1'b0; cal_to <= 22'd0;
            ph_req_val <= 7'd0; ph_req_tgl <= 1'b0;
            rr <= 3'd0;
            for (ci = 0; ci < 6; ci = ci + 1) begin
                c_vld[ci] <= 2'd0;
                c_lru[ci] <= 1'b0;
            end
        end else begin
            // Probe once the download's last write has drained. Re-running on every
            // download pulse just re-confirms the same answer.
            dl_d <= ioctl_download;
            // DIAG-REVERT-2026-10-13: original block commented out below
            // if (dl_d && !ioctl_download && ref_vld && !wr_pend && !sd_busy) begin
            //     probing <= 1'b1; prb_ph <= 2'd0; prb_ok <= 4'hF; prb_to <= 16'd0;
            // end
            // Request is held until it can start: firing only on the download's falling
            // edge silently skipped the probe whenever the bus was busy on that cycle.
            // The probe read itself still waits for !sd_busy in the issue branch below.
            if ((dl_d && !ioctl_download) || recal) prb_req <= 1'b1;
            // DIAG-REVERT-2026-10-13: original below
            // else if (prb_req && ref_vld && !probing && !ioctl_download) begin
            else if (prb_req && ref_vld && !probing && !ioctl_download && !cal_busy) begin
                prb_req <= 1'b0;
                probing <= 1'b1; prb_ph <= 2'd0; prb_ok <= 4'hF; prb_to <= 16'd0;
            end
            if (probing) begin
                prb_to <= prb_to + 16'd1;
                if (&prb_to) begin      // never leave the clients blocked
                    probing <= 1'b0; sd_probe <= 1'b0; prb_dly <= 2'd0; det_ok <= 1'b0;
                end
            end

            // ---- phase calibration (DIAG-REVERT-2026-10-13: block added) ----
            ph_auto_d <= ph_auto;
            cal_quiet <= (ioctl_download || ld_hold) ? 21'd0 : (cal_quiet + {20'd0, ~&cal_quiet});
            if (ref_wd || (ph_auto && !ph_auto_d)) cal_pend <= 1'b1;
            if (cal_busy) cal_to <= cal_to + 22'd1;

            if (cal_busy && (!ph_auto || &cal_to)) begin
                // Manual phase selected, or an ack never came: stop, release the game.
                cal_busy <= 1'b0; cal_st <= CS_IDLE;
            end else if (cal_busy && ioctl_download && !cal_abrt) begin
                // New load mid-sweep: return to the last good position before any write
                // (ioctl_wait holds the HPS), then sweep again once it is quiet.
                cal_abrt <= 1'b1; cal_fin <= 1'b1; cal_tgt <= cal_home; cal_st <= CS_REQ;
            end else begin
                case (cal_st)
                    CS_IDLE:
                        if (cal_pend && ph_auto && ref_ok && (&cal_quiet) && !probing && !ioctl_download && !ld_hold) begin
                            cal_pend <= 1'b0; cal_busy <= 1'b1; cal_fin <= 1'b0; cal_abrt <= 1'b0;
                            cal_p <= 7'd0; cal_tgt <= 7'd0; t_open <= 4'hF; cal_to <= 22'd0;
                            for (li = 0; li < 4; li = li + 1) begin
                                t_cur[li] <= 7'd0; t_curs[li] <= 7'd0; t_first[li] <= 7'd0;
                                t_best[li] <= 7'd0; t_bests[li] <= 7'd0;
                            end
                            cal_st <= CS_REQ;
                        end
                    CS_REQ: begin
                        ph_req_val <= cal_tgt; cal_to <= 22'd0;
                        cal_st <= CS_TGL;
                    end
                    CS_TGL: begin   // value settled a cycle before the toggle crosses
                        ph_req_tgl <= ~ph_req_tgl;
                        cal_st <= CS_WACK;
                    end
                    CS_WACK:
                        if (recal) begin
                            if (cal_fin) begin
                                cal_busy <= 1'b0; cal_st <= CS_IDLE;
                                if (cal_abrt) cal_pend <= 1'b1;
                                else          cal_home <= cal_tgt;
                            end else begin
                                cal_set <= 8'd0; cal_st <= CS_SETTLE;
                            end
                        end
                    CS_SETTLE: begin
                        cal_set <= cal_set + 8'd1;
                        if (&cal_set) begin
                            cal_w <= 15'd0;
                            // for (li = 0; li < 4; li = li + 1) begin cs1[li] <= 32'd0; cs2[li] <= 32'd0; end
                            for (li = 0; li < 4; li = li + 1) cs_crc[li] <= 32'hFFFFFFFF;   // DIAG-REVERT-2026-10-13b
                            cal_st <= CS_READ;
                        end
                    end
                    CS_READ:
                        if ((cal_w == ref_cnt) && !cal_inflight) cal_st <= CS_EVAL;
                    CS_EVAL: begin
                        for (li = 0; li < 4; li = li + 1) begin
                            if (cal_pass[li]) begin
                                t_cur[li] <= t_cur[li] + 7'd1;
                                if (t_cur[li] == 7'd0) t_curs[li] <= cal_p;
                                if (t_open[li]) t_first[li] <= t_first[li] + 7'd1;
                                if ((t_cur[li] + 7'd1) > t_best[li]) begin
                                    t_best[li]  <= t_cur[li] + 7'd1;
                                    t_bests[li] <= (t_cur[li] == 7'd0) ? cal_p : t_curs[li];
                                end
                            end else begin
                                t_cur[li] <= 7'd0; t_open[li] <= 1'b0;
                            end
                        end
                        if (cal_p == 7'd79) cal_st <= CS_PICK;
                        else begin cal_p <= cal_p + 7'd1; cal_tgt <= cal_p + 7'd1; cal_st <= CS_REQ; end
                    end
                    CS_PICK: begin
                        // Nothing passed, or everything did: keep the pre-calibration clock.
                        cal_tgt <= ((pk_blen == 7'd0) || (pk_blen == 7'd80)) ? 7'd0 : pk_mid[6:0];
                        cal_fin <= 1'b1;
                        cal_st  <= CS_REQ;
                    end
                endcase
            end

            // AUTO_REFRESH: 8192 rows / 64 ms = 7.8125 us = 468 cycles at 60 MHz.
            // Toggled unconditionally and OUTSIDE the arbiter so a busy client cannot
            // starve it; the controller edge-detects it and services it from IDLE.
            // This toggle is the only refresh source — sdram.sv's cycles_per_refresh
            // is declared but never referenced.
            if (sd_refresh_cnt == 9'd467) begin
                sd_refresh_cnt <= 9'd0;
                sd_refresh     <= ~sd_refresh;
            end else begin
                sd_refresh_cnt <= sd_refresh_cnt + 1'b1;
            end
            sd_old_ready   <= sd_ready;
            ack_r          <= 6'd0;

            if (ioctl_wr && in_sdram) begin
                wr_pend <= 1'b1;
                wr_addr <= dl_base + ioctl_addr[23:0];
                wr_data <= ioctl_data;
            end

            // accepted: ready fell 1->0, drop the strobe so the op runs once
            if (sd_old_ready && !sd_ready) begin
                sd_rd <= 0;
                sd_wr <= 0;
            end

            if (sd_busy) begin
                // complete: ready back high with the strobe already cleared
                if (sd_ready && !sd_rd && !sd_wr) begin
                    if (sd_was_rd) begin
                        if (sd_probe) begin
                            prb_e <= sd_dout_d1; prb_n <= sd_dout;
                            prb_dly <= 2'd2; sd_probe <= 1'b0;
                        // DIAG-REVERT-2026-10-13: calibration read capture added
                        end else if (sd_cal) begin
                            cal_e <= sd_dout_d1; cal_n <= sd_dout;
                            cal_dly <= 2'd2; sd_cal <= 1'b0;
                        end else if (rd_sel >= RD_LATE) begin
                            rd_pend <= 1'b1; rd_cur <= cur; rd_lsbp <= sd_lsb;
                            rd_cnt  <= (rd_sel == RD_LATER) ? 2'd2 : 2'd1;
                        end else begin
                            rd_q       <= sd_lsb ? sd_dout_sel[15:8] : sd_dout_sel[7:0];
                            ack_r[cur] <= 1'b1;
                            c_tag[cur][c_lru[cur]] <= sd_addr[23:1];
                            c_dat[cur][c_lru[cur]] <= sd_dout_sel;
                            c_vld[cur][c_lru[cur]] <= 1'b1;
                            c_lru[cur]             <= ~c_lru[cur];
                        end
                    end
                    sd_busy <= 0;
                end
            end else begin
                if (wr_pend) begin
                    sd_addr  <= {3'd0, wr_addr[23:1]};
                    sd_din   <= {wr_data, wr_data};
                    sd_bs    <= wr_addr[0] ? 2'b10 : 2'b01;
                    sd_wr    <= 1; sd_busy <= 1; sd_was_rd <= 0;
                    // Keep a request arriving this cycle: a bare `wr_pend <= 0` here
                    // would win as the last assignment and drop that byte.
                    wr_pend  <= (ioctl_wr && in_sdram);
                // !ack_r[pick] && !c_hit: never fetch for a client whose ack is already
                // up or is being served from cache, or its next read is one fetch stale.
                // DIAG-REVERT-2026-10-13: calibration read issue added
                end else if ((cal_st == CS_READ) && cal_busy && !cal_inflight && (cal_w != ref_cnt) && !rd_pend) begin
                    sd_addr   <= {11'd0, cal_w};   // SDR_CHAR is word 0
                    sd_rd     <= 1; sd_busy <= 1; sd_was_rd <= 1; sd_cal <= 1; cal_inflight <= 1;
                end else if (probing && (prb_dly == 2'd0)) begin
                    sd_addr   <= {3'd0, ref_wa + {21'd0, prb_ph}};
                    prb_wd    <= ref_w[prb_ph];
                    sd_rd     <= 1; sd_busy <= 1; sd_was_rd <= 1; sd_probe <= 1;
                // DIAG-REVERT-2026-10-13: original below
                // end else if (pick_v && !ioctl_download && !probing && !rd_pend && !ack_r[pick] && !c_hit) begin
                end else if (pick_v && !ioctl_download && !probing && !cal_busy && !rd_pend && !ack_r[pick] && !c_hit) begin
                    sd_addr   <= {3'd0, cli_byte[23:1]};
                    sd_lsb    <= cli_byte[0];
                    cur       <= pick;
                    rr        <= (pick == 3'd5) ? 3'd0 : (pick + 3'd1);
                    sd_rd     <= 1; sd_busy <= 1; sd_was_rd <= 1;
                end
            end

            // RD_LATE capture, one cycle after completion
            if (rd_pend && (rd_cnt > 2'd1)) rd_cnt <= rd_cnt - 2'd1;
            else if (rd_pend) begin
                rd_q          <= rd_lsbp ? sd_dout[15:8] : sd_dout[7:0];
                ack_r[rd_cur] <= 1'b1;
                rd_pend       <= 1'b0;
                c_tag[rd_cur][c_lru[rd_cur]] <= sd_addr[23:1];
                c_dat[rd_cur][c_lru[rd_cur]] <= sd_dout;
                c_vld[rd_cur][c_lru[rd_cur]] <= 1'b1;
                c_lru[rd_cur]                <= ~c_lru[rd_cur];
            end

            // Late sample lands here, one cycle after completion, so all three
            // candidate sample points are now in hand for this phase.
            if (prb_dly == 2'd2) begin
                prb_l   <= sd_dout;          // completion +1
                prb_dly <= 2'd1;
            end else if (prb_dly == 2'd1) begin
                prb_ok  <= prb_ok_nxt;       // sd_dout is now completion +2
                prb_dly <= 2'd0;
                if (prb_ph == 2'd3) begin
                    probing <= 1'b0;
                    if      (prb_ok_nxt[1]) begin rd_det <= RD_NORMAL; det_ok <= 1'b1; end
                    else if (prb_ok_nxt[0]) begin rd_det <= RD_EARLY;  det_ok <= 1'b1; end
                    else if (prb_ok_nxt[2]) begin rd_det <= RD_LATE;   det_ok <= 1'b1; end
                    else if (prb_ok_nxt[3]) begin rd_det <= RD_LATER;  det_ok <= 1'b1; end
                    else                          det_ok <= 1'b0;
                end else prb_ph <= prb_ph + 2'd1;
            end

            // DIAG-REVERT-2026-10-13: calibration sample pipeline added
            if (cal_dly == 2'd2) begin
                cal_l   <= sd_dout;          // completion +1
                cal_dly <= 2'd1;
            end else if (cal_dly == 2'd1) begin
                // DIAG-REVERT-2026-10-13b: original below
                // for (li = 0; li < 4; li = li + 1) begin
                //     cs1[li] <= cs1[li] + {16'd0, cal_cw[li]};
                //     cs2[li] <= cs2[li] + cs1[li] + {16'd0, cal_cw[li]};
                // end
                for (li = 0; li < 4; li = li + 1) cs_crc[li] <= crc_step(cs_crc[li], cal_cw[li]);
                cal_dly <= 2'd0; cal_inflight <= 1'b0; cal_w <= cal_w + 15'd1;
            end

            // Cache hit: ack immediately and rotate the pointer as a real service
            // would, so one client cannot monopolise the port.
            if (serve_hit) begin
                rd_q        <= cli_byte[0] ? c_word[15:8] : c_word[7:0];
                ack_r[pick] <= 1'b1;
                rr          <= (pick == 3'd5) ? 3'd0 : (pick + 3'd1);
            end

            // ROM never changes underneath us, so a download is the only invalidation.
            // DIAG-REVERT-2026-10-13: original below
            // if (ioctl_download)
            if (ioctl_download || recal)   // recal: words cached at the old phase may be bad
                for (ci = 0; ci < 6; ci = ci + 1) c_vld[ci] <= 2'd0;
        end
    end

    assign {pcm_ack, tile3_ack, tile2_ack, tile1_ack, spr_ack, char_ack} = ack_r;
    assign char_data  = rd_q;
    assign spr_data   = rd_q;
    assign tile1_data = rd_q;
    assign tile2_data = rd_q;
    assign tile3_data = rd_q;
    assign pcm_data   = rd_q;

    // Clock-rate dependent: 468 cycles = 7.8125 us at 60 MHz (stock 780 would be
    // 13 us and lose data). Startup 100 us = 6060 cycles.
    sdram #(.sdram_startup_cycles(14'd6060), .cycles_per_refresh(14'd468)) sdram_i
    (
        .init       (por_reset),
        .clk        (clk),
        .SDRAM_DQ   (SDRAM_DQ),   .SDRAM_A   (SDRAM_A),   .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH (SDRAM_DQMH), .SDRAM_BA  (SDRAM_BA),  .SDRAM_nCS (SDRAM_nCS),
        .SDRAM_nWE  (SDRAM_nWE),  .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE  (SDRAM_CKE),  .SDRAM_CLK (SDRAM_CLK), .SDRAM_EN  (1'b1),
        .sel        (1'b1),
        .addr       (sd_addr),    .dout      (sd_dout),   .din       (sd_din),
        .wr         (sd_wr),      .bs        (sd_bs),     .rd        (sd_rd),
        .ready      (sd_ready),   .refresh   (sd_refresh),
        .cpsel(1'b0), .cpaddr(26'd0), .cpdin(16'd0), .cprd(), .cpreq(1'b0), .cpbusy()
    );

endmodule
