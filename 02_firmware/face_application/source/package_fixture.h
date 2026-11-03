typedef struct { uint32_t package_base,package_bytes,payload_crc,arena,macs,op_hash,crc0,crc1,crc2,crc3,crc4,crc5,program,program_bytes,commands,program_crc,assets,asset_bytes,asset_crc; } model_contract;
static uint32_t current_model;
static const model_contract models[2]={
{65536u,549722u,3279544509u,11059200u,56u,3419377476u,4172577005u,1708458788u,2893429149u,2710772158u,3183682244u,2771718948u,117440512u,926784u,14481u,2396708544u,100663296u,3680000u,327409369u},
{16777216u,3617343u,812686290u,3361792u,50u,1715406439u,934704849u,1976725422u,3883592742u,4191298613u,3183682244u,3607668708u,150994944u,256320u,4005u,3984628143u,134217728u,4630528u,4034034809u}
};
#define PACKAGE_BASE (models[current_model].package_base)
#define PACKAGE_BYTES (models[current_model].package_bytes)
#define EXPECTED_PAYLOAD_CRC (models[current_model].payload_crc)
#define EXPECTED_ARENA (models[current_model].arena)
#define EXPECTED_MACS (models[current_model].macs)
#define EXPECTED_OP_HASH (models[current_model].op_hash)
static const uint32_t section_manifest[2][6]={{4172577005u,1708458788u,2893429149u,2710772158u,3183682244u,2771718948u},{934704849u,1976725422u,3883592742u,4191298613u,3183682244u,3607668708u}};
#define expected_section_crc (section_manifest[current_model])
