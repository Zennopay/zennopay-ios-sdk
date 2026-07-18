Pod::Spec.new do |s|
  s.name             = "Zennopay"
  s.version          = "0.5.0"
  s.summary          = "Scan a local merchant QR code abroad and pay it from your wallet — native iOS checkout."
  s.description      = <<-DESC
    Zennopay's native iOS SDK. Presents a full in-process pay experience:
    scan a local merchant QR code while travelling, review the amount in the
    local currency with a transparent FX + fee breakdown, slide to pay from
    the user's wallet, and get a shareable receipt. SwiftUI + UIKit, with an
    AVFoundation/Vision QR scanner and gallery import.
  DESC
  s.homepage         = "https://zennopay.in"
  s.license          = { :type => "MIT", :file => "LICENSE" }
  s.author           = { "Zennopay" => "support@zennopay.in" }
  s.source           = { :git => "https://github.com/Zennopay/zennopay-ios-sdk.git", :tag => "v#{s.version}" }

  s.swift_version         = "5.9"
  s.ios.deployment_target = "16.0"

  s.source_files = "Sources/Zennopay/**/*.swift"

  # The asset catalog (the "Powered by Zennopay" footer wordmark, light + dark)
  # is compiled into a resource bundle named "ZennopayResources". The SDK's
  # BundleModule shim resolves `Bundle.module` to this bundle under CocoaPods.
  s.resource_bundles = {
    "ZennopayResources" => ["Sources/Zennopay/Resources/Media.xcassets"]
  }

  s.frameworks = "UIKit", "SwiftUI", "AVFoundation", "Vision", "PhotosUI", "Photos"
end
