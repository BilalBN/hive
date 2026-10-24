import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // M6: Apple push (needs the Apple Developer account and the Push
  // Notifications capability; until then registering fails quietly).
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    HivePush.shared.registered(token: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    HivePush.shared.failed(error)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HivePush") {
      HivePush.shared.attach(messenger: registrar.messenger())
    }
  }
}

/// Registers this device for Apple push and hands the token to Hive (M6).
final class HivePush {
  static let shared = HivePush()
  private var pending: FlutterResult?

  func attach(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "hive/push", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "register" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.register(result)
      }
  }

  private func register(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, _ in
      DispatchQueue.main.async {
        guard granted else {
          result(FlutterError(code: "denied", message: "Notifications aren't allowed", details: nil))
          return
        }
        self.pending = result
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func registered(token: Data) {
    pending?(token.map { String(format: "%02x", $0) }.joined())
    pending = nil
  }

  func failed(_ error: Error) {
    pending?(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    pending = nil
  }
}
