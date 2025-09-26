package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAddPidToCgroup_WritesPID(t *testing.T) {
	dir := t.TempDir()
	procsPath := filepath.Join(dir, "cgroup.procs")
	if err := os.WriteFile(procsPath, []byte(""), 0644); err != nil {
		t.Fatalf("prepare cgroup.procs: %v", err)
	}

	pid := 4242
	if err := addPidToCgroup(dir, pid); err != nil {
		t.Fatalf("addPidToCgroup failed: %v", err)
	}

	data, err := os.ReadFile(procsPath)
	if err != nil {
		t.Fatalf("read back cgroup.procs: %v", err)
	}
	got := string(data)
	want := "4242\n"
	if got != want {
		t.Fatalf("unexpected content. got=%q want=%q", got, want)
	}
}

func TestContains(t *testing.T) {
	if !contains("hello world", "world") {
		t.Fatal("expected substring to be found")
	}
	if contains("hello", "xyz") {
		t.Fatal("did not expect substring to be found")
	}
}
