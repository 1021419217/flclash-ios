import Foundation
import NetworkExtension
import UIKit
import os

@MainActor
final class TunnelController {
  private let sharedStateStore: SharedStateStore
  private let managerStore: TunnelManagerStore
  private let coordinator: TunnelCoordinator

  private var tunnelStatusObserver: NSObjectProtocol?
  private var appActiveObserver: NSObjectProtocol?
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.chenx.flclash",
    category: "TunnelController"
  )

  init(
    sharedStateStore: SharedStateStore,
    onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
    onConnectionStateChanged: @escaping (String) -> Void,
    onExternalStart: @escaping () -> Void,
    onExternalStop: @escaping () -> Void
  ) {
    let networkExtensionIdentifier =
      "\(Bundle.main.bundleIdentifier!).NECore"
    let managerStore = TunnelManagerStore(
      sharedStateStore: sharedStateStore,
      networkExtensionIdentifier: networkExtensionIdentifier,
      localizedDescription: "FlClash"
    )
    self.sharedStateStore = sharedStateStore
    self.managerStore = managerStore
    coordinator = TunnelCoordinator(
      managerStore: managerStore,
      onTunnelStateChanged: onTunnelStateChanged,
      onConnectionStateChanged: onConnectionStateChanged,
      onExternalStart: onExternalStart,
      onExternalStop: onExternalStop
    )
  }

  deinit {
    if let tunnelStatusObserver {
      NotificationCenter.default.removeObserver(tunnelStatusObserver)
    }
    if let appActiveObserver {
      NotificationCenter.default.removeObserver(appActiveObserver)
    }
  }

  func startObserving() {
    if tunnelStatusObserver == nil {
      tunnelStatusObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor in
          self?.coordinator.handleTunnelStatusNotification(notification)
        }
      }
    }
    if appActiveObserver == nil {
      appActiveObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.coordinator.requestStatusRefresh(notifyExternal: true)
        }
      }
    }
    coordinator.requestStatusRefresh(notifyExternal: false)
  }

  func start() {
    coordinator.submitTunnelRequest(target: .running)
  }

  /// Starts the tunnel and waits until the system reports it connected.
  ///
  /// The Flutter side treats a successful start as "the core is running" and
  /// starts its uptime clock, so answering before the network extension is up
  /// makes the app look connected while every packet still goes out unproxied.
  /// Returns nil on success, or a message describing why it gave up.
  func startAndConfirm(timeout: TimeInterval = 25) async -> String? {
    coordinator.submitTunnelRequest(target: .running)
    let deadline = Date().addingTimeInterval(timeout)
    var sawProgress = false
    while Date() < deadline {
      if await isCoreActive() {
        return nil
      }
      do {
        if let manager = try await managerStore.loadManager(
          createIfNeeded: false
        ) {
          let status = manager.connection.status
          if status == .connecting || status == .reasserting {
            sawProgress = true
          }
          if status == .invalid {
            // A configuration the system rejects never reaches connecting.
            return startFailure(
              detail: coordinator.lastFailureDescription
                ?? "the tunnel configuration was rejected"
            )
          }
          if status == .disconnected {
            if let failure = coordinator.lastFailureDescription {
              return startFailure(detail: failure)
            }
            if sawProgress {
              return startFailure(
                detail: "the tunnel stopped before it connected"
              )
            }
          }
        }
      } catch {
        log("start poll failed: \(error.localizedDescription)")
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return startFailure(
      detail: coordinator.lastFailureDescription
        ?? "timed out waiting for the tunnel"
    )
  }

  private func startFailure(detail: String) -> String {
    let lower = detail.lowercased()
    if lower.contains("already") || lower.contains("another")
      || lower.contains("active") || lower.contains("in use")
    {
      return "另一个 VPN 正在运行，请先断开（例如 Surge）再启动 FlClash。"
    }
    return "网络扩展未能启动：\(detail)"
  }

  func publishConnectionState() {
    coordinator.publishConnectionState()
    coordinator.requestStatusRefresh(notifyExternal: false)
  }

  func stop() {
    coordinator.submitTunnelRequest(target: .stopped)
  }

  func toggle() {
    coordinator.toggleTunnelRequest()
  }

  func reloadOnDemandRules() async throws {
    try await coordinator.reloadOnDemandRules()
  }

  func sendProviderMessage(_ data: Data) async throws -> String {
    let manager: NETunnelProviderManager?
    do {
      manager = try await managerStore.loadManager(createIfNeeded: false)
    } catch {
      throw ProviderMessageError(
        code: "network_extension_error",
        message: error.localizedDescription
      )
    }
    guard let manager,
      manager.connection.status.tunnelState == .running,
      let session = manager.connection as? NETunnelProviderSession
    else {
      throw ProviderMessageError(
        code: "network_extension_unavailable",
        message: "network extension is not running"
      )
    }

    return try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(data) { response in
          Task { @MainActor in
            guard let response,
              let message = String(data: response, encoding: .utf8)
            else {
              continuation.resume(
                throwing: ProviderMessageError(
                  code: "empty_response",
                  message: "empty network extension response"
                )
              )
              return
            }
            continuation.resume(returning: message)
          }
        }
      } catch {
        continuation.resume(
          throwing: ProviderMessageError(
            code: "network_extension_error",
            message: error.localizedDescription
          )
        )
      }
    }
  }

  func isCoreActive() async -> Bool {
    do {
      let manager = try await managerStore.loadManager(createIfNeeded: false)
      return manager?.connection.status.tunnelState == .running
    } catch {
      log("isCoreActive failed: \(error.localizedDescription)")
      return false
    }
  }

  func getRunTime() async -> Int {
    guard await isCoreActive() else {
      return 0
    }
    return sharedStateStore.runTime()
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
