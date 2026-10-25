#include "bpf_endian.h"
#include "bpf_helpers.h"
#include "ebpf_nethooks.h"

#define BLOCKED_PORT 4444

static __inline int authorize_bind(bpf_sock_addr_t* context)
{
    if (context->user_port == bpf_htons(BLOCKED_PORT)) {
        return BPF_SOCK_ADDR_VERDICT_REJECT;
    }
    return BPF_SOCK_ADDR_VERDICT_PROCEED_SOFT;
}

SEC("cgroup/bind4")
int bind_policy_ipv4(bpf_sock_addr_t* context)
{
    return authorize_bind(context);
}

SEC("cgroup/bind6")
int bind_policy_ipv6(bpf_sock_addr_t* context)
{
    return authorize_bind(context);
}