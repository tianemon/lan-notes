import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 自研「选择保存目录」通道：替代 file_picker 的 NSOpenPanel——
    // file_picker 面板按钮是英文 "Open"（App 无中文本地化回退英文，且语义
    // 是"打开"非"保存"）。此处 NSOpenPanel 设中文按钮"保存"+中文提示。
    let channel = FlutterMethodChannel(
      name: "easynote/save_directory",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { (call, result) in
      guard call.method == "pick" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "保存"
      panel.message = "选择保存位置"
      panel.title = "保存图片"
      if panel.runModal() == .OK, let url = panel.url {
        result(url.path)
      } else {
        result(nil)
      }
    }

    super.awakeFromNib()
  }
}
