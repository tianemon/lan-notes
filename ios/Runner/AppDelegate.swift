import Flutter
import UIKit
import Network

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerUdpBroadcastChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 注册 UDP 广播发送通道（easynote/udp_broadcast）。
  ///
  /// 背景：dart:io 的 RawDatagramSocket 在 iOS 上发送 UDP 广播有已知缺陷
  /// （send 返回成功但数据包不离开设备，见 dart-lang/sdk #45824/#55564；
  /// 用户实测：iPhone 周期广播 Mac 一个包都收不到）。改用 iOS 原生
  /// Network.framework 发送广播——原生栈无此问题。
  ///
  /// 协议：与 Dart 侧 discovery_service 的 UDP 广播完全一致（发送到
  /// 58888 端口的广播地址，payload 为通告 JSON）。接收仍走 Dart socket
  /// （iOS 接收正常，无需原生）。
  private func registerUdpBroadcastChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "easynote/udp_broadcast",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "send":
        guard let args = call.arguments as? [String: Any],
              let payload = args["payload"] as? FlutterStandardTypedData,
              let host = args["host"] as? String,
              let port = args["port"] as? Int else {
          result(FlutterError(code: "bad_args", message: "参数缺失", details: nil))
          return
        }
        self.sendUdpBroadcast(
          data: Data(payload.data),
          host: host,
          port: UInt16(port)
        ) { error in
          if let error = error {
            result(FlutterError(code: "send_failed", message: error, details: nil))
          } else {
            result(nil)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 用 Network.framework 发送 UDP 广播（async，完成回调）。
  private func sendUdpBroadcast(
    data: Data,
    host: String,
    port: UInt16,
    completion: @escaping (String?) -> Void
  ) {
    guard let portValue = NWEndpoint.Port(rawValue: port) else {
      completion("无效的端口")
      return
    }
    // UDP 连接：发送广播到目标地址。
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: portValue,
      using: .udp
    )
    connection.start(queue: .global(qos: .userInitiated))
    connection.send(content: data, completion: .contentProcessed { error in
      if let error = error {
        completion(error.localizedDescription)
      } else {
        completion(nil)
      }
      connection.cancel()
    })
  }
}
