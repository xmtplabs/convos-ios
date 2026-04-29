import SwiftUI

struct CapabilityApprovedToastView: View {
    var body: some View {
        Group {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.colorLava)

                Text("Connection approved")
                    .foregroundStyle(.colorTextPrimary)
            }
            .font(.body)
            .padding(.vertical, DesignConstants.Spacing.step3HalfX)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
        .background(
            Capsule()
                .fill(.colorFillMinimal)
        )
    }
}

#Preview {
    CapabilityApprovedToastView()
        .padding()
}
