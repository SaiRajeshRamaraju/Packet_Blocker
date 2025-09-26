CLANG ?= clang
LLC ?= llc
BPFTOOL ?= bpftool

TARGET = simple-port-filter

all: $(TARGET).o

%.o: %.c
	$(CLANG) -target bpf -D__TARGET_ARCH_x86_64 -I/usr/include/x86_64-linux-gnu -g \
        -O2 -Wall -c $< -o $@

clean:
	rm -f *.o

load: $(TARGET).o
	sudo $(BPFTOOL) prog load $< /sys/fs/bpf/$(TARGET)

unload:
	sudo rm -f /sys/fs/bpf/$(TARGET)

attach: load
	sudo $(BPFTOOL) cgroup attach /sys/fs/cgroup/unified connect4 pinned /sys/fs/bpf/$(TARGET)

detach:
	sudo $(BPFTOOL) cgroup detach /sys/fs/cgroup/unified connect4 pinned /sys/fs/bpf/$(TARGET)

.PHONY: all clean load unload attach detach
