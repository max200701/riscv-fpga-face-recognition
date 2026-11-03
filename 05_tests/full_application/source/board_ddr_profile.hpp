#pragma once
#include <cstdlib>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
namespace board_ddr_profile {
constexpr unsigned kLatency = 40;
constexpr unsigned kRate = 750;
constexpr const char* kName = "board_estimate40";
inline unsigned number(const char* text) {
  std::string s(text); size_t end=0;
  if(s.empty() || s[0]=='-') throw std::runtime_error("invalid DDR profile number");
  auto n=std::stoul(s,&end);
  if(end!=s.size() || n>4096) throw std::runtime_error("invalid DDR profile number");
  return unsigned(n);
}
inline void configure(int argc, char** argv, uint32_t& latency, uint32_t& rate) {
  if(const char* p=std::getenv("DDR_FIRST_LATENCY"))
    if(number(p)!=kLatency) throw std::runtime_error("stale DDR_FIRST_LATENCY conflicts with frozen profile");
  if(argc>2) throw std::runtime_error("unexpected DDR simulation arguments");
  if(argc>1 && number(argv[1])!=kRate) throw std::runtime_error("DDR bandwidth argument conflicts with frozen profile");
  latency=kLatency; rate=kRate;
  std::cout << "DDR_PROFILE id=" << kName << " first_latency=" << latency
            << " shared_limit_Bps=" << uint64_t(rate)*4000000ULL
            << " write_visibility_cycles=3 transaction_calibrated=0 board_prediction_accepted=0" << std::endl;
}
}
