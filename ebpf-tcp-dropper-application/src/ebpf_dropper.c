#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// Config map: key 0 -> ifindex to match. 0 means match all interfaces.
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u32);
} cfg_ifindex SEC(".maps");

// Config map: key 0 -> TCP port to BLOCK (host byte order). 0 means 'disabled' (allow all).
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u16);
} cfg_port SEC(".maps");

// Check if we should apply filtering on this interface
static __always_inline int should_filter(__u32 ifindex) {
    __u32 key = 0;
    __u32 *cfg = bpf_map_lookup_elem(&cfg_ifindex, &key);
    if (!cfg) {
        // If map not set up, default to apply filtering on all interfaces
        return 1;
    }
    if (*cfg == 0) {
        // 0 means apply filtering on all interfaces
        return 1;
    }
    // Only apply filtering if the skb ifindex matches configured one
    return ifindex == *cfg;
}

// Returns 1 if the packet is TCP/IPv4 and either source or destination port
// matches the configured blocked port. Otherwise returns 0.
static __always_inline int is_blocked_port(struct __sk_buff *skb) {
    __u32 key = 0;
    __u16 *p_port = bpf_map_lookup_elem(&cfg_port, &key);
    if (!p_port) {
        return 0; // No port configured => nothing to block
    }
    __u16 blocked_port = *p_port; // host order
    if (blocked_port == 0) {
        return 0; // disabled => nothing to block
    }

    struct iphdr iph;
    if (bpf_skb_load_bytes(skb, 0, &iph, sizeof(iph)) < 0)
        return 0; // Not IP => ignore
    if (iph.version != 4)
        return 0; // Not IPv4 => ignore
    if (iph.protocol != IPPROTO_TCP)
        return 0; // Not TCP => ignore

    __u32 ihl = iph.ihl * 4;
    struct tcphdr tcph;
    if (bpf_skb_load_bytes(skb, ihl, &tcph, sizeof(tcph)) < 0)
        return 0; // Can't parse TCP => ignore

    __u16 sport = bpf_ntohs(tcph.source);
    __u16 dport = bpf_ntohs(tcph.dest);
    
    // Block if either source or destination port matches the blocked port
    return sport == blocked_port || dport == blocked_port;
}

// CGROUP_SKB eBPF program: return 0 (SK_DROP) to drop, 1 (SK_PASS) to allow
SEC("cgroup_skb/egress")
int block_egress(struct __sk_buff *skb) {
    // If we should not filter this interface, allow all traffic
    if (!should_filter(skb->ifindex))
        return 1; // SK_PASS
    
    // Drop packets matching the configured port; otherwise allow
    if (is_blocked_port(skb))
        return 0; // SK_DROP

    return 1; // SK_PASS
}

SEC("cgroup_skb/ingress")
int block_ingress(struct __sk_buff *skb) {
    // If we should not filter this interface, allow all traffic
    if (!should_filter(skb->ifindex))
        return 1; // SK_PASS
    
    if (is_blocked_port(skb))
        return 0; // SK_DROP

    return 1; // SK_PASS
}

char _license[] SEC("license") = "GPL";