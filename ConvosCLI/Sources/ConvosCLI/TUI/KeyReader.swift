import Foundation

/// Represents keyboard input
enum Key: Equatable, Sendable {
    case char(Character)
    case ctrl(Character)  // Control + letter (a-z)
    case up
    case down
    case left
    case right
    case enter
    case escape
    case backspace
    case delete
    case tab
    case unknown
}

/// Reads keyboard input in raw mode
final class KeyReader: @unchecked Sendable {
    private var originalTermios: termios?
    private let inputHandle: FileHandle

    init() {
        self.inputHandle = FileHandle.standardInput
    }

    /// Enable raw mode for reading individual keystrokes
    func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw

        // Disable canonical mode (line buffering) and echo
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO) | UInt(ISIG))

        // Set minimum characters to read
        raw.c_cc.4 = 1  // VMIN - minimum number of characters to read
        raw.c_cc.5 = 0  // VTIME - timeout in deciseconds

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    /// Restore original terminal settings
    func disableRawMode() {
        if var original = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
    }

    /// Read a single key (blocking)
    func readKey() -> Key {
        var buffer = [UInt8](repeating: 0, count: 4)
        let bytesRead = read(STDIN_FILENO, &buffer, 4)

        guard bytesRead > 0 else {
            return .unknown
        }

        // Handle escape sequences
        if buffer[0] == 27 { // ESC
            if bytesRead == 1 {
                return .escape
            }

            // CSI sequences (ESC [)
            if buffer[1] == 91 { // '['
                switch buffer[2] {
                case 65: return .up     // ESC [ A
                case 66: return .down   // ESC [ B
                case 67: return .right  // ESC [ C
                case 68: return .left   // ESC [ D
                case 51: // ESC [ 3 ~
                    if bytesRead >= 4 && buffer[3] == 126 {
                        return .delete
                    }
                    return .unknown
                default:
                    return .unknown
                }
            }

            return .escape
        }

        // Handle special characters
        switch buffer[0] {
        case 10, 13: // LF or CR
            return .enter
        case 127, 8: // DEL or BS
            return .backspace
        case 1...26: // Control characters (Ctrl+A through Ctrl+Z)
            // Convert control code to corresponding letter
            // Ctrl+A = 1, Ctrl+B = 2, etc.
            // Note: Tab (9) = Ctrl+I, but we return .tab for it
            if buffer[0] == 9 {
                return .tab
            }
            let letter = Character(UnicodeScalar(buffer[0] + 96)) // 1 + 96 = 'a'
            return .ctrl(letter)
        default:
            // Regular character (handle UTF-8)
            let data = Data(buffer[0..<bytesRead])
            if let str = String(data: data, encoding: .utf8), let char = str.first {
                return .char(char)
            }
            return .unknown
        }
    }

    /// Read a key asynchronously
    func readKeyAsync() async -> Key {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                let key = self.readKey()
                continuation.resume(returning: key)
            }
        }
    }

    /// Read a key with timeout (returns nil if no key pressed within timeout)
    func readKeyWithTimeout(milliseconds: Int) -> Key? {
        // Use select() to check if input is available
        var readfds = fd_set()
        withUnsafeMutablePointer(to: &readfds) { ptr in
            // Initialize the fd_set
            let rawPtr = UnsafeMutableRawPointer(ptr)
            memset(rawPtr, 0, MemoryLayout<fd_set>.size)

            // Set the bit for STDIN_FILENO
            let fd = STDIN_FILENO
            let intOffset = Int(fd) / 32
            let bitOffset = Int(fd) % 32
            let mask = Int32(1 << bitOffset)

            rawPtr.advanced(by: intOffset * 4).assumingMemoryBound(to: Int32.self).pointee |= mask
        }

        var timeout = timeval(
            tv_sec: milliseconds / 1000,
            tv_usec: Int32((milliseconds % 1000) * 1000)
        )

        let result = select(STDIN_FILENO + 1, &readfds, nil, nil, &timeout)

        if result > 0 {
            return readKey()
        }
        return nil
    }

    /// Read a key asynchronously with timeout
    func readKeyAsyncWithTimeout(milliseconds: Int) async -> Key? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                let key = self.readKeyWithTimeout(milliseconds: milliseconds)
                continuation.resume(returning: key)
            }
        }
    }

    deinit {
        disableRawMode()
    }
}

/// Simple line editor for text input
final class LineEditor: @unchecked Sendable {
    private(set) var text: String = ""
    private(set) var cursorPosition: Int = 0

    func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char(let c):
            let index = text.index(text.startIndex, offsetBy: cursorPosition)
            text.insert(c, at: index)
            cursorPosition += 1
            return true

        case .backspace:
            if cursorPosition > 0 {
                let index = text.index(text.startIndex, offsetBy: cursorPosition - 1)
                text.remove(at: index)
                cursorPosition -= 1
            }
            return true

        case .delete:
            if cursorPosition < text.count {
                let index = text.index(text.startIndex, offsetBy: cursorPosition)
                text.remove(at: index)
            }
            return true

        case .left:
            if cursorPosition > 0 {
                cursorPosition -= 1
            }
            return true

        case .right:
            if cursorPosition < text.count {
                cursorPosition += 1
            }
            return true

        case .enter:
            return false // Signal that input is complete

        default:
            return true
        }
    }

    func clear() {
        text = ""
        cursorPosition = 0
    }

    func getText() -> String {
        let result = text
        clear()
        return result
    }
}
