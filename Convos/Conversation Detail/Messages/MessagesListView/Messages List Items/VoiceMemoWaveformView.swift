import SwiftUI

struct VoiceMemoWaveformView: View {
    let levels: [Float]
    var progress: Double = 0
    var playedColor: Color = .colorTextPrimary
    var unplayedColor: Color = .colorTextSecondary.opacity(0.4)
    var barWidth: CGFloat = 2
    var barSpacing: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let totalBarWidth = barWidth + barSpacing
            let barCount = max(Int(size.width / totalBarWidth), 1)
            let sampledLevels = resample(levels, to: barCount)
            let progressBarIndex = Int(Double(barCount) * progress)

            for index in 0 ..< barCount {
                let level = index < sampledLevels.count ? CGFloat(sampledLevels[index]) : 0
                let height = max(size.height * level, 2)
                let x = CGFloat(index) * totalBarWidth
                let y = (size.height - height) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                let color: Color = progress > 0 && index < progressBarIndex ? playedColor : unplayedColor
                context.fill(path, with: .color(color))
            }
        }
    }

    private func resample(_ input: [Float], to count: Int) -> [Float] {
        guard !input.isEmpty, count > 0 else {
            return Array(repeating: 0, count: count)
        }
        if input.count == count { return input }
        var result: [Float] = []
        let step = Double(input.count) / Double(count)
        for i in 0 ..< count {
            let position = Double(i) * step
            let index = Int(position)
            if index >= input.count - 1 {
                result.append(input[input.count - 1])
            } else {
                let fraction = Float(position - Double(index))
                let interpolated = input[index] * (1 - fraction) + input[index + 1] * fraction
                result.append(interpolated)
            }
        }
        return result
    }
}

#Preview {
    let levels: [Float] = (0 ..< 80).map { _ in Float.random(in: 0.05 ... 1.0) }
    VoiceMemoWaveformView(levels: levels, progress: 0.4)
        .frame(height: 32)
        .padding()
}
