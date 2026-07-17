//
//  BundleModule.swift
//  Zennopay
//
//  Resource-bundle resolution shim.
//
//  Under Swift Package Manager, `Bundle.module` is synthesized by the build
//  system and the SDK's asset catalog is compiled into that generated bundle.
//  Under CocoaPods there is no synthesized `Bundle.module`, so the same
//  `Image("zp-powered-…", bundle: .module)` call sites in the UI would fail to
//  compile. CocoaPods instead ships the asset catalog inside a resource bundle
//  declared by the podspec's `resource_bundles` (named "ZennopayResources").
//
//  This file provides a `Bundle.module` that locates that resource bundle, but
//  ONLY when NOT building via SwiftPM (guarded by `!SWIFT_PACKAGE` so it never
//  collides with the SPM-generated accessor). The lookup walks the framework
//  and host bundle locations so it resolves whether the pod is integrated as a
//  static library, a dynamic framework, or `pod lib lint`'s isolated build.
//
#if !SWIFT_PACKAGE
import Foundation

private final class ZennopayBundleToken {}

extension Bundle {
    /// The bundle that carries the SDK's compiled resources (asset catalog)
    /// when the SDK is integrated via CocoaPods.
    static let module: Bundle = {
        let bundleName = "ZennopayResources"

        let candidates: [URL?] = [
            // Bundle for the framework/library that contains this type.
            Bundle(for: ZennopayBundleToken.self).resourceURL,
            // App resources (static-library integration nests the bundle here).
            Bundle.main.resourceURL,
            // Framework bundle URL directly.
            Bundle(for: ZennopayBundleToken.self).bundleURL,
            Bundle.main.bundleURL,
            // Frameworks living under a Frameworks/ dir of the host app.
            Bundle(for: ZennopayBundleToken.self)
                .resourceURL?
                .deletingLastPathComponent(),
        ]

        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(bundleName + ".bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // Fall back to the framework bundle itself (asset catalog may have been
        // merged directly into it).
        return Bundle(for: ZennopayBundleToken.self)
    }()
}
#endif
