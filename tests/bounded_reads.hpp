#pragma once
#include <cstdint>
#include <deque>
#include <stdexcept>
// Host simulation of the existing physical request budget. No graph math.
// Data still consumes the driver's shared read/write bandwidth credit.
struct BoundedReads {
 struct Request { uint32_t address,left,id; uint64_t ready; };
 std::deque<Request> queue;
 uint32_t beats=0;
 bool can_accept(uint32_t n)const {return n>=1&&n<=16&&queue.size()<8&&beats+n<=64;}
 bool ready(uint64_t now)const {return !queue.empty()&&queue.front().ready<=now;}
 const Request& front()const {if(queue.empty())throw std::runtime_error("empty read queue");return queue.front();}
 void push(uint32_t address,uint32_t n,uint32_t id,uint64_t ready_at){
  if(!can_accept(n)||id>8||address%32||(address%4096)+n*32>4096)throw std::runtime_error("physical read geometry/capacity");
  for(const auto&r:queue)if(r.id==id)throw std::runtime_error("live physical RID reused");
  if((id==8&&!queue.empty())||(!queue.empty()&&queue.front().id==8))throw std::runtime_error("verify read overlaps normal request");
  queue.push_back({address,n,id,ready_at});beats+=n;
 }
 void consume(){
  if(queue.empty()||!beats)throw std::runtime_error("unowned physical return");
  auto&r=queue.front();r.address+=32;--r.left;--beats;if(!r.left)queue.pop_front();
 }
};
