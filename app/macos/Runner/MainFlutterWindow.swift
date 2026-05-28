import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let screenFrame = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? self.frame
    let targetWidth = min(1280.0, max(980.0, screenFrame.width - 40.0))
    let targetHeight = min(820.0, max(640.0, screenFrame.height - 40.0))
    let windowFrame = NSRect(
      x: screenFrame.midX - targetWidth / 2.0,
      y: screenFrame.midY - targetHeight / 2.0,
      width: targetWidth,
      height: targetHeight
    )

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 860.0, height: 600.0)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
