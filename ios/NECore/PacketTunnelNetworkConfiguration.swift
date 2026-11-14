import Darwin
import NetworkExtension
import os

final class PacketTunnelNetworkConfiguration {
  private let ipv4Address = "198.18.0.1"
  private let ipv4AddressPrefix = "198.18.0.1/30"
  private let ipv4SubnetMask = "255.255.255.252"
  private let ipv4DNS = "198.18.0.2"
  private let ipv6Address = "fdfe:dcba:9876::1"
  private let ipv6AddressPrefix = "fdfe:dcba:9876::1/126"
  private let ipv6DNS = "fdfe:dcba:9876::2"
  private let netAny = "0.0.0.0"

  // Shadowrocket / Loon / Quantumult X expose this switch as
  // "排除路由 0.0.0.0/31". Open-source Network Extension code (OneXray
  // swift/Tunnel/PacketTunnelProvider.swift, AdGuard
  // PacketTunnelSettingsProvider.swift) implements it by KEEPING the literal
  // default route and adding 0.0.0.0/31 (v6: ::/127) to excludedRoutes; iOS
  // subtracts the exclusions from 0.0.0.0/0 and stops drawing the badge.
  // The remaining entries keep private/bypassed networks direct -- Dart
  // normally folds them into routeAddress, which we deliberately do not use
  // while hiding the icon.
  private static let hideIconV4Exclusions: [(String, Int)] = [
    ("0.0.0.0", 31),
    ("10.0.0.0", 8),
    ("127.0.0.0", 8),
    ("169.254.0.0", 16),
    ("172.16.0.0", 12),
    ("192.168.0.0", 16),
    ("224.0.0.0", 4),
    ("255.255.255.255", 32),
  ]
  private static let hideIconV6Exclusions: [(String, Int)] = [
    ("::", 127),
    ("fc00::", 7),
    ("fe80::", 10),
    ("ff00::", 8),
  ]

  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "PacketTunnelNetworkConfiguration"
  )

  func makeSettings(
    for options: PacketTunnelVPNOptions,
    hideVpnIcon: Bool = false
  ) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(
      tunnelRemoteAddress: "127.0.0.1"
    )
    settings.mtu = NSNumber(value: options.mtu)

    let ipv4Settings = NEIPv4Settings(
      addresses: [ipv4Address],
      subnetMasks: [ipv4SubnetMask]
    )
    let ipv4Routes = options.routeAddress.compactMap {
      route -> NEIPv4Route? in
      guard route.contains("."),
        let cidr = CIDR(route),
        let subnetMask = ipv4SubnetMask(
          prefixLength: cidr.prefixLength
        )
      else {
        return nil
      }
      return NEIPv4Route(
        destinationAddress: cidr.address,
        subnetMask: subnetMask
      )
    }
    if hideVpnIcon {
      // 0.9.12 / 0.9.13 never reached their split-route branch: Dart's
      // vpnRouteAddress() returns a long CIDR list whenever
      // bypassPrivateRoute is on (the default), so ipv4Routes is NOT empty.
      // 0.9.13 additionally removed the default route, which the badge logic
      // depends on ("Keep the default routes" in OneXray's implementation).
      //
      // Correct behavior: declare 0.0.0.0/0 and exclude 0.0.0.0/31. iOS
      // subtracts the exclusions itself, so no CIDR math is needed here.
      ipv4Settings.includedRoutes = [.default()]
      ipv4Settings.excludedRoutes = Self.hideIconV4Exclusions.compactMap {
        entry in
        guard let mask = self.ipv4SubnetMask(prefixLength: entry.1) else {
          return nil
        }
        return NEIPv4Route(destinationAddress: entry.0, subnetMask: mask)
      }
      // Long literal stays visible in the Mach-O for delivery verification;
      // short strings like "0.0.0.0/31" get inlined by Swift SmallString.
      logger.info(
        "hideVpnIcon: keep default route, apply 0.0.0.0/31 exclusion"
      )
    } else {
      ipv4Settings.includedRoutes = ipv4Routes.isEmpty
        ? [.default()]
        : ipv4Routes
    }
    settings.ipv4Settings = ipv4Settings

    var ipv6RouteCount = 0
    if options.ipv6 {
      let ipv6Settings = NEIPv6Settings(
        addresses: [ipv6Address],
        networkPrefixLengths: [NSNumber(value: 126)]
      )
      let ipv6Routes = options.routeAddress.compactMap {
        route -> NEIPv6Route? in
        guard route.contains(":"),
          let cidr = CIDR(route)
        else {
          return nil
        }
        return NEIPv6Route(
          destinationAddress: cidr.address,
          networkPrefixLength: NSNumber(value: cidr.prefixLength)
        )
      }
      ipv6RouteCount = ipv6Routes.count
      if hideVpnIcon {
        // v6 counterpart: keep ::/0 and exclude ::/127 plus the ULA,
        // link-local and multicast ranges Dart would otherwise fold into
        // routeAddress. OneXray applies the same ::/127 on iOS.
        ipv6Settings.includedRoutes = [.default()]
        ipv6Settings.excludedRoutes = Self.hideIconV6Exclusions.map {
          entry in
          NEIPv6Route(
            destinationAddress: entry.0,
            networkPrefixLength: NSNumber(value: entry.1)
          )
        }
      } else {
        ipv6Settings.includedRoutes = ipv6Routes.isEmpty
          ? [.default()]
          : ipv6Routes
      }
      settings.ipv6Settings = ipv6Settings
    }

    let dnsServers = options.ipv6
      ? [ipv4DNS, ipv6DNS]
      : [ipv4DNS]
    let dnsSettings = NEDNSSettings(servers: dnsServers)
    if options.captureDns {
      dnsSettings.matchDomains = [""]
    }
    settings.dnsSettings = dnsSettings

    if options.systemProxy {
      let proxySettings = NEProxySettings()
      proxySettings.httpEnabled = true
      proxySettings.httpServer = NEProxyServer(
        address: "127.0.0.1",
        port: options.port
      )
      proxySettings.httpsEnabled = true
      proxySettings.httpsServer = NEProxyServer(
        address: "127.0.0.1",
        port: options.port
      )
      proxySettings.exceptionList = options.bypassDomain
      settings.proxySettings = proxySettings
    }

    logger.debug(
      "makeSettings ipv4Routes=\(ipv4Routes.count, privacy: .public) ipv6Routes=\(ipv6RouteCount, privacy: .public) hideVpnIcon=\(hideVpnIcon, privacy: .public)"
    )
    return settings
  }

  func tunAddress(for options: PacketTunnelVPNOptions) -> String {
    options.ipv6
      ? "\(ipv4AddressPrefix),\(ipv6AddressPrefix)"
      : ipv4AddressPrefix
  }

  func tunDNS(for options: PacketTunnelVPNOptions) -> String {
    if options.captureDns {
      return netAny
    }
    return options.ipv6 ? "\(ipv4DNS),\(ipv6DNS)" : ipv4DNS
  }

  func tunnelFileDescriptor() -> Int32? {
    var controlInfo = ctl_info()
    withUnsafeMutablePointer(to: &controlInfo.ctl_name) {
      $0.withMemoryRebound(
        to: CChar.self,
        capacity: MemoryLayout.size(ofValue: $0.pointee)
      ) {
        _ = strcpy($0, "com.apple.net.utun_control")
      }
    }
    for fileDescriptor: Int32 in 0...1024 {
      var address = sockaddr_ctl()
      var result: Int32 = -1
      var length = socklen_t(MemoryLayout.size(ofValue: address))
      withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          result = getpeername(fileDescriptor, $0, &length)
        }
      }
      if result != 0 || address.sc_family != AF_SYSTEM {
        continue
      }
      if controlInfo.ctl_id == 0 {
        result = ioctl(fileDescriptor, CTLIOCGINFO, &controlInfo)
        if result != 0 {
          continue
        }
      }
      if address.sc_id == controlInfo.ctl_id {
        return fileDescriptor
      }
    }
    return nil
  }

  private func ipv4SubnetMask(prefixLength: Int) -> String? {
    guard (0...32).contains(prefixLength) else {
      return nil
    }
    let mask = prefixLength == 0
      ? 0
      : UInt32.max << UInt32(32 - prefixLength)
    return [
      (mask >> 24) & 0xff,
      (mask >> 16) & 0xff,
      (mask >> 8) & 0xff,
      mask & 0xff,
    ].map { String($0) }.joined(separator: ".")
  }
}

private struct CIDR {
  let address: String
  let prefixLength: Int

  init?(_ value: String) {
    let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2,
      let prefixLength = Int(parts[1])
    else {
      return nil
    }
    address = parts[0]
    self.prefixLength = prefixLength
  }
}
