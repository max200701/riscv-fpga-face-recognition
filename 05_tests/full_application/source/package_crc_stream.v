// Reflected CRC32, polynomial 0xedb88320, init/final XOR all ones.
// A load-time integrity primitive. It does not validate graph semantics or
// authorize a package: firmware must also validate header/section/range fields.
module package_crc_stream(
 input wire clk,rst,start,input wire[31:0]cfg_bytes,cfg_expected,
 output wire ready,input wire in_valid,output wire in_ready,
 input wire[255:0]in_data,input wire in_last,
 output reg done,output reg[3:0]error,output reg[31:0]actual_crc,consumed_bytes
);
 reg active,busy;reg[255:0]buffer;reg[5:0]buffer_left;
 reg[31:0]remaining,expected,crc;
 wire[2:0]take=buffer_left>4?3'd4:buffer_left[2:0];
 assign ready=!rst&&!active&&!busy;
 assign in_ready=!rst&&active&&!busy&&error==0;
 function[31:0]step_byte(input[31:0]old,input[7:0]data);
  reg[31:0]x;integer k;
  begin x=old^{24'b0,data};for(k=0;k<8;k=k+1)x=(x>>1)^(x[0]?32'hedb88320:32'b0);step_byte=x;end
 endfunction
 function[31:0]step4(input[31:0]old,input[31:0]data,input[2:0]count);
  reg[31:0]a,b,c,d;
  begin
   a=step_byte(old,data[7:0]);b=step_byte(a,data[15:8]);c=step_byte(b,data[23:16]);d=step_byte(c,data[31:24]);
   case(count)0:step4=old;1:step4=a;2:step4=b;3:step4=c;default:step4=d;endcase
  end
 endfunction
 wire[31:0]next_crc=step4(crc,buffer[31:0],take);
 always @(posedge clk)begin
  if(rst)begin active<=0;busy<=0;buffer<=0;buffer_left<=0;remaining<=0;expected<=0;crc<=32'hffffffff;done<=0;error<=0;actual_crc<=0;consumed_bytes<=0;end
  else begin
   done<=0;
   if(start&&ready)begin
    remaining<=cfg_bytes;expected<=cfg_expected;crc<=32'hffffffff;consumed_bytes<=0;actual_crc<=0;
    if(cfg_bytes==0||cfg_bytes>32'h40000000)begin error<=1;done<=1;end
    else begin active<=1;error<=0;end
   end
   if(in_valid&&in_ready)begin
    if(in_last!=(remaining<=32))begin active<=0;error<=2;done<=1;end
    else begin buffer<=in_data;buffer_left<=remaining>32?32:remaining[5:0];busy<=1;end
   end
   if(busy)begin
    crc<=next_crc;buffer<=buffer>>32;buffer_left<=buffer_left-take;remaining<=remaining-take;consumed_bytes<=consumed_bytes+take;
    if(buffer_left==take)busy<=0;
    if(remaining==take)begin
     actual_crc<=~next_crc;error<=((~next_crc)==expected)?0:3;active<=0;busy<=0;done<=1;
    end
   end
  end
 end
endmodule
