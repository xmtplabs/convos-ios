import SwiftUI

struct AnimationsGuidebookView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                draggableSpringySection
                relativeDateLabelSection
                imagePickerButtonSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var draggableSpringySection: some View {
        ComponentShowcase(
            "DraggableSpringyView",
            description: "Wrapper that adds elastic drag gestures with spring physics and haptic feedback"
        ) {
            VStack(spacing: 20) {
                Text("Drag the card below to see the spring effect:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DraggableSpringyView(
                    maxDragDistance: 80,
                    springStiffness: 200,
                    springDamping: 20
                ) {
                    VStack(spacing: 12) {
                        Image(systemName: "hand.draw")
                            .font(.largeTitle)
                            .foregroundStyle(.colorFillPrimary)
                        Text("Drag me!")
                            .font(.headline)
                        Text("I'll spring back")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.colorBackgroundRaised)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                }
                .frame(height: 150)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Configurable parameters:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    Group {
                        Label("maxDragDistance: CGFloat", systemImage: "arrow.left.and.right")
                        Label("springStiffness: CGFloat", systemImage: "waveform.path")
                        Label("springDamping: CGFloat", systemImage: "waveform")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var relativeDateLabelSection: some View {
        ComponentShowcase(
            "RelativeDateLabel",
            description: "Auto-updating label that shows relative time (e.g., '2 min ago', 'Yesterday')"
        ) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Just now")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Date()")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    HStack {
                        Text("2 minutes ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Date().addingTimeInterval(-120)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    HStack {
                        Text("Yesterday")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    HStack {
                        Text("Last week")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("Updates automatically using TimelineView")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var imagePickerButtonSection: some View {
        ComponentShowcase(
            "ImagePickerButton",
            description: "Button that presents photo picker and handles image selection"
        ) {
            VStack(spacing: 16) {
                Text("ImagePickerButton wraps PhotosUI and provides a simple callback-based API for image selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    VStack {
                        ZStack {
                            Circle()
                                .fill(.colorFillSecondary)
                                .frame(width: 60, height: 60)
                            Image(systemName: "photo.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.colorFillPrimary)
                        }
                        Text("Add Photo")
                            .font(.caption)
                    }

                    VStack {
                        ZStack {
                            Circle()
                                .fill(.colorFillSecondary)
                                .frame(width: 60, height: 60)
                            Image(systemName: "camera")
                                .font(.title2)
                                .foregroundStyle(.colorFillPrimary)
                        }
                        Text("Camera")
                            .font(.caption)
                    }
                }

                Text("Usage: ImagePickerButton(image:isImagePickerPresented:)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        AnimationsGuidebookView()
            .navigationTitle("Animations")
    }
}
