//go:build ios && cgo

// Package main builds the iOS core as a C archive. The Network Extension
// owns the packet tunnel; this bridge only forwards method calls and hands
// the TUN descriptor over, exactly like the Android gomobile entry does.
package main

/*
#include "bride.h"
*/
import "C"

import (
	"encoding/json"
	"unsafe"

	"core"
)

func main() {}

// tunOptions is the shape the Dart side sends for the iOS tunnel.
type tunOptions struct {
	Stack                  string `json:"stack"`
	Address                string `json:"address"`
	DNS                    string `json:"dns"`
	MTU                    uint32 `json:"mtu"`
	CongestionController   string `json:"congestionController"`
	RecvMsgX               bool   `json:"recvMsgX"`
	SendMsgX               bool   `json:"sendMsgX"`
	DisableICMPForwarding  bool   `json:"disableIcmpForwarding"`
	EndpointIndependentNAT bool   `json:"endpointIndependentNat"`
}

//export invokeMethod
func invokeMethod(callback unsafe.Pointer, paramsChar *C.char) {
	params := takeCString(paramsChar)
	core.InvokeMethod(params, func(result []byte) {
		invokeResult(callback, string(result))
	})
}

//export startTUN
func startTUN(callback unsafe.Pointer, fd C.int, optionsChar *C.char) bool {
	raw := takeCString(optionsChar)
	var options tunOptions
	if err := json.Unmarshal([]byte(raw), &options); err != nil {
		if callback != nil {
			releaseObject(callback)
		}
		return false
	}
	// tun_ios.go reads the same camelCase blob the Dart layer produced.
	rest, err := json.Marshal(options)
	if err != nil {
		if callback != nil {
			releaseObject(callback)
		}
		return false
	}
	return core.StartTun(
		iosTunCallbacks{handle: callback},
		int(fd),
		options.Stack,
		options.Address,
		options.DNS,
		string(rest),
	)
}

//export quickSetup
func quickSetup(callback unsafe.Pointer, initParamsChar *C.char, setupParamsChar *C.char) {
	initParams := takeCString(initParamsChar)
	setupParams := takeCString(setupParamsChar)
	core.QuickSetup(initParams, setupParams, func(message string) {
		invokeResult(callback, message)
	})
}

//export setEventListener
func setEventListener(listener unsafe.Pointer) {
	core.SetEventListener(func(data []byte) {
		invokeResult(listener, string(data))
	})
}

//export getTotalTraffic
func getTotalTraffic(onlyStatisticsProxy C.int) *C.char {
	return C.CString(core.GetTotalTraffic(onlyStatisticsProxy != 0))
}

//export getTraffic
func getTraffic(onlyStatisticsProxy C.int) *C.char {
	return C.CString(core.GetTraffic(onlyStatisticsProxy != 0))
}

//export stopTun
func stopTun() {
	core.StopTun()
}

//export startListener
func startListener() {
	core.StartListener()
}

//export stopListener
func stopListener() {
	core.StopListener()
}

//export forceGC
func forceGC() {
	core.ForceGC()
}

//export updateDns
func updateDns(valueChar *C.char) {
	core.UpdateDns(takeCString(valueChar))
}

//export updateNetwork
func updateNetwork(interfaceNameChar *C.char, gatewayChar *C.char) {
	// iOS reports route changes through the tunnel itself; clearing the cached
	// resolution is enough to make the core dial over the new interface.
	_ = takeCString(interfaceNameChar)
	_ = takeCString(gatewayChar)
	core.ResetNetwork()
}
