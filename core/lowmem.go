//go:build with_low_memory

package core

import "runtime/debug"

// The Network Extension is capped at ~50 MB, and the Go runtime happily grows
// its heap past that before the OS kills the process. Telling the collector
// where the ceiling is makes it collect early instead of dying at the cap.
const lowMemoryLimit = 32 * 1024 * 1024

func init() {
	debug.SetMemoryLimit(lowMemoryLimit)
}
