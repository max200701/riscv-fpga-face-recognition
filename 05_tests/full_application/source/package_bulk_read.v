// Bounded CPU read bank fill. The existing ordered transport owns all real ACKs.
// Maximum512B, 32B aligned; splits at4KiB, never exposes partial data as complete.
module package_bulk_read(
 input wire clk,rst,start,output wire ready,input wire[31:0]addr,bytes,
 output reg done,output reg[3:0]error,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire cache_we,output wire[3:0]cache_addr,output wire[255:0]cache_data
);
 localparam IDLE=0,REQUEST=1,RECEIVE=2,FINISH=3;
 reg[1:0]state;reg[31:0]cursor;reg[4:0]left,part;reg[3:0]offset;
 wire[7:0]page_left=8'd128-{1'b0,cursor[11:5]};
 wire[4:0]burst=left<page_left?left:page_left[4:0];
 wire valid_beat=!r_error&&(r_last==(part==1));
 assign ready=!rst&&state==IDLE;
 assign rd_valid=!rst&&state==REQUEST;assign rd_addr=cursor;assign rd_beats=burst;
 assign r_ready=!rst&&state==RECEIVE;
 assign cache_we=r_valid&&r_ready&&valid_beat;
 assign cache_addr=offset;assign cache_data=r_data;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;cursor<=0;left<=0;part<=0;offset<=0;done<=0;error<=0;end
  else begin
   done<=0;
   case(state)
    IDLE:if(start)begin
     error<=0;offset<=0;
     if(addr[31:30]!=0||addr[4:0]!=0||bytes==0||bytes>512||bytes[4:0]!=0||
        {1'b0,addr}+{1'b0,bytes}>33'h40000000)begin error<=1;state<=FINISH;end
     else begin cursor<=addr;left<=bytes[9:5];state<=REQUEST;end
    end
    REQUEST:if(rd_ready)begin part<=burst;state<=RECEIVE;end
    RECEIVE:if(r_valid)begin
     if(!valid_beat)begin error<=4;state<=FINISH;end
     else begin
      cursor<=cursor+32;left<=left-1'b1;part<=part-1'b1;offset<=offset+1'b1;
      if(left==1)state<=FINISH;else if(part==1)state<=REQUEST;
     end
    end
    FINISH:begin done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
