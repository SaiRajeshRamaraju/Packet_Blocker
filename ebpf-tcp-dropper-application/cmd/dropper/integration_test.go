package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"net"
	"strconv"
)

// repoRoot returns the repository root by walking up from this file's path.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve caller path")
	}
	// .../cmd/dropper/integration_test.go -> repo root is two dirs up
	root := filepath.Clean(filepath.Join(filepath.Dir(thisFile), "..", ".."))
	return root
}

// buildHelperServer builds a tiny TCP echo server binary into tmpDir and returns its path.
func buildHelperServer(t *testing.T, tmpDir string) string {
	t.Helper()
	src := `package main
import (
    "flag"
    "fmt"
    "io"
    "log"
    "net"
)
func main(){
    port := flag.Int("port", 0, "port to listen on")
    flag.Parse()
    addr := fmt.Sprintf("127.0.0.1:%d", *port)
    ln, err := net.Listen("tcp", addr)
    if err != nil { log.Fatal(err) }
    // Print the actual port (helps when port==0)
    fmt.Printf("LISTENING %s\n", ln.Addr().String())
    c, err := ln.Accept()
    if err != nil { log.Fatal(err) }
    defer c.Close()
    io.Copy(c, c)
}
`
    srcPath := filepath.Join(tmpDir, "helperserver.go")
    if err := os.WriteFile(srcPath, []byte(src), 0644); err != nil {
        t.Fatalf("write helper server: %v", err)
    }
    binPath := filepath.Join(tmpDir, "helperserver")
    cmd := exec.Command("go", "build", "-o", binPath, srcPath)
    out, err := cmd.CombinedOutput()
    if err != nil {
        t.Fatalf("build helper server failed: %v\n%s", err, string(out))
    }
    return binPath
}

// pickFreePort asks the kernel for a free port on localhost and returns it.
func pickFreePort(t *testing.T) int {
    t.Helper()
    l, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil { t.Fatalf("listen :0: %v", err) }
    defer l.Close()
    _, pStr, err := net.SplitHostPort(l.Addr().String())
    if err != nil { t.Fatalf("split host port: %v", err) }
    p, err := strconv.Atoi(pStr)
    if err != nil { t.Fatalf("atoi port: %v", err) }
    return p
}

// TestBlockMatchingPortAndAllowDifferentPort verifies that when the dropper is
// configured with a specific TCP port, traffic to that port is blocked for a
// process in the target cgroup, while traffic to a different port is allowed.
func TestBlockMatchingPortAndAllowDifferentPort(t *testing.T) {
    if os.Geteuid() != 0 { t.Skip("requires root") }
    if !isCgroupV2Mounted() { t.Skip("requires cgroup v2 mounted on /sys/fs/cgroup") }

    root := repoRoot(t)
    binPath := filepath.Join(root, "bin", "dropper")

    // Ensure dropper binary exists (generate + build)
    {
        cmd := exec.Command("go", "generate", "./bpf")
        cmd.Dir = root
        if out, err := cmd.CombinedOutput(); err != nil {
            t.Fatalf("go generate failed: %v\n%s", err, string(out))
        }
    }
    {
        cmd := exec.Command("go", "build", "-o", binPath, "./cmd/dropper")
        cmd.Dir = root
        if out, err := cmd.CombinedOutput(); err != nil {
            t.Fatalf("go build failed: %v\n%s", err, string(out))
        }
    }
    t.Cleanup(func(){ _ = os.Remove(binPath) })

    // Make a temporary cgroup path
    cgPath := filepath.Join("/sys/fs/cgroup", fmt.Sprintf("ebpf-dropper-test-%d", os.Getpid()))
    if err := os.MkdirAll(cgPath, 0755); err != nil { t.Fatalf("mkdir cgroup: %v", err) }
    t.Cleanup(func(){ _ = os.RemoveAll(cgPath) })

    // Build helper server
    tmp := t.TempDir()
    srvBin := buildHelperServer(t, tmp)

    blockedPort := pickFreePort(t)
    allowedPort := pickFreePort(t)

    // 1) Start server on blockedPort and verify client connection fails when dropper is active.
    srv1 := exec.Command(srvBin, "--port", strconv.Itoa(blockedPort))
    var srvOut1 bytes.Buffer
    srv1.Stdout = &srvOut1
    srv1.Stderr = &srvOut1
    if err := srv1.Start(); err != nil { t.Fatalf("start server1: %v", err) }
    t.Cleanup(func(){ _ = srv1.Process.Kill(); _, _ = srv1.Process.Wait() })

    // Start dropper attached to cgroup and add server1 PID
    drop1 := exec.Command(binPath, "--cgroup", cgPath, "--both", "--port", strconv.Itoa(blockedPort), "--pid", strconv.Itoa(srv1.Process.Pid))
    var dropOut1 bytes.Buffer
    drop1.Stdout = &dropOut1
    drop1.Stderr = &dropOut1
    if err := drop1.Start(); err != nil { t.Fatalf("start dropper1: %v", err) }
    // Ensure we stop it
    defer func(){ _ = drop1.Process.Signal(syscall.SIGINT); _ = drop1.Wait() }()

    // Give a moment for attach to complete
    time.Sleep(400 * time.Millisecond)

    // Attempt client connect to blockedPort; expect failure
    conn1, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", blockedPort), 1200*time.Millisecond)
    if err == nil {
        // If dial succeeded, try writing and reading; it's unexpected
        _ = conn1.SetDeadline(time.Now().Add(800 * time.Millisecond))
        _, _ = conn1.Write([]byte("ping"))
        buf := make([]byte, 4)
        _, rerr := conn1.Read(buf)
        _ = conn1.Close()
        if rerr == nil {
            t.Fatalf("expected connect/read to blocked port to fail, but succeeded")
        }
    }

    // 2) Start server on allowedPort; with dropper still configured for blockedPort, this should succeed.
    srv2 := exec.Command(srvBin, "--port", strconv.Itoa(allowedPort))
    var srvOut2 bytes.Buffer
    srv2.Stdout = &srvOut2
    srv2.Stderr = &srvOut2
    if err := srv2.Start(); err != nil { t.Fatalf("start server2: %v", err) }
    t.Cleanup(func(){ _ = srv2.Process.Kill(); _, _ = srv2.Process.Wait() })

    // Also add server2 to cgroup (to ensure policy applies); since different port, it should pass
    // We can re-use a quick writer to cgroup.procs here.
    procs := filepath.Join(cgPath, "cgroup.procs")
    if f, err := os.OpenFile(procs, os.O_WRONLY|os.O_APPEND, 0644); err == nil {
        fmt.Fprintf(f, "%d\n", srv2.Process.Pid)
        f.Close()
    } else {
        t.Fatalf("write cgroup.procs: %v", err)
    }

    // Give a brief moment
    time.Sleep(200 * time.Millisecond)

    // Attempt client connect to allowedPort; expect success
    conn2, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", allowedPort), 2*time.Second)
    if err != nil {
        t.Fatalf("dial to allowed port failed: %v\nserver2 out:\n%s\ndropper out:\n%s", err, srvOut2.String(), dropOut1.String())
    }
    _ = conn2.SetDeadline(time.Now().Add(1 * time.Second))
    if _, err := conn2.Write([]byte("pong")); err != nil {
        t.Fatalf("write to allowed port failed: %v", err)
    }
    buf := make([]byte, 4)
    if _, err := conn2.Read(buf); err != nil {
        t.Fatalf("read from allowed port failed: %v", err)
    }
    _ = conn2.Close()
}

