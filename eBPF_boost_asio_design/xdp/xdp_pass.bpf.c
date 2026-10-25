#include "bpf_helpers.h"
#include "xdp/ebpfhook.h"

SEC("xdp/pass")
int xdp_pass(xdp_md_t* context)
{
    (void)context;
    return XDP_PASS;
}