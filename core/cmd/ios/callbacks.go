//go:build ios && cgo

package main

/*
#include "bride.h"
*/
import "C"

import "unsafe"

// iosTunCallbacks forwards the core's socket questions to the Network
// Extension through the function pointers Swift installs in bride.c.
type iosTunCallbacks struct {
	handle unsafe.Pointer
}

func (c iosTunCallbacks) Protect(fd int) bool {
	if c.handle == nil {
		return false
	}
	return C.protect(c.handle, C.int(fd)) != 0
}

func (c iosTunCallbacks) ResolveUid(protocol int, source, target string) int {
	if c.handle == nil {
		return -1
	}
	s := C.CString(source)
	defer C.free(unsafe.Pointer(s))
	t := C.CString(target)
	defer C.free(unsafe.Pointer(t))
	return int(C.resolve_uid(c.handle, C.int(protocol), s, t))
}

func (c iosTunCallbacks) ResolvePackage(uid int) string {
	if c.handle == nil {
		return ""
	}
	return takeCString(C.resolve_package(c.handle, C.int(uid)))
}

func takeCString(s *C.char) string {
	if s == nil {
		return ""
	}
	defer C.free_string(s)
	return C.GoString(s)
}

func invokeResult(callback unsafe.Pointer, data string) {
	if callback == nil {
		return
	}
	s := C.CString(data)
	defer C.free(unsafe.Pointer(s))
	C.result(callback, s)
}

func releaseObject(callback unsafe.Pointer) {
	if callback == nil {
		return
	}
	C.release_object(callback)
}

func retainObject(callback unsafe.Pointer) unsafe.Pointer {
	if callback == nil {
		return nil
	}
	return C.retain_object(callback)
}
