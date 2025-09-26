/* BPF program to block port 8080 */

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

// Define the port to block
#define BLOCKED_PORT 8080

// Helper macro for debug output
#define bpf_printk(fmt, ...)                            \
    ({                                                  \
        char ____fmt[] = fmt;                           \
        bpf_trace_printk(____fmt, sizeof(____fmt),      \
                ##__VA_ARGS__);                         \
    })

SEC("cgroup/connect4")
int connect4_filter(struct bpf_sock_addr *ctx) {
    // Get the destination port in host byte order
    __u16 port = ctx->user_port;
    port = (port >> 8) | ((port & 0xFF) << 8);
    
    // Block connections to the specified port
    if (port == BLOCKED_PORT) {
        bpf_printk("BLOCKED connection to port %d\n", port);
        return 0;  // Block the connection
    }
    
    bpf_printk("ALLOWED connection to port %d\n", port);
    return 1;  // Allow the connection
}

// For IPv6 support (using same logic as IPv4 for simplicity)
SEC("cgroup/connect6")
int connect6_filter(struct bpf_sock_addr *ctx) {
    return connect4_filter(ctx);
}

char _license[] SEC("license") = "GPL";
__u32 _version SEC("version") = 0xFFFFFFFE;
