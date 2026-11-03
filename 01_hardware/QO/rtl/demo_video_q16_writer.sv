// OJ: UI-clock stream adapter. Not an MS7200 receiver or a CDC implementation.
// RGB input is already an exact 640x480 canvas. Preserve detector BGR/mean/Q16.
// Connect p_* through the EXCLUSIVE boot-input selector to the existing bridge.
// rst is the coordinated physical reset, never the application warm reset.
// ACK is matched full-burst HMIC completion; it does not imply readback compare.
// frame_ready still requires every burst completion and preserves the lease.
module demo_video_q16_writer #(
 parameter integer WIDTH=640,HEIGHT=480
)(
 input wire clk,rst,boot_allowed,bridge_drained,
 input wire start,input wire[31:0]generation,frame_id,base_address,
 output wire start_ready,
 input wire pixel_valid,output wire pixel_ready,input wire[23:0]pixel_rgb,
 input wire pixel_last,
 input wire release_frame,input wire[31:0]release_generation,
 output wire frame_ready,output reg fault,output reg[7:0]fault_code,
 output reg[31:0]held_generation,held_frame_id,pixels_accepted,writes_acknowledged,
 output wire p_wr_valid,input wire p_wr_ready,output wire[31:0]p_wr_addr,
 output wire[6:0]p_wr_beats,output wire[63:0]p_wr_token,output wire[2:0]p_wr_owner,
 output wire p_w_valid,input wire p_w_ready,output wire[255:0]p_w_data,
 output wire[31:0]p_w_strb,output wire p_w_last,
 input wire p_b_valid,output wire p_b_ready,input wire[63:0]p_b_token,input wire p_b_error
);
 localparam integer PIXELS=WIDTH*HEIGHT,PLANE_BYTES=PIXELS*4;
 localparam IDLE=0,COLLECT=1,REQUEST=2,FETCH=3,SEND=4,ACK=5,READY=6,FAILED=7;
 reg[2:0]state;reg[1:0]plane;reg[4:0]beat,block_beats;
 reg[6:0]block_fill;reg[31:0]block_start,base,sequence_number;
 reg[255:0]pack_b,pack_g,pack_r,data;
 // Full 256-bit writes, one synchronous read, no multi-read-port pixel store.
 reg[255:0]bank_b[0:15],bank_g[0:15],bank_r[0:15];
 wire[31:0]q_b=($signed({1'b0,pixel_rgb[7:0]})-32'sd104)<<<16;
 wire[31:0]q_g=($signed({1'b0,pixel_rgb[15:8]})-32'sd117)<<<16;
 wire[31:0]q_r=($signed({1'b0,pixel_rgb[23:16]})-32'sd123)<<<16;
 assign start_ready=state==IDLE&&boot_allowed&&bridge_drained&&!rst;
 assign pixel_ready=state==COLLECT&&boot_allowed&&!fault&&!rst;
 assign frame_ready=state==READY&&!fault&&!rst;
 assign p_wr_valid=state==REQUEST&&!fault&&!rst;
 assign p_wr_addr=base+block_start*4+plane*PLANE_BYTES;
 assign p_wr_beats={2'b0,block_beats};
 assign p_wr_token={held_generation,sequence_number};
 assign p_wr_owner=3'd0; // Existing boot owner, no extra physical writer.
 assign p_w_valid=state==SEND&&!fault&&!rst;
 assign p_w_data=data;assign p_w_strb=32'hffffffff;
 assign p_w_last=beat+1==block_beats;
 assign p_b_ready=state==ACK&&!rst;
 task automatic poison(input[7:0]code);
  begin fault<=1;fault_code<=code;state<=FAILED;end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;fault<=0;fault_code<=0;held_generation<=0;held_frame_id<=0;
   pixels_accepted<=0;writes_acknowledged<=0;block_fill<=0;block_start<=0;
   beat<=0;block_beats<=0;plane<=0;sequence_number<=0;base<=0;
   pack_b<=0;pack_g<=0;pack_r<=0;data<=0;
  end else begin
   case(state)
    IDLE:if(start&&start_ready)begin
     // 128 pixels = 512 bytes/plane; alignment avoids crossing 4 KiB pages.
     if(PIXELS<=0||PIXELS%128!=0||base_address[8:0]!=0||
        base_address>32'h40000000-3*PLANE_BYTES)poison(8'h01);
     else begin held_generation<=generation;held_frame_id<=frame_id;base<=base_address;
      pixels_accepted<=0;writes_acknowledged<=0;block_fill<=0;block_start<=0;
      sequence_number<=0;plane<=0;state<=COLLECT;end
    end
    COLLECT:if(pixel_valid&&pixel_ready)begin
     if(pixel_last!=(pixels_accepted+1==PIXELS))poison(8'h02);
     else begin
      pack_b<={q_b,pack_b[255:32]};pack_g<={q_g,pack_g[255:32]};pack_r<={q_r,pack_r[255:32]};
      if(block_fill[2:0]==7)begin
       bank_b[block_fill[6:3]]<={q_b,pack_b[255:32]};
       bank_g[block_fill[6:3]]<={q_g,pack_g[255:32]};
       bank_r[block_fill[6:3]]<={q_r,pack_r[255:32]};
      end
      pixels_accepted<=pixels_accepted+1;block_fill<=block_fill+1'b1;
      if(block_fill==127)begin block_beats<=16;plane<=0;beat<=0;state<=REQUEST;end
     end
    end
    REQUEST:if(p_wr_ready)begin beat<=0;state<=FETCH;end
    FETCH:begin
     case(plane)0:data<=bank_b[beat];1:data<=bank_g[beat];default:data<=bank_r[beat];endcase
     state<=SEND;
    end
    SEND:if(p_w_ready)begin
     if(p_w_last)state<=ACK;else begin beat<=beat+1'b1;state<=FETCH;end
    end
    ACK:if(p_b_valid)begin
     if(p_b_token!={held_generation,sequence_number}||p_b_error)poison(8'h03);
     else begin
      writes_acknowledged<=writes_acknowledged+1;sequence_number<=sequence_number+1;
      if(plane!=2)begin plane<=plane+1'b1;state<=REQUEST;end
      else if(pixels_accepted==PIXELS)state<=READY;
      else begin block_start<=pixels_accepted;block_fill<=0;state<=COLLECT;end
     end
    end
    READY:if(release_frame)begin
     if(release_generation!=held_generation||!boot_allowed||!bridge_drained)poison(8'h04);
     else state<=IDLE;
    end
    default:;
   endcase
   if(state>=COLLECT&&state<=ACK&&!boot_allowed)poison(8'h05);
  end
 end
endmodule
