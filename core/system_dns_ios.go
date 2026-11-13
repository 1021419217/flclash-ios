//go:build ios

package core

// updateSystemDns is a no-op on iOS: the packet tunnel cannot rewrite the
// system resolver, and mihomo's DNS listeners already take the configured
// servers from the profile.
func updateSystemDns(addr []string) {}
