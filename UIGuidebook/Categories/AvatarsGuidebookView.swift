import SwiftUI

struct AvatarsGuidebookView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                monogramViewSection
                avatarViewSection
                profileAvatarViewSection
                conversationAvatarViewSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var monogramViewSection: some View {
        ComponentShowcase(
            "MonogramView",
            description: "Displays initials in a circular gradient background. Extracts up to 2 initials from name."
        ) {
            VStack(spacing: 20) {
                HStack(spacing: 20) {
                    VStack {
                        MonogramView(name: "John Doe")
                            .frame(width: 24)
                        Text("24pt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack {
                        MonogramView(name: "Jane Smith")
                            .frame(width: 40)
                        Text("40pt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack {
                        MonogramView(name: "Robert Adams")
                            .frame(width: 80)
                        Text("80pt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Different init options:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    VStack {
                        MonogramView(name: "A")
                            .frame(width: 48)
                        Text("Single")
                            .font(.caption2)
                    }

                    VStack {
                        MonogramView(text: "XY")
                            .frame(width: 48)
                        Text("Custom text")
                            .font(.caption2)
                    }

                    VStack {
                        MonogramView(name: "Multi Word Name Here")
                            .frame(width: 48)
                        Text("Long name")
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var avatarViewSection: some View {
        ComponentShowcase(
            "AvatarView",
            description: "Loads images from URL with caching. Falls back to MonogramView when no image available."
        ) {
            VStack(spacing: 16) {
                Text("AvatarView requires ConvosCore types (ImageCacheable). In production, it:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Loads from URL with caching", systemImage: "checkmark.circle.fill")
                    Label("Shows MonogramView as fallback", systemImage: "checkmark.circle.fill")
                    Label("Supports placeholder images", systemImage: "checkmark.circle.fill")
                    Label("Uses system symbol placeholders", systemImage: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    VStack {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundStyle(.colorFillTertiary)
                        Text("System placeholder")
                            .font(.caption2)
                    }

                    VStack {
                        MonogramView(name: "Fallback")
                            .frame(width: 60)
                        Text("Monogram fallback")
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var profileAvatarViewSection: some View {
        ComponentShowcase(
            "ProfileAvatarView",
            description: "Specialized avatar for user profiles. Wraps AvatarView with Profile-specific configuration."
        ) {
            VStack(spacing: 16) {
                Text("ProfileAvatarView is a convenience wrapper around AvatarView that takes a Profile object from ConvosCore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 24) {
                    VStack {
                        ZStack {
                            Circle()
                                .fill(.colorFillTertiary)
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                                .foregroundStyle(.colorTextPrimaryInverted)
                        }
                        .frame(width: 60, height: 60)
                        Text("With placeholder")
                            .font(.caption2)
                    }

                    VStack {
                        MonogramView(name: "Profile Name")
                            .frame(width: 60)
                        Text("Without image")
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var conversationAvatarViewSection: some View {
        ComponentShowcase(
            "ConversationAvatarView",
            description: "Avatar for conversations. Shows conversation image or empty monogram."
        ) {
            VStack(spacing: 16) {
                Text("ConversationAvatarView handles group conversations by showing the conversation's custom image if set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 24) {
                    VStack {
                        ZStack {
                            Circle()
                                .fill(.colorFillTertiary)
                            Image(systemName: "person.2.fill")
                                .resizable()
                                .scaledToFit()
                                .padding(16)
                                .foregroundStyle(.colorTextPrimaryInverted)
                        }
                        .frame(width: 60, height: 60)
                        Text("Group convo")
                            .font(.caption2)
                    }

                    VStack {
                        MonogramView(text: "")
                            .frame(width: 60)
                        Text("No image set")
                            .font(.caption2)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        AvatarsGuidebookView()
            .navigationTitle("Avatars")
    }
}
