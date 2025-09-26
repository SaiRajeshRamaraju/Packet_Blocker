
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define SERVER_IP "127.0.0.1"
#define ALLOWED_PORT 4040
#define BLOCKED_PORT 4041

void test_connection(int port) {
    int sockfd;
    struct sockaddr_in servaddr;
    
    // Create socket
    if ((sockfd = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
        perror("Socket creation failed");
        return;
    }
    
    memset(&servaddr, 0, sizeof(servaddr));
    
    // Configure server address
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons(port);
    
    // Convert IPv4 address from text to binary form
    if (inet_pton(AF_INET, SERVER_IP, &servaddr.sin_addr) <= 0) {
        perror("Invalid address/ Address not supported");
        close(sockfd);
        return;
    }
    
    printf("Attempting to connect to port %d... ", port);
    fflush(stdout);
    
    // Try to connect
    if (connect(sockfd, (struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) {
        printf("Failed (Blocked by BPF filter)\n");
    } else {
        printf("Success (Allowed by BPF filter)\n");
        close(sockfd);
    }
}

int main() {
    printf("=== BPF Port Filter Tester ===\n");
    printf("This program will test connections to different ports.\n");
    printf("Port %d should be ALLOWED by the BPF filter\n", ALLOWED_PORT);
    printf("Port %d should be BLOCKED by the BPF filter\n\n", BLOCKED_PORT);
    
    // Wait a moment for the user to read the info
    sleep(2);
    
    // Test allowed port (4040)
    test_connection(ALLOWED_PORT);
    
    // Test blocked port (4041)
    test_connection(BLOCKED_PORT);
    
    printf("\nTest complete. Check the results above.\n");
    return 0;
}
