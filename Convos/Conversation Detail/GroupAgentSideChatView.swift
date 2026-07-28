import SwiftUI

/// A deliberately static first pass of the private group-agent side chat.
/// It proves the three-space loop before a durable one-to-one conversation
/// model is wired in.
struct GroupAgentSideChatView: View {
    let agentName: String
    let groupName: String
    @Binding var draft: String

    @State private var sentPrompts: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.black)
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(agentName)
                    .font(.headline)
                Text("Your agent · private side chat · working for \(groupName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("LISTEN ONLY")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground))
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                agentBubble(
                    "Anything from \(groupName) can become work here. "
                        + "Drop context, request an edit, ask for research, or say what should happen next."
                )

                promptGrid

                ForEach(Array(sentPrompts.enumerated()), id: \.offset) { _, prompt in
                    userBubble(prompt)
                    agentBubble(
                        "Working on it quietly. The useful result, sources, and changes will come back to Things "
                            + "so everyone can keep improving it. You get the credit for moving the group forward."
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }

    private var promptGrid: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TRY ASKING")
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            prompt("Research this with everything the group shared")
            prompt("Update the plan and show everyone what changed")
            prompt("Ask each person privately for their thoughts")
            prompt("Connect the app or file needed to finish this")
            prompt("Leave a voice note and sort it all out")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prompt(_ text: String) -> some View {
        Button {
            draft = text
        } label: {
            HStack {
                Image(systemName: "plus")
                    .font(.caption.bold())
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.bold())
            }
            .foregroundStyle(.primary)
            .padding(13)
            .background(Color.primary.opacity(0.05))
            .clipShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func agentBubble(_ text: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black)
                .clipShape(Circle())

            Text(text)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.065))
                .clipShape(.rect(cornerRadius: 18))

            Spacer(minLength: 52)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 52)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.black)
                .clipShape(.rect(cornerRadius: 18))
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button {
                draft = "Here’s more context: "
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
            }

            TextField("Tell \(agentName) what to do", text: $draft, axis: .vertical)
                .lineLimit(1 ... 4)
                .foregroundStyle(.white)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(.white)
                    .clipShape(Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
        .clipShape(.capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        sentPrompts.append(prompt)
        draft = ""
    }
}
