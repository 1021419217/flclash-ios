//go:build ios && cgo

package platform

import "net"

// iOS has no procfs; the Network Extension reports the owner of a socket
// through the protect/resolve callbacks instead.
func QuerySocketUidFromProcFs(source, target net.Addr) int {
	return -1
}

func ShouldBlockConnection() bool {
	return false
}

func RequiresProtectCallback() bool {
	return false
}

func CloseRejectedTunDescriptor(fd int) {
}
