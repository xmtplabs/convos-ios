#if os(macOS)
import AppKit
public typealias ImageType = NSImage
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias ImageType = UIImage
#endif
