import SwiftUI
import UIKit

struct AssistantsInfoView: View {
    var isConfirmation: Bool = false
    var onConfirm: (() -> Void)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    private let horizontalPadding: CGFloat = DesignConstants.Spacing.step10x

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Group {
                Text("Private chat for the AI era")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)

                TightLineHeightText(text: "Assistants help groups do things", fontSize: 40, lineHeight: 40)

                Text("Ask them anything. Assistants join your groupchat and learn by listening.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("Invite them in, and kick them out, anytime.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, horizontalPadding)

            sampleMessagesSection
                .padding(.top, DesignConstants.Spacing.step2x)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                if isConfirmation {
                    let confirmAction = {
                        onConfirm?()
                        dismiss()
                    }
                    Button(action: confirmAction) {
                        Text("Add an instant assistant")
                            .font(.body)
                    }
                    .convosButtonStyle(.rounded(fullWidth: true))
                } else {
                    let dismissAction = { dismiss() }
                    Button(action: dismissAction) {
                        Text("Awesome")
                            .font(.body)
                    }
                    .convosButtonStyle(.rounded(fullWidth: true))
                }

                let learnMoreURL = URL(string: "https://learn.convos.org/assistants")
                let learnMoreAction = { if let learnMoreURL { openURL(learnMoreURL) } }
                Button(action: learnMoreAction) {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Text("Learn more")
                            .font(.body)
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.colorFillTertiary)
                    }
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : DesignConstants.Spacing.step6x)
        .presentationBackground(.colorBackgroundRaised)
        .sheetDragIndicator(.hidden)
    }

    private var sampleMessagesSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            AutoScrollingRow(speed: 18) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    messageBubble("🏡 Help watch neighborhood news")
                    messageBubble("⛰️ Help us travel")
                    messageBubble("🛠️ Help us manage our home")
                    messageBubble("📘 Help us keep notes")
                    messageBubble("🎸 Help us catch local shows")
                }
                .padding(.horizontal, horizontalPadding)
            }
            .frame(height: 42)
            AutoScrollingRow(speed: 30) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    messageBubble("🎾 Help organize pick-up games")
                    messageBubble("🗓️ Help us get together soon")
                    messageBubble("🍕 Help us eat and drink better")
                    messageBubble("❤️ Help us keep in touch")
                    messageBubble("🍼 Help with our fam")
                }
                .padding(.horizontal, horizontalPadding)
            }
            .frame(height: 42)
        }
    }

    private func messageBubble(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.colorTextPrimary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, 10)
            .background(
                Color.colorBubbleIncoming,
                in: .rect(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: 20
                )
            )
    }
}

private struct AutoScrollingRow<Content: View>: UIViewRepresentable {
    let speed: CGFloat
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.clipsToBounds = false

        let contentView = content()

        let hostA = UIHostingController(rootView: contentView)
        hostA.view.backgroundColor = .clear
        hostA.view.translatesAutoresizingMaskIntoConstraints = false

        let hostB = UIHostingController(rootView: contentView)
        hostB.view.backgroundColor = .clear
        hostB.view.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostA.view)
        container.addSubview(hostB.view)
        scrollView.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            container.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            hostA.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostA.view.topAnchor.constraint(equalTo: container.topAnchor),
            hostA.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            hostB.view.leadingAnchor.constraint(equalTo: hostA.view.trailingAnchor),
            hostB.view.topAnchor.constraint(equalTo: container.topAnchor),
            hostB.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostB.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        context.coordinator.hostingControllers = [hostA, hostB]
        context.coordinator.scrollView = scrollView
        context.coordinator.speed = speed
        context.coordinator.startAutoScroll()

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let contentHeight = uiView.contentSize.height
        guard contentHeight > 0 else { return nil }
        return CGSize(width: width, height: contentHeight)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        var hostingControllers: [UIViewController] = []
        nonisolated(unsafe) var displayLink: CADisplayLink?
        private var isUserDragging: Bool = false
        var speed: CGFloat = 0

        func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func pauseAutoScroll() {
            displayLink?.isPaused = true
        }

        private func resumeAutoScroll() {
            normalizeOffset()
            displayLink?.isPaused = false
        }

        private func normalizeOffset() {
            guard let scrollView else { return }
            let singleContentWidth = scrollView.contentSize.width / 2.0
            guard singleContentWidth > 0 else { return }
            if scrollView.contentOffset.x >= singleContentWidth {
                scrollView.contentOffset.x -= singleContentWidth
            } else if scrollView.contentOffset.x < 0 {
                scrollView.contentOffset.x += singleContentWidth
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let scrollView, !isUserDragging else { return }
            let singleContentWidth = scrollView.contentSize.width / 2.0
            guard singleContentWidth > 0 else { return }

            var offset = scrollView.contentOffset
            offset.x += speed * CGFloat(link.duration)

            if offset.x >= singleContentWidth {
                offset.x -= singleContentWidth
            }

            scrollView.contentOffset = offset
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserDragging = true
            pauseAutoScroll()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                isUserDragging = false
                resumeAutoScroll()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserDragging = false
            resumeAutoScroll()
        }

        deinit {
            displayLink?.invalidate()
        }
    }
}

#Preview("Info") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { AssistantsInfoView().padding(.top, 20) }
}

#Preview("Confirmation") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) {
            AssistantsInfoView(isConfirmation: true, onConfirm: { }).padding(.top, 20)
        }
}