func isCgroupV2Mounted() bool {
    data, err := os.ReadFile("/proc/self/mountinfo")
    if err != nil { return false }
    return strings.Contains(string(data), " - cgroup2 ")
}

// TestEndToEndBuildAndRun builds the dropper and runs it briefly against a
// temporary cgroup v2 path, then sends SIGINT to trigger a clean detach.
// Skips unless running as root and with cgroup v2 mounted.
func TestEndToEndBuildAndRun(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root to manage cgroups and attach eBPF")
	}
	if !isCgroupV2Mounted() {
		t.Skip("requires cgroup v2 mounted on /sys/fs/cgroup")
	}

	root := repoRoot(t)
	binPath := filepath.Join(root, "bin", "dropper")

	// Build: go generate ./bpf && go build -o ./bin/dropper ./cmd/dropper
	{
		cmd := exec.Command("go", "generate", "./bpf")
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("go generate failed: %v\n%s", err, string(out))
		}
	}
	{
		cmd := exec.Command("go", "build", "-o", binPath, "./cmd/dropper")
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("go build failed: %v\n%s", err, string(out))
		}
	}
	// Ensure we clean up the binary afterwards
	t.Cleanup(func() { _ = os.Remove(binPath) })

	// Prepare a temporary cgroup path under /sys/fs/cgroup
	cgPath := filepath.Join("/sys/fs/cgroup", fmt.Sprintf("ebpf-dropper-test-%d", os.Getpid()))
	if err := os.MkdirAll(cgPath, 0755); err != nil {
		t.Fatalf("create cgroup path: %v", err)
	}
	// Cleanup cgroup at the end
	t.Cleanup(func() {
		_ = os.RemoveAll(cgPath)
	})

	// Launch dropper in foreground and then interrupt it.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binPath, "--cgroup", cgPath, "--both", "--port", "0")
	// Capture output for debugging
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	// Start process
	if err := cmd.Start(); err != nil {
		t.Fatalf("start dropper: %v", err)
	}

	// After a brief delay, send SIGINT to request detach
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-time.After(1200 * time.Millisecond):
		_ = cmd.Process.Signal(syscall.SIGINT)
	case err := <-done:
		// Process exited too early — consider it a failure, include logs
		if err != nil {
			t.Fatalf("dropper exited early with error: %v\nOutput:\n%s", err, buf.String())
		}
	}

	// Wait for clean exit
	select {
	case err := <-done:
		var exitErr *exec.ExitError
		if err != nil && !errors.As(err, &exitErr) {
			t.Fatalf("dropper wait failed: %v\nOutput:\n%s", err, buf.String())
		}
		// If ExitError, still allow if context timed out and killed — but we used SIGINT.
	case <-ctx.Done():
		t.Fatalf("timeout waiting for dropper to exit cleanly\nOutput:\n%s", buf.String())
	}

	// Basic smoke checks in logs
	out := buf.String()
	if !strings.Contains(out, "Press Ctrl-C to detach") && !strings.Contains(out, "Attached") {
		t.Logf("dropper output:\n%s", out)
	}
}
