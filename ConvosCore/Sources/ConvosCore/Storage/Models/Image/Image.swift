#if os(macOS)
import AppKit
public typealias Image = NSImage
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias Image = UIImage
#endif
