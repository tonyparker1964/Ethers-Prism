import Foundation

/// Ethers Prism's version, shown in the sidebar and the About box.
/// Keep Support/Info.plist (CFBundleShortVersionString, CFBundleVersion) in step; a test checks it.
/// Raise the middle number for new fields or features, the last for fixes.
public enum AppVersion {
    public static let number = "1.4.0"
    public static let build = "5"
}
