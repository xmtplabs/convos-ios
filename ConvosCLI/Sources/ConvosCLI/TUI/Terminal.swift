import Foundation

/// Screen buffer for flicker-free rendering using double buffering
final class ScreenBuffer {
    private var buffer: String = ""
    private var cursorRow: Int = 1
    private var cursorCol: Int = 1
    private var showCursorAtEnd: Bool = false

    let rows: Int
    let cols: Int

    init() {
        let size = Terminal.getSize()
        self.rows = size.rows
        self.cols = size.cols
    }

    /// Clear the buffer and prepare for new frame
    func clear() {
        buffer = ""
        // Hide cursor, clear screen, and move to home position
        buffer.append("\u{001B}[?25l")  // Hide cursor
        buffer.append("\u{001B}[2J")     // Clear entire screen
        buffer.append("\u{001B}[H")      // Move to home
        showCursorAtEnd = false
    }

    /// Write text at specific position
    func write(row: Int, col: Int, _ text: String) {
        buffer.append("\u{001B}[\(row);\(col)H")
        buffer.append(text)
        // Clear to end of line to remove any leftover characters
        buffer.append("\u{001B}[K")
    }

    /// Write a horizontal line
    func writeLine(row: Int, char: Character = "─") {
        buffer.append("\u{001B}[\(row);1H")
        buffer.append(String(repeating: char, count: cols))
    }

    /// Set final cursor position and make it visible
    func setCursor(row: Int, col: Int) {
        cursorRow = row
        cursorCol = col
        showCursorAtEnd = true
    }

    /// Hide cursor at end of render
    func hideCursor() {
        showCursorAtEnd = false
    }

    /// Render the buffer to the terminal in one atomic write
    func render() {
        // Position cursor and optionally show it
        buffer.append("\u{001B}[\(cursorRow);\(cursorCol)H")
        if showCursorAtEnd {
            buffer.append("\u{001B}[?25h")  // Show cursor
        }

        // Write entire buffer at once
        print(buffer, terminator: "")
        fflush(stdout)
    }
}

/// Low-level terminal control using ANSI escape codes
enum Terminal {
    // MARK: - Screen Control

    /// Clear the entire screen and move cursor to home position
    static func clear() {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        fflush(stdout)
    }

    /// Clear from cursor to end of screen
    static func clearToEnd() {
        print("\u{001B}[J", terminator: "")
        fflush(stdout)
    }

    /// Clear the current line
    static func clearLine() {
        print("\u{001B}[2K", terminator: "")
        fflush(stdout)
    }

    // MARK: - Cursor Control

    /// Move cursor to specified row and column (1-indexed)
    static func moveTo(row: Int, col: Int) {
        print("\u{001B}[\(row);\(col)H", terminator: "")
        fflush(stdout)
    }

    /// Move cursor up by n lines
    static func moveUp(_ n: Int = 1) {
        print("\u{001B}[\(n)A", terminator: "")
        fflush(stdout)
    }

    /// Move cursor down by n lines
    static func moveDown(_ n: Int = 1) {
        print("\u{001B}[\(n)B", terminator: "")
        fflush(stdout)
    }

    /// Hide the cursor
    static func hideCursor() {
        print("\u{001B}[?25l", terminator: "")
        fflush(stdout)
    }

    /// Show the cursor
    static func showCursor() {
        print("\u{001B}[?25h", terminator: "")
        fflush(stdout)
    }

    /// Save cursor position
    static func saveCursor() {
        print("\u{001B}[s", terminator: "")
        fflush(stdout)
    }

    /// Restore cursor position
    static func restoreCursor() {
        print("\u{001B}[u", terminator: "")
        fflush(stdout)
    }

    // MARK: - Text Styling

    /// Make text bold
    static func bold(_ text: String) -> String {
        "\u{001B}[1m\(text)\u{001B}[0m"
    }

    /// Make text dim
    static func dim(_ text: String) -> String {
        "\u{001B}[2m\(text)\u{001B}[0m"
    }

    /// Make text italic
    static func italic(_ text: String) -> String {
        "\u{001B}[3m\(text)\u{001B}[0m"
    }

    /// Make text underlined
    static func underline(_ text: String) -> String {
        "\u{001B}[4m\(text)\u{001B}[0m"
    }

    /// Invert text colors (highlight)
    static func inverse(_ text: String) -> String {
        "\u{001B}[7m\(text)\u{001B}[0m"
    }

    /// Reset all text styling
    static func reset() -> String {
        "\u{001B}[0m"
    }

    // MARK: - Colors

    static func black(_ text: String) -> String { "\u{001B}[30m\(text)\u{001B}[0m" }
    static func red(_ text: String) -> String { "\u{001B}[31m\(text)\u{001B}[0m" }
    static func green(_ text: String) -> String { "\u{001B}[32m\(text)\u{001B}[0m" }
    static func yellow(_ text: String) -> String { "\u{001B}[33m\(text)\u{001B}[0m" }
    static func blue(_ text: String) -> String { "\u{001B}[34m\(text)\u{001B}[0m" }
    static func magenta(_ text: String) -> String { "\u{001B}[35m\(text)\u{001B}[0m" }
    static func cyan(_ text: String) -> String { "\u{001B}[36m\(text)\u{001B}[0m" }
    static func white(_ text: String) -> String { "\u{001B}[37m\(text)\u{001B}[0m" }

    // Bright colors
    static func brightBlack(_ text: String) -> String { "\u{001B}[90m\(text)\u{001B}[0m" }
    static func brightRed(_ text: String) -> String { "\u{001B}[91m\(text)\u{001B}[0m" }
    static func brightGreen(_ text: String) -> String { "\u{001B}[92m\(text)\u{001B}[0m" }
    static func brightYellow(_ text: String) -> String { "\u{001B}[93m\(text)\u{001B}[0m" }
    static func brightBlue(_ text: String) -> String { "\u{001B}[94m\(text)\u{001B}[0m" }
    static func brightMagenta(_ text: String) -> String { "\u{001B}[95m\(text)\u{001B}[0m" }
    static func brightCyan(_ text: String) -> String { "\u{001B}[96m\(text)\u{001B}[0m" }
    static func brightWhite(_ text: String) -> String { "\u{001B}[97m\(text)\u{001B}[0m" }

    // MARK: - Terminal Size

    /// Get terminal size (rows, columns)
    static func getSize() -> (rows: Int, cols: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        // Default fallback
        return (24, 80)
    }

    // MARK: - Alternate Screen Buffer

    /// Enter alternate screen buffer (like vim does)
    static func enterAlternateScreen() {
        print("\u{001B}[?1049h", terminator: "")
        fflush(stdout)
    }

    /// Leave alternate screen buffer
    static func leaveAlternateScreen() {
        print("\u{001B}[?1049l", terminator: "")
        fflush(stdout)
    }

    // MARK: - Output

    /// Print text at specific position
    static func printAt(row: Int, col: Int, _ text: String) {
        moveTo(row: row, col: col)
        print(text, terminator: "")
        fflush(stdout)
    }

    /// Print a horizontal line
    static func printLine(row: Int, cols: Int, char: Character = "─") {
        moveTo(row: row, col: 1)
        print(String(repeating: char, count: cols), terminator: "")
        fflush(stdout)
    }

    /// Flush stdout
    static func flush() {
        fflush(stdout)
    }
}
