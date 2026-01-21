import ConvosCore
import SwiftUI

struct RelativeDateLabel: View {
    let date: Date
    @State private var dateString: String = ""

    var body: some View {
        Text(dateString)
            .textCase(.lowercase)
            .onAppear {
                dateString = date.relativeShort()
            }
            .onChange(of: date) {
                dateString = date.relativeShort()
            }
            .task(id: date) {
                while !Task.isCancelled {
                    let interval = nextUpdateInterval()
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { break }
                    dateString = date.relativeShort()
                }
            }
    }

    private func nextUpdateInterval() -> TimeInterval {
        let secondsAgo = abs(Date().timeIntervalSince(date))
        if secondsAgo < 60 {
            return TimeInterval(30.0)
        } else if secondsAgo < 1800 {
            return TimeInterval(120.0)
        } else if secondsAgo < 3600 {
            let secondsToNextMinute = 60 - (Int(secondsAgo) % 60)
            return TimeInterval(secondsToNextMinute)
        } else {
            let secondsToNextHour = 3600 - (Int(secondsAgo) % 3600)
            return TimeInterval(secondsToNextHour)
        }
    }
}
