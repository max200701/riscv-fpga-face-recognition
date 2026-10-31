error {REFERENCE RECIPE: relocate inputs and review docs/BUILD.md before running}
set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676
gen_bit_stream -force_to_run -input_db_file {$QG_ROUTE_WORK/qb_route10.adf} -create_bit_file TRUE -disable_cyclic_redundancy_checking FALSE -write_drm_data TRUE -scbv {High Voltage} -unused_io_status {UNUSED}
puts {QG28_EXPERIMENT_BITSTREAM_DONE}
exit
