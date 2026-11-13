//go:build android

package core

import "github.com/metacubex/mihomo/dns"

// updateSystemDns rewrites the resolvers the Android stack hands to libc.
// mihomo only ships that helper for Android, where the system DNS is read back
// from the tun interface.
func updateSystemDns(addr []string) {
	dns.UpdateSystemDNS(addr)
	dns.FlushCacheWithDefaultResolver()
}
