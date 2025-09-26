//go:build linux

package main

// This file contains the go:generate directive to produce Go bindings and
// object files from the eBPF C source. The generated files will live in this
// package so main.go can reference bpfObjects and loadBpfObjects directly.

//go:generate go run github.com/cilium/ebpf/cmd/bpf2go -cc clang bpf ../../bpf/drop_tcp.bpf.c
