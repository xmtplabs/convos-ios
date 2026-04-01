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
        scrollView.alwaysBounceHorizontal = true

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.speed = speed
        context.coordinator.startAutoScroll()

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let height = uiView.contentSize.height
        guard height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, @unchecked Sendable {
        weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var isAutoScrolling: Bool = true
        var speed: CGFloat = 0

        func startAutoScroll() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .default)
            displayLink = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let scrollView, isAutoScrolling else { return }
            let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            guard maxOffset > 0 else { return }

            var offset = scrollView.contentOffset
            offset.x += speed * CGFloat(link.duration)
            if offset.x >= maxOffset {
                offset.x = maxOffset
                stopAutoScroll()
            }
            scrollView.contentOffset = offset
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            stopAutoScroll()
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
            isAutoScrolling = false
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
