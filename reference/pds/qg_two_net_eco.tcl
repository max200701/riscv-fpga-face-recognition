error {REFERENCE RECIPE: relocate inputs and review docs/BUILD.md before running}
set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676
mpnr -input {$QG_ROUTE_WORK/qb_route10.adf}
unroute -design_net {application/transport/endpoint/header [35];application/transport/endpoint/good_frame;}
auto_route -design_net {application/transport/endpoint/header [35];application/transport/endpoint/good_frame;}
save_adif
puts {QG10_TWO_NET_ROUTE_SAVED}
exit
