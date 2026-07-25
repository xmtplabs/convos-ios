#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
public protocol KeyboardListenerDelegate: AnyObject {
    func keyboardWillShow(info: KeyboardInfo)
    func keyboardDidShow(info: KeyboardInfo)
    func keyboardWillHide(info: KeyboardInfo)
    func keyboardDidHide(info: KeyboardInfo)
    func keyboardWillChangeFrame(info: KeyboardInfo)
    func keyboardDidChangeFrame(info: KeyboardInfo)
}

public extension KeyboardListenerDelegate {
    func keyboardWillShow(info: KeyboardInfo) {}
    func keyboardDidShow(info: KeyboardInfo) {}
    func keyboardWillHide(info: KeyboardInfo) {}
    func keyboardDidHide(info: KeyboardInfo) {}
    func keyboardWillChangeFrame(info: KeyboardInfo) {}
    func keyboardDidChangeFrame(info: KeyboardInfo) {}
}

@MainActor
public final class KeyboardListener {
    public nonisolated static let shared: KeyboardListener = KeyboardListener()
    public private(set) var keyboardRect: CGRect?

    private let delegatesLock: NSLock = NSLock()
    nonisolated(unsafe) private var delegates: NSHashTable<AnyObject> = NSHashTable<AnyObject>.weakObjects()

    // Fallback support
    private var pendingDidChangeFrameInfo: KeyboardInfo?
    private var didChangeFrameTimer: Timer?

    public nonisolated func add(delegate: KeyboardListenerDelegate) {
        delegatesLock.lock()
        defer { delegatesLock.unlock() }
        delegates.add(delegate)
    }

    public nonisolated func remove(delegate: KeyboardListenerDelegate) {
        delegatesLock.lock()
        defer { delegatesLock.unlock() }
        delegates.remove(delegate)
    }

    private func allDelegates() -> [KeyboardListenerDelegate] {
        delegatesLock.lock()
        defer { delegatesLock.unlock() }
        return delegates.allObjects.compactMap { $0 as? KeyboardListenerDelegate }
    }

    nonisolated private init() {
        subscribeToKeyboardNotifications()
    }

    @objc @MainActor
    private func keyboardWillShow(_ notification: Notification) {
        guard let info = KeyboardInfo(notification) else {
            return
        }

        keyboardRect = info.frameEnd
        allDelegates().forEach {
            $0.keyboardWillShow(info: info)
        }
    }

    @objc @MainActor
    private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let info = KeyboardInfo(notification) else {
            return
        }

        keyboardRect = info.frameEnd
        pendingDidChangeFrameInfo = info

        // Cancel any existing timer
        didChangeFrameTimer?.invalidate()

        // Start a fallback timer slightly longer than the expected duration
        didChangeFrameTimer = Timer.scheduledTimer(withTimeInterval: info.animationDuration + 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleMissingDidChangeFrame()
            }
        }

        allDelegates().forEach {
            $0.keyboardWillChangeFrame(info: info)
        }
    }

    @objc @MainActor
    private func keyboardDidChangeFrame(_ notification: Notification) {
        guard let info = KeyboardInfo(notification) else {
            return
        }

        // Cancel the fallback timer
        didChangeFrameTimer?.invalidate()
        didChangeFrameTimer = nil
        pendingDidChangeFrameInfo = nil

        keyboardRect = info.frameEnd
        allDelegates().forEach {
            $0.keyboardDidChangeFrame(info: info)
        }
    }

    @objc @MainActor
    private func keyboardDidShow(_ notification: Notification) {
        guard let info = KeyboardInfo(notification) else {
            return
        }

        keyboardRect = info.frameEnd
        allDelegates().forEach {
            $0.keyboardDidShow(info: info)
        }
    }

    @objc @MainActor
    private func keyboardWillHide(_ notification: Notification) {
        guard let info = KeyboardInfo(notification) else {
            return
        }

        keyboardRect = info.frameEnd
        allDelegates().forEach {
            $0.keyboardWillHide(info: info)
        }
    }

    @objc @MainActor
    private func keyboardDidHide(_ notification: Notification) {
        guard let info = KeyboardInfo(notification) else {
            return
        }

        keyboardRect = info.frameEnd
        allDelegates().forEach {
            $0.keyboardDidHide(info: info)
        }
    }

    @MainActor
    private func handleMissingDidChangeFrame() {
        guard let info = pendingDidChangeFrameInfo else { return }

        keyboardRect = info.frameEnd
        pendingDidChangeFrameInfo = nil
        didChangeFrameTimer = nil

        allDelegates().forEach {
            $0.keyboardDidChangeFrame(info: info)
        }
    }

    nonisolated private func subscribeToKeyboardNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardDidShow(_:)),
                                               name: UIResponder.keyboardDidShowNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardDidHide(_:)),
                                               name: UIResponder.keyboardDidHideNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardDidChangeFrame(_:)),
                                               name: UIResponder.keyboardDidChangeFrameNotification,
                                               object: nil)
    }
}
#endif
