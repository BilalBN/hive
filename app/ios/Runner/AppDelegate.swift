import AVFAudio
import Flutter
import ShazamKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HiveShazam") {
      HiveShazam.register(messenger: registrar.messenger())
    }
  }
}

/// Shazam for songs that aren't at home (M5). Listen sends the last few
/// seconds of sound it heard; only a fingerprint of it goes to Apple.
/// Needs the ShazamKit service turned on for this app's identifier in the
/// Apple Developer account; until then a match fails and Listen carries on
/// as if Shazam didn't know the song.
final class HiveShazam: NSObject, SHSessionDelegate {
  private static var kept: HiveShazam?
  private var session: SHSession?
  private var pending: FlutterResult?

  static func register(messenger: FlutterBinaryMessenger) {
    let shazam = HiveShazam()
    kept = shazam
    FlutterMethodChannel(name: "hive/shazam", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in shazam.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(true)
    case "match":
      guard pending == nil,
        let args = call.arguments as? [String: Any],
        let pcm = args["pcm"] as? FlutterStandardTypedData,
        let rate = args["rate"] as? Int
      else {
        result(FlutterError(code: "busy", message: "Shazam is already listening", details: nil))
        return
      }
      match(pcm.data, rate: Double(rate), result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func match(_ data: Data, rate: Double, result: @escaping FlutterResult) {
    let count = data.count / 2
    guard count > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
      let out = buffer.floatChannelData?[0]
    else {
      result(nil)
      return
    }
    buffer.frameLength = AVAudioFrameCount(count)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for i in 0..<count {
        out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
      }
    }
    let generator = SHSignatureGenerator()
    do {
      try generator.append(buffer, at: nil)
    } catch {
      result(FlutterError(code: "signature", message: error.localizedDescription, details: nil))
      return
    }
    let session = SHSession()
    session.delegate = self
    self.session = session
    pending = result
    session.match(generator.signature())
  }

  func session(_ session: SHSession, didFind match: SHMatch) {
    guard let item = match.mediaItems.first, let title = item.title else {
      finish(nil)
      return
    }
    var found: [String: Any] = ["title": title]
    if let artist = item.artist { found["artist"] = artist }
    finish(found)
  }

  func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
    if let error {
      finish(FlutterError(code: "shazam", message: error.localizedDescription, details: nil))
    } else {
      finish(nil)
    }
  }

  private func finish(_ value: Any?) {
    DispatchQueue.main.async {
      self.pending?(value)
      self.pending = nil
      self.session = nil
    }
  }
}
