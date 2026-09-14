import Flutter
import UIKit

/// Stub iOS — MVP Android 11+ only. Fingerprint/device info limited.
public class OmniMdmPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "omni_mdm", binaryMessenger: registrar.messenger())
    let instance = OmniMdmPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getHardwareFingerprint":
      result(UIDevice.current.identifierForVendor?.uuidString)
    case "getDeviceInfo":
      let device = UIDevice.current
      result([
        "hardware_fingerprint": device.identifierForVendor?.uuidString as Any,
        "platform": "ios",
        "manufacturer": "Apple",
        "model": device.model,
        "os_version": device.systemVersion,
        "name": device.name,
        "observed_at": ISO8601DateFormatter().string(from: Date()),
      ] as [String: Any])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
