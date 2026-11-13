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

// maxIOSMtu keeps the tun under the phone's own link MTU.
const maxIOSMtu = 1500

// Start takes ownership of fd. iOS hands over the utun descriptor opened by
// the PacketTunnelProvider; routes and addresses are configured by the
// extension itself, so the core must not try to own them (AutoRoute stays
// off). A loopback address is still needed for mihomo's DNS hijack path.
func Start(fd int, stack, address, dns, rawOptions string) *sing_tun.Listener {
	if fd <= 0 {
		return nil
	}
	var settings iosOptions
	if err := json.Unmarshal([]byte(rawOptions), &settings); err != nil {
		log.Errorln("TUN: %v", err)
		_ = syscall.Close(fd)
		return nil
	}

	dupFd, err := syscall.Dup(fd)
	if err != nil {
		log.Errorln("TUN: dup fd: %v", err)
		_ = syscall.Close(fd)
		return nil
	}
	defer func() { _ = syscall.Close(fd) }()

	var prefix4 []netip.Prefix
	var prefix6 []netip.Prefix
	for _, a := range strings.Split(address, ",") {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		prefix, parseErr := netip.ParsePrefix(a)
		if parseErr != nil {
			_ = syscall.Close(dupFd)
			log.Errorln("TUN: %v", parseErr)
			return nil
		}
		if prefix.Addr().Is4() {
			prefix4 = append(prefix4, prefix)
		} else {
			prefix6 = append(prefix6, prefix)
		}
	}

	// Only gvisor is proven under the iOS sandbox. The system stack wants a
	// routing table the extension cannot own, mixed builds on system, and
	// mips has never run on this platform; any of them leaves the tunnel up
	// while nothing moves.
	tunStack, ok := constant.StackTypeMapping[strings.ToLower(stack)]
	if !ok || tunStack != constant.TunGvisor {
		tunStack = constant.TunGvisor
	}

	var dnsHijack []string
	for _, d := range strings.Split(dns, ",") {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		dnsHijack = append(dnsHijack, net.JoinHostPort(d, "53"))
	}

	// 9000 is the Android default, where the tun is a plain virtual device.
	// On a phone the real link is 1500, and segments over it stall every page
	// while DNS and the handshakes still get through.
	mtu := settings.MTU
	if mtu == 0 || mtu > maxIOSMtu {
		mtu = maxIOSMtu
	}

	options := LC.Tun{
		Enable:    true,
		Device:    "FlClash",
		Stack:     tunStack,
		RecvMsgX:  settings.RecvMsgX,
		SendMsgX:  settings.SendMsgX,
		DNSHijack: dnsHijack,
		AutoRoute: false,
		// The extension's own sockets already sit outside the tunnel it
		// creates, so there is nothing to bind around; asking for an
		// interface monitor would only add a route socket this sandbox may
		// refuse, and the tun would never come up.
		AutoDetectInterface:    false,
		Inet4Address:           prefix4,
		Inet6Address:           prefix6,
		MTU:                    mtu,
		FileDescriptor:         dupFd,
		DisableICMPForwarding:  settings.DisableICMPForwarding,
		EndpointIndependentNat: settings.EndpointIndependentNAT,
		CongestionController:   settings.CongestionController,
		LoopbackAddress: []netip.Addr{
			netip.MustParseAddr("10.7.0.1"),
		},
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		_ = syscall.Close(dupFd)
		log.Errorln("TUN: %v", err)
		return nil
	}
	return listener
}
