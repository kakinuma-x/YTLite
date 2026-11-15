package main

import (
	"bufio"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

type SysInfo struct {
	OS        string `json:"os"`
	Arch      string `json:"arch"`
	Chip      string `json:"chip"`
	RAMTotal  int64  `json:"ram_total"`
	RAMAvail  int64  `json:"ram_avail"`
	Cores     int    `json:"cores"`      // logical
	PerfCores int    `json:"perf_cores"` // physical performance cores
}

func sysctl(name string) string {
	out, err := exec.Command("sysctl", "-n", name).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func meminfo(key string) int64 {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) >= 2 && fs[0] == key+":" {
			n, _ := strconv.ParseInt(fs[1], 10, 64)
			return n * 1024
		}
	}
	return 0
}

// darwinAvail estimates reclaimable memory from vm_stat (free + inactive +
// speculative + purgeable pages).
func darwinAvail() int64 {
	out, err := exec.Command("vm_stat").Output()
	if err != nil {
		return 0
	}
	page := int64(4096)
	var pages int64
	for _, line := range strings.Split(string(out), "\n") {
		if i := strings.Index(line, "page size of "); i >= 0 {
			fs := strings.Fields(line[i+len("page size of "):])
			if len(fs) > 0 {
				if n, err := strconv.ParseInt(fs[0], 10, 64); err == nil {
					page = n
				}
			}
			continue
		}
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "Pages free", "Pages inactive", "Pages speculative", "Pages purgeable":
			n, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimSpace(v), "."), 10, 64)
			pages += n
		}
	}
	return pages * page
}

var staticSys *SysInfo

func sysInfo() SysInfo {
	if staticSys == nil {
		s := SysInfo{OS: runtime.GOOS, Arch: runtime.GOARCH, Cores: runtime.NumCPU()}
		if runtime.GOOS == "darwin" {
			s.RAMTotal, _ = strconv.ParseInt(sysctl("hw.memsize"), 10, 64)
			s.Chip = sysctl("machdep.cpu.brand_string")
			for _, k := range []string{"hw.perflevel0.physicalcpu", "hw.physicalcpu"} {
				if n, _ := strconv.Atoi(sysctl(k)); n > 0 {
					s.PerfCores = n
					break
				}
			}
		} else {
			s.RAMTotal = meminfo("MemTotal")
		}
		if s.PerfCores <= 0 {
			s.PerfCores = max(1, s.Cores/2)
		}
		staticSys = &s
	}
	s := *staticSys
	if runtime.GOOS == "darwin" {
		s.RAMAvail = darwinAvail()
	} else {
		s.RAMAvail = meminfo("MemAvailable")
	}
	return s
}

const gib = int64(1) << 30

// autoContext picks a context window that keeps the KV cache small on
// low-memory machines.
func autoContext(ram int64) int {
	switch {
	case ram <= 4*gib+gib/2:
		return 2048
	case ram <= 8*gib+gib/2:
		return 4096
	default:
		return 8192
	}
}

// autoGPULayers: Metal on Apple Silicon shares memory with the CPU and is
// much faster; Intel Macs and other machines stay on the CPU.
func autoGPULayers() int {
	if runtime.GOOS == "darwin" && runtime.GOARCH == "arm64" {
		return 99
	}
	return 0
}

// memNeed estimates resident memory for a GGUF of the given size.
func memNeed(size int64) int64 { return size + size/5 + gib/2 }

// fit rates how well a model fits: "good", "ok", "tight" or "no".
func fit(size, ram int64) string {
	if size <= 0 || ram <= 0 {
		return "unknown"
	}
	reserve := max(2*gib, ram*35/100) // macOS itself and other apps
	budget := ram - reserve
	need := memNeed(size)
	switch {
	case need <= budget*6/10:
		return "good"
	case need <= budget:
		return "ok"
	case need <= ram*85/100:
		return "tight"
	default:
		return "no"
	}
}
