#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// Define the BPF map to store the port to block
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, __u16);
    __uint(max_entries, 1);
} port_to_block SEC(".maps");

SEC("xdp")
int drop_tcp_port(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    // Parse Ethernet header
    struct ethhdr *eth = data;
    if ((void *)eth + sizeof(*eth) > data_end) {
        return XDP_PASS;
    }
    
    // Check if it's an IP packet
    if (eth->h_proto != bpf_htons(ETH_P_IP)) {
        return XDP_PASS;
    }
    
    // Parse IP header
    struct iphdr *ip = data + sizeof(*eth);
    if ((void *)ip + sizeof(*ip) > data_end) {
        return XDP_PASS;
    }

    // Ensure IP header has a valid minimum length (ihl is number of 32-bit words)
    if (ip->ihl < 5) {
        return XDP_PASS;
    }

    // Compute actual IP header length and re-validate bounds
    unsigned int ip_hdr_len = ip->ihl * 4;
    if ((void *)ip + ip_hdr_len > data_end) {
        return XDP_PASS;
    }

    // Check if it's a TCP packet (IPPROTO_TCP is 6)
    if (ip->protocol != 6) {
        return XDP_PASS;
    }
    
    // Parse TCP header (account for IP header length)
    struct tcphdr *tcp = (void *)ip + ip_hdr_len;
    if ((void *)tcp + sizeof(*tcp) > data_end) {
        return XDP_PASS;
    }
    
    // Get the port to block from the map
    __u32 key = 0;
    __u16 *block_port = bpf_map_lookup_elem(&port_to_block, &key);
    if (!block_port) {
        return XDP_PASS;
    }
    
    // Check if the destination port matches the port to block
    if (bpf_ntohs(tcp->dest) == *block_port) {
        return XDP_DROP;
    }
    
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
