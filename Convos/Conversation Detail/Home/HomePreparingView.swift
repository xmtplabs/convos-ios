import SwiftUI

/// What the home shows while it has nothing to draw yet: the house mark, a
/// line naming what is happening, and a bar that creeps forward.
/// Figma 7629:37802.
///
/// It replaces a bare spinner. The wait is for a space being built rather than
/// a request in flight, so the surface says so and shows movement toward
/// something instead of spinning in place.
struct HomePreparingView: View {
    /// What is being waited on. A conversation gets its Home tab immediately,
    /// but the worker publishes the space URL a while later, so the bar holds
    /// low until there is something to load and advances once there is.
    enum Stage {
        case awaitingSpace
        case loadingPage
    }

    /// Whose home this is. The personal Space is a conversation with nobody in
    /// it but the user and their own agent, so a line about "your group's"
    /// home names a group that isn't there.
    enum Subject {
        case group
        case space
    }

    var stage: Stage = .loadingPage
    var subject: Subject = .group

    @State private var progress: Double = Constant.progressStart

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            houseMark
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: Constant.captionFadeDuration), value: stage)
            progressBar
        }
        .task(id: stage) {
            await rampProgress()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityIdentifier("home-preparing")
    }

    /// What the line says the wait is for. Until the worker publishes the
    /// space URL there is no page yet - the home is still being built - so the
    /// line only claims to be loading once there is something to load.
    private var caption: String {
        switch (stage, subject) {
        case (.awaitingSpace, .group): "Preparing your group's new home"
        case (.loadingPage, .group): "Loading your group's home"
        case (.awaitingSpace, .space): "Preparing your home"
        case (.loadingPage, .space): "Loading your home"
        }
    }

    /// Roof plus two windows. The roof is the exported vector, tinted with the
    /// app's lava token rather than the hex baked into the export; the windows
    /// are plain rounded squares in the design, so they are drawn here.
    private var houseMark: some View {
        VStack(spacing: Constant.roofToWindowsSpacing) {
            Image("homePreparingRoof")
                .renderingMode(.template)
                .resizable()
                .frame(width: Constant.roofWidth, height: Constant.roofHeight)
                .foregroundStyle(.colorLava)
            HStack(spacing: Constant.windowSpacing) {
                window
                window
            }
        }
    }

    private var window: some View {
        RoundedRectangle(cornerRadius: Constant.windowCornerRadius)
            .fill(Color.colorLava)
            .frame(width: Constant.windowSize, height: Constant.windowSize)
    }

    /// A 160x8 track in 15% lava with a lava fill, matching the agent tab's
    /// preparing bar in behavior: it creeps toward a cap rather than
    /// completing, because neither stage reports real progress.
    private var progressBar: some View {
        let fillWidth: CGFloat = Constant.progressWidth * progress
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Constant.progressHeight)
                .fill(Color.colorLava.opacity(Constant.progressTrackOpacity))
                .frame(width: Constant.progressWidth, height: Constant.progressHeight)
            RoundedRectangle(cornerRadius: Constant.progressHeight)
                .fill(Color.colorLava)
                .frame(width: fillWidth, height: Constant.progressHeight)
        }
    }

    /// The ceiling for the current stage. Waiting on the space holds the bar
    /// in its first third; once the URL lands the same bar carries on from
    /// where it stopped, so the arrival reads as progress rather than a reset.
    private var progressCap: Double {
        switch stage {
        case .awaitingSpace: Constant.awaitingSpaceCap
        case .loadingPage: Constant.loadingPageCap
        }
    }

    private func rampProgress() async {
        while !Task.isCancelled, progress < progressCap {
            try? await Task.sleep(for: .seconds(Constant.progressTick))
            guard !Task.isCancelled else { return }
            let next: Double = min(progress + Constant.progressStep, progressCap)
            withAnimation(.easeOut(duration: Constant.progressTick)) {
                progress = next
            }
        }
    }

    private enum Constant {
        static let roofWidth: CGFloat = 35.04
        static let roofHeight: CGFloat = 18.76
        static let roofToWindowsSpacing: CGFloat = 4.46
        static let windowSize: CGFloat = 16.0
        static let windowSpacing: CGFloat = 4.0
        static let windowCornerRadius: CGFloat = 5.0
        static let progressWidth: CGFloat = 160.0
        static let progressHeight: CGFloat = 8.0
        static let progressTrackOpacity: Double = 0.15
        /// The design's still frame shows the bar just started.
        static let progressStart: Double = 0.15
        static let awaitingSpaceCap: Double = 0.35
        static let loadingPageCap: Double = 0.9
        static let progressStep: Double = 0.05
        static let progressTick: Double = 0.8
        static let captionFadeDuration: Double = 0.3
    }
}

#Preview("Awaiting the space") {
    ZStack {
        Color.colorBackgroundSubtle
        HomePreparingView(stage: .awaitingSpace)
    }
}

#Preview("Loading the page") {
    ZStack {
        Color.colorBackgroundSubtle
        HomePreparingView(stage: .loadingPage)
    }
}

#Preview("Your Space, awaiting") {
    ZStack {
        Color.colorBackgroundSubtle
        HomePreparingView(stage: .awaitingSpace, subject: .space)
    }
}
