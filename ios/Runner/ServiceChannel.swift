import Flutter
import Foundation
import os

@MainActor
private final class CoreMessageRouterReference {
  weak var value: CoreMessageRouter?
}

enum QuickAction: String {
  case start
  case stop
  case toggle

  // Before the engine is up only the latest intent survives: a toggle flips a pending start or
  // stop, and two toggles cancel out.
  func folded(onto pending: QuickAction?) -> QuickAction? {
    guard self == .toggle, let pending else {
      return self
    }
    switch pending {
    case .start:
      return .stop
    case .stop:
      return .start
    case .toggle:
      return nil
    }
  }
}

@MainActor
final class ServiceChannel {
  private static var instance: ServiceChannel?
  private static var pendingQuickAction: QuickAction?

  // Dart addresses these channels with its package name (lib/common/constant.dart),
  // which is deliberately not the bundle id; the two drifted apart once the iOS
  // layer was ported over and every call started raising MissingPluginException.
  private static let channelPrefix = "com.follow.clash"
  private let channel: FlutterMethodChannel
  // Dart routes core calls to `<prefix>/core` while the service lifecycle uses
  // `<prefix>/service`; both land on the same handler.
  private let coreChannel: FlutterMethodChannel
  private let tileChannel: FlutterMethodChannel
  private let sharedStateStore: SharedStateStore
  private let tunnelController: TunnelController
  private let coreMessageRouter: CoreMessageRouter
  private let coreEventRelay: CoreEventRelay
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.chenx.flclash",
    category: "ServiceChannel"
  )

  static func register(with messenger: FlutterBinaryMessenger) {
    let serviceChannel = ServiceChannel(messenger: messenger)
    instance = serviceChannel
    guard let action = pendingQuickAction else {
      return
    }
    pendingQuickAction = nil
    serviceChannel.perform(action)
  }

  static func request(_ action: QuickAction) {
    guard let instance else {
      pendingQuickAction = action.folded(onto: pendingQuickAction)
      return
    }
    instance.perform(action)
  }

  private func perform(_ action: QuickAction) {
    switch action {
    case .start:
      tunnelController.start()
    case .stop:
      tunnelController.stop()
    case .toggle:
      tunnelController.toggle()
    }
  }

  private init(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "\(Self.channelPrefix)/service",
      binaryMessenger: messenger
    )
    let tileChannel = FlutterMethodChannel(
      name: "\(Self.channelPrefix)/tile",
      binaryMessenger: messenger
    )
    let coreChannel = FlutterMethodChannel(
      name: "\(Self.channelPrefix)/core",
      binaryMessenger: messenger
    )
    let sharedStateStore = SharedStateStore()
    let routerReference = CoreMessageRouterReference()
    let tunnelController = TunnelController(
      sharedStateStore: sharedStateStore,
      onTunnelStateChanged: { state in
        routerReference.value?.updateTunnelState(state)
      },
      onConnectionStateChanged: { state in
        channel.invokeMethod("tunnelState", arguments: state)
      },
      onExternalStart: {
        tileChannel.invokeMethod("syncRunningState", arguments: [
          "running": true,
          "startTime": sharedStateStore.runTime(),
        ])
      },
      onExternalStop: {
        tileChannel.invokeMethod("syncRunningState", arguments: [
          "running": false,
          "startTime": 0,
        ])
      }
    )
    let coreMessageRouter = CoreMessageRouter(
      tunnelController: tunnelController
    )
    routerReference.value = coreMessageRouter
    let coreEventRelay = CoreEventRelay(
      sharedStateStore: sharedStateStore,
      sendEvent: { event, completion in
        channel.invokeMethod("event", arguments: event) { callbackResult in
          completion(callbackResult == nil)
        }
      }
    )

    self.channel = channel
    self.coreChannel = coreChannel
    self.tileChannel = tileChannel
    self.sharedStateStore = sharedStateStore
    self.tunnelController = tunnelController
    self.coreMessageRouter = coreMessageRouter
    self.coreEventRelay = coreEventRelay

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    coreChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    coreEventRelay.start()
    tunnelController.startObserving()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    log("handle method=\(call.method)")
    switch call.method {
    case "invokeMethod":
      guard let data = methodCallData(call) else {
        result(invalidMethodCallResponse)
        return
      }
      Task {
        // Dart asks for Uint8List here and decodes the JSON itself; handing back
        // the raw String trips "type 'String' is not a subtype of type
        // 'Uint8List?'" on every core call.
        let response = await coreMessageRouter.invoke(data)
        result(FlutterStandardTypedData(bytes: Data(response.utf8)))
      }
    case "start":
      // The Flutter side syncs the shared state before it starts the tunnel and
      // only sends a command revision here, so an argument that is not the
      // state blob means the last synced one still applies.
      if let state = call.arguments as? FlutterStandardTypedData {
        guard sharedStateStore.saveSharedState(state.data) else {
          result("共享状态同步失败，无法启动隧道。")
          return
        }
      } else {
        log("start without shared state; reusing the last synced one")
      }
      Task {
        // Wait for the system to report the tunnel connected. Reporting success
        // straight away left the app claiming it was running while traffic went
        // out unproxied, which is what a second VPN being active used to look
        // like.
        let failure = await tunnelController.startAndConfirm()
        if let failure {
          log("start failed: \(failure)")
        }
        result(failure ?? "")
      }
    case "stop":
      tunnelController.stop()
      result(true)
    case "init":
      tunnelController.publishConnectionState()
      coreEventRelay.drainEventQueue()
      result("")
    case "syncState":
      syncState(call, result: result)
    case "shutdown":
      Task {
        result(await coreMessageRouter.shutdownAppCore())
      }
    case "getRunTime":
      Task {
        result(await tunnelController.getRunTime())
      }
    case "getActiveVpnOptions":
      Task {
        let running = await tunnelController.getRunTime() > 0
        result(running ? sharedStateStore.activeVpnOptions() : nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func methodCallData(_ call: FlutterMethodCall) -> Data? {
    guard let message = call.arguments as? String else {
      return nil
    }
    return message.data(using: .utf8)
  }

  private func syncState(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard saveSharedState(call) else {
      result("failed to sync shared state")
      return
    }
    result("")
    Task {
      do {
        try await tunnelController.reloadOnDemandRules()
      } catch {
        log("syncState preferences failed: \(error.localizedDescription)")
      }
    }
  }

  private func saveSharedState(_ call: FlutterMethodCall) -> Bool {
    guard let data = methodCallData(call),
      sharedStateStore.saveSharedState(data)
    else {
      log("saveSharedState failed")
      return false
    }
    log("saveSharedState bytes=\(data.count)")
    return true
  }

  private var invalidMethodCallResponse: String {
    #"{"result":null,"error":{"code":"invalid_method_call","message":"invalid method call","details":null}}"#
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
