//go:build ios && cgo

package tun

import (
	"encoding/json"
	"net"
	"net/netip"
	"strings"
	"syscall"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// iosOptions mirrors what the Network Extension sends. The Dart side fills it
// from the same payload the Android path uses, so the JSON keys stay in the
// camelCase form the Flutter layer already produces.
type iosOptions struct {
	MTU                    uint32 `json:"mtu"`
	CongestionController   string `json:"congestionController"`
	RecvMsgX               bool   `json:"recvMsgX"`
	SendMsgX               bool   `json:"sendMsgX"`
	DisableICMPForwarding  bool   `json:"disableIcmpForwarding"`
	EndpointIndependentNAT bool   `json:"endpointIndependentNat"`
}

// Start takes the utun descriptor the Network Extension opened. Addresses,
// routes and DNS belong to the extension, so AutoRoute and AutoDetectInterface
// stay off; the core only reads and writes packets on the fd. The descriptor is
// duplicated because the extension keeps its own handle on it.
func Start(fd int, stack, address, dns, rawOptions string) *sing_tun.Listener {
	if fd <= 0 {
		return nil
	}
	var settings iosOptions
	if err := json.Unmarshal([]byte(rawOptions), &settings); err != nil {
		log.Errorln("TUN: %v", err)
		return nil
	}

	tunFd, err := syscall.Dup(fd)
	if err != nil {
		log.Errorln("TUN: dup fd: %v", err)
		return nil
	}

	var prefix4 []netip.Prefix
	var prefix6 []netip.Prefix
	for _, a := range strings.Split(address, ",") {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		prefix, parseErr := netip.ParsePrefix(a)
		if parseErr != nil {
			_ = syscall.Close(tunFd)
			log.Errorln("TUN: %v", parseErr)
			return nil
		}
		if prefix.Addr().Is4() {
			prefix4 = append(prefix4, prefix)
		} else {
			prefix6 = append(prefix6, prefix)
		}
	}

	tunStack, ok := constant.StackTypeMapping[strings.ToLower(stack)]
	if !ok {
		tunStack = constant.TunMips
	}

	var dnsHijack []string
	for _, d := range strings.Split(dns, ",") {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		dnsHijack = append(dnsHijack, net.JoinHostPort(d, "53"))
	}

	options := LC.Tun{
		Enable:                 true,
		Device:                 "FlClash",
		Stack:                  tunStack,
		RecvMsgX:               settings.RecvMsgX,
		SendMsgX:               settings.SendMsgX,
		DNSHijack:              dnsHijack,
		AutoRoute:              false,
		AutoDetectInterface:    false,
		Inet4Address:           prefix4,
		Inet6Address:           prefix6,
		MTU:                    settings.MTU,
		FileDescriptor:         tunFd,
		DisableICMPForwarding:  settings.DisableICMPForwarding,
		EndpointIndependentNat: settings.EndpointIndependentNAT,
		CongestionController:   settings.CongestionController,
		LoopbackAddress: []netip.Addr{
			netip.MustParseAddr("10.7.0.1"),
		},
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		_ = syscall.Close(tunFd)
		log.Errorln("TUN: %v", err)
		return nil
	}
	return listener
}
