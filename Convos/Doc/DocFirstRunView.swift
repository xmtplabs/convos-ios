import ConvosCore
import MessageUI
import SwiftUI
import UIKit

enum DocFirstRunStep: Equatable {
    case welcome
    case verify
    case sayHello
    case connectGoogle
    case home
}

enum DocFirstRunReducer {
    static func step(
        hasCompletedWelcome: Bool,
        hasCompletedFirstRun: Bool,
        hasVerifiedNumber: Bool,
        hasCompletedVerificationHello: Bool,
        hasGrantedGoogleDocs: Bool
    ) -> DocFirstRunStep {
        if hasCompletedFirstRun { return .home }
        if !hasCompletedWelcome { return .welcome }
        if !hasVerifiedNumber { return .verify }
        if !hasCompletedVerificationHello { return .sayHello }
        if !hasGrantedGoogleDocs { return .connectGoogle }
        return .home
    }
}

struct DocWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        DocFirstRunScaffold(
            systemImage: "doc.text.fill",
            title: "Your group talks. I keep the doc current.",
            message: "Start with screenshots or start in iMessage."
        ) {
            DocWelcomeTeaching()
        } action: {
            Button("Continue", action: onContinue)
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
                .accessibilityIdentifier("doc-welcome-continue")
        }
        .accessibilityIdentifier("doc-welcome")
    }
}

private struct DocWelcomeTeaching: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            teachingRow(
                systemImage: "photo.on.rectangle.angled",
                title: "Send screenshots",
                detail: "I'll turn them into the first doc."
            )
            teachingRow(
                systemImage: "bubble.left.and.bubble.right.fill",
                title: "Add @doc to a group",
                detail: "The first new text starts the doc."
            )
            Text("Connect later anytime—standalone docs work too.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func teachingRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorLava)
                .frame(width: 36.0, height: 36.0)
                .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 10.0))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DocVerifyFirstRunView: View {
    let flowState: DocVerificationFlowState
    let verification: DocControlVerification?
    let agentStartupState: DocAgentStartupSurfaceState
    let transportErrorMessage: String?
    let onRequest: (String) -> Void
    let onSubmit: (String) -> Void
    let onShowFallback: () -> Void
    let onEditNumber: () -> Void
    let onRenew: () -> Void
    let onRetryStartup: () -> Void

    private let phoneFormatter: DocPhoneNumberFormatter
    @State private var phoneText: String
    @State private var code: String = ""
    @State private var isDelayedFallbackAvailable: Bool = false
    @FocusState private var focusedField: Field?

    init(
        flowState: DocVerificationFlowState,
        verification: DocControlVerification?,
        rememberedNumber: String?,
        agentStartupState: DocAgentStartupSurfaceState,
        transportErrorMessage: String?,
        regionCode: String = Locale.current.region?.identifier ?? "US",
        onRequest: @escaping (String) -> Void,
        onSubmit: @escaping (String) -> Void,
        onShowFallback: @escaping () -> Void,
        onEditNumber: @escaping () -> Void,
        onRenew: @escaping () -> Void,
        onRetryStartup: @escaping () -> Void
    ) {
        self.flowState = flowState
        self.verification = verification
        self.agentStartupState = agentStartupState
        self.transportErrorMessage = transportErrorMessage
        self.onRequest = onRequest
        self.onSubmit = onSubmit
        self.onShowFallback = onShowFallback
        self.onEditNumber = onEditNumber
        self.onRenew = onRenew
        self.onRetryStartup = onRetryStartup
        let formatter = DocPhoneNumberFormatter(regionCode: regionCode)
        self.phoneFormatter = formatter
        _phoneText = State(initialValue: rememberedNumber.map(formatter.formatPartial) ?? formatter.initialText)
    }

    var body: some View {
        DocFirstRunScaffold(
            systemImage: systemImage,
            title: title,
            message: message
        ) {
            surfaceDetails
        } action: {
            surfaceAction
        }
        .accessibilityIdentifier("doc-first-run-verify")
        .task(id: flowState) {
            await prepareForCurrentState()
        }
        .task(id: agentStartupState) {
            await prepareForCurrentState()
        }
        .onChange(of: phoneText) { _, newValue in
            let formatted = phoneFormatter.formatPartial(newValue)
            if formatted != newValue {
                phoneText = formatted
            }
        }
        .onChange(of: code) { _, newValue in
            handleCodeChange(newValue)
        }
    }

    @ViewBuilder
    private var surfaceDetails: some View {
        switch agentStartupState {
        case .preparing:
            startupStatus(
                systemImage: nil,
                text: "Opening our private chat…",
                identifier: "doc-first-run-agent-preparing"
            )
        case .failed:
            startupStatus(
                systemImage: "exclamationmark.triangle.fill",
                text: "Your number hasn't been sent.",
                identifier: "doc-first-run-agent-startup-error"
            )
        case .ready:
            details
        }
    }

    @ViewBuilder
    private var surfaceAction: some View {
        switch agentStartupState {
        case .preparing:
            EmptyView()
        case .failed:
            Button("Try again", action: onRetryStartup)
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
                .accessibilityIdentifier("doc-first-run-agent-startup-retry")
        case .ready:
            actionContent
        }
    }

    private func startupStatus(
        systemImage: String?,
        text: String,
        identifier: String
    ) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.colorLava)
            } else {
                ProgressView()
            }
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .frame(maxWidth: .infinity, minHeight: 52.0)
        .background(.colorFillMinimal, in: RoundedRectangle(cornerRadius: 14.0))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var details: some View {
        switch flowState {
        case .enteringNumber, .requesting:
            phoneNumberEntry
        case let .enteringCode(number, attemptFailed):
            codeEntry(number: number, attemptFailed: attemptFailed)
        case let .submitting(number), let .awaitingVerification(number):
            codeEntry(number: number, attemptFailed: false)
        case .fallback:
            fallbackDetails
        case .verified:
            ProgressView()
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            if let transportErrorMessage {
                errorText(transportErrorMessage, identifier: "doc-first-run-verify-transport-error")
            }
            switch flowState {
            case .enteringNumber:
                numberAction
            case .requesting:
                waitingButton(label: "Sending code…")
            case .enteringCode:
                codeActions
            case .submitting, .awaitingVerification:
                waitingButton(label: "Checking code…")
            case .fallback:
                Button("Use another number", action: onEditNumber)
                    .frame(minHeight: 44.0)
                    .accessibilityIdentifier("doc-first-run-verify-edit-number")
            case .verified:
                waitingButton(label: "Verified")
            }
        }
    }

    private var phoneNumberEntry: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            TextField("Phone number", text: $phoneText)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.colorTextPrimary)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focusedField, equals: .phone)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .frame(minHeight: 58.0)
                .background(.colorFillMinimal, in: RoundedRectangle(cornerRadius: 14.0))
                .overlay {
                    RoundedRectangle(cornerRadius: 14.0)
                        .stroke(focusedField == .phone ? Color.colorLava : .clear, lineWidth: 1.0)
                }
                .disabled(isRequesting)
                .accessibilityIdentifier("doc-first-run-phone-number")

            Text(regionDescription)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func codeEntry(number: String, attemptFailed: Bool) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            DocVerificationCodeField(code: $code, isFocused: $focusedField, focusValue: .code)
            VStack(spacing: DesignConstants.Spacing.stepX) {
                Text("Sent to \(docDisplayPhoneNumber(number))")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .monospacedDigit()
                Button("Change number", action: onEditNumber)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44.0)
            }
            if attemptFailed {
                errorText("That code didn't work. Check it and try again.", identifier: "doc-first-run-code-error")
            }
        }
    }

    @ViewBuilder
    private var fallbackDetails: some View {
        if let verification, verification.status == .pending {
            DocVerificationFallbackPanel(verification: verification)
        } else if let verification, verification.status == .expired {
            VStack(spacing: DesignConstants.Spacing.step3x) {
                errorText("That backup code expired.", identifier: "doc-first-run-fallback-expired")
                Button("Get a new backup code", action: onRenew)
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
            }
        } else {
            VStack(spacing: DesignConstants.Spacing.step3x) {
                ProgressView("Preparing text verification…")
                Button("Try text verification", action: onRenew)
                    .convosButtonStyle(.outlineCapsule(fullWidth: true))
                    .frame(minHeight: 44.0)
            }
        }
    }

    private var numberAction: some View {
        let canRequestCode: Bool = phoneFormatter.e164(from: phoneText) != nil
        let request = {
            guard let number = phoneFormatter.e164(from: phoneText) else { return }
            focusedField = nil
            onRequest(number)
        }
        return Button("Send code", action: request)
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
            .frame(minHeight: 44.0)
            .disabled(!canRequestCode)
            .docFirstRunButtonAvailability(isAvailable: canRequestCode)
            .accessibilityIdentifier("doc-first-run-send-code")
    }

    private var codeActions: some View {
        let canSubmit: Bool = code.count == 6
        return VStack(spacing: DesignConstants.Spacing.step2x) {
            let verify = { onSubmit(code) }
            Button("Verify", action: verify)
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
                .disabled(!canSubmit)
                .docFirstRunButtonAvailability(isAvailable: canSubmit)
                .accessibilityIdentifier("doc-first-run-submit-code")

            if isDelayedFallbackAvailable {
                Button("Didn't get a code?", action: onShowFallback)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44.0)
                    .accessibilityIdentifier("doc-first-run-show-fallback")
            }
        }
    }

    private func waitingButton(label: String) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ProgressView()
                .tint(.colorTextPrimaryInverted)
            Text(label)
        }
        .foregroundStyle(.colorTextPrimaryInverted)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44.0)
        .background(.colorLava, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func errorText(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private var isRequesting: Bool {
        guard case .requesting = flowState else { return false }
        return true
    }

    private var systemImage: String {
        switch agentStartupState {
        case .preparing:
            return "ellipsis.message.fill"
        case .failed:
            return "exclamationmark.bubble.fill"
        case .ready:
            break
        }
        switch flowState {
        case .fallback:
            return "message.fill"
        default:
            return "checkmark.shield.fill"
        }
    }

    private var title: String {
        switch agentStartupState {
        case .preparing:
            return "Getting our chat ready"
        case .failed:
            return "I couldn't get ready"
        case .ready:
            break
        }
        switch flowState {
        case .enteringNumber, .requesting:
            return "What's your number?"
        case .enteringCode, .submitting, .awaitingVerification:
            return "Enter your code"
        case .fallback:
            return "Verify by text instead"
        case .verified:
            return "Number verified"
        }
    }

    private var message: String {
        switch agentStartupState {
        case .preparing:
            return "I'm opening our private chat. Verification will start as soon as it's ready."
        case .failed(let message):
            return message
        case .ready:
            break
        }
        switch flowState {
        case .enteringNumber, .requesting:
            return "I'll text you a six-digit code. Your number is how @doc knows which groups are yours."
        case .enteringCode, .submitting, .awaitingVerification:
            return "Enter the six digits I just texted you."
        case .fallback:
            return "Text the backup code to @doc. I'll recognize your number from the message."
        case .verified:
            return "You're all set."
        }
    }

    private var regionDescription: String {
        let locale = Locale.current
        let regionName = locale.localizedString(forRegionCode: phoneFormatter.regionCode) ?? phoneFormatter.regionCode
        return "Using \(regionName) (+\(phoneFormatter.callingCode)). You can paste any +country-code number."
    }

    private func prepareForCurrentState() async {
        guard agentStartupState == .ready else {
            focusedField = nil
            return
        }
        switch flowState {
        case .enteringNumber:
            focusedField = .phone
        case .enteringCode(_, let attemptFailed):
            if attemptFailed { code = "" }
            focusedField = .code
            isDelayedFallbackAvailable = false
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            isDelayedFallbackAvailable = true
        case .submitting, .awaitingVerification:
            focusedField = nil
        case .fallback, .requesting, .verified:
            focusedField = nil
        }
    }

    private func handleCodeChange(_ newValue: String) {
        let digits = String(newValue.filter(\.isNumber).prefix(6))
        if digits != newValue {
            code = digits
            return
        }
        guard digits.count == 6,
              case .enteringCode = flowState else {
            return
        }
        focusedField = nil
        onSubmit(digits)
    }

    fileprivate enum Field: Hashable {
        case phone
        case code
    }
}

struct DocVerificationHelloView: View {
    let lineNumber: String
    let onComplete: () -> Void

    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var isComposerPresented: Bool = false

    var body: some View {
        DocFirstRunScaffold(
            systemImage: "hand.wave.fill",
            title: "You're verified",
            message: "Want to say hi to @doc before we connect your Google account?"
        ) {
            Text("I'll text back so you know you've got the right line.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        } action: {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button("Say hi to @doc", action: sayHello)
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
                    .accessibilityIdentifier("doc-first-run-say-hi")
                Button("Skip", action: onComplete)
                    .frame(minHeight: 44.0)
                    .accessibilityIdentifier("doc-first-run-skip-hi")
            }
        }
        .sheet(isPresented: $isComposerPresented) {
            DocMessageComposeView(recipient: lineNumber, body: Constant.helloText) {
                isComposerPresented = false
                onComplete()
            }
        }
        .accessibilityIdentifier("doc-first-run-hello")
    }

    private func sayHello() {
        guard !lineNumber.isEmpty else {
            onComplete()
            return
        }
        if MFMessageComposeViewController.canSendText() {
            isComposerPresented = true
            return
        }
        guard let url = smsURL(lineNumber: lineNumber, body: Constant.helloText) else {
            onComplete()
            return
        }
        openURL(url)
        onComplete()
    }

    private func smsURL(lineNumber: String, body: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        guard let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "sms:\(lineNumber)&body=\(encodedBody)")
    }

    private enum Constant {
        static let helloText: String = "hi @doc — ready when you are 👋"
    }
}

private struct DocVerificationCodeField: View {
    @Binding var code: String
    @FocusState.Binding var isFocused: DocVerifyFirstRunView.Field?
    let focusValue: DocVerifyFirstRunView.Field

    var body: some View {
        ZStack {
            TextField("Verification code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused, equals: focusValue)
                .frame(width: 1.0, height: 1.0)
                .opacity(0.01)
                .accessibilityLabel("Six-digit verification code")

            HStack(spacing: DesignConstants.Spacing.step2x) {
                ForEach(0..<6, id: \.self) { index in
                    codeCell(at: index)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = focusValue }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 380.0)
        .frame(minHeight: 58.0)
        .accessibilityIdentifier("doc-first-run-code")
    }

    private func codeCell(at index: Int) -> some View {
        let character: String
        if index < code.count {
            character = String(code[code.index(code.startIndex, offsetBy: index)])
        } else {
            character = ""
        }
        return Text(character)
            .font(.title2.bold().monospacedDigit())
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56.0)
            .background(.colorFillMinimal, in: RoundedRectangle(cornerRadius: 12.0))
            .overlay {
                RoundedRectangle(cornerRadius: 12.0)
                    .stroke(isFocused == focusValue && index == min(code.count, 5) ? Color.colorLava : .clear, lineWidth: 1.0)
            }
    }
}

private struct DocVerificationFallbackPanel: View {
    let verification: DocControlVerification

    @State private var didCopyCode: Bool = false
    @State private var isWaitingForText: Bool = false

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            VStack(spacing: DesignConstants.Spacing.stepX) {
                Text("Text this backup code")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                Text(verification.code ?? "")
                    .font(.title2.bold().monospaced())
                    .foregroundStyle(.colorTextPrimary)
                    .textSelection(.enabled)
            }

            Button(action: copyCode) {
                Label(didCopyCode ? "Copied" : "Copy code", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
            }
            .convosButtonStyle(.outlineCapsule(fullWidth: true))
            .frame(minHeight: 44.0)

            DocVerificationActionButton(
                verification: verification,
                isWaitingForText: $isWaitingForText
            )

            if isWaitingForText {
                Label("Waiting for your text…", systemImage: "ellipsis.message")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
                    .transition(.opacity)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorFillMinimal, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
        .accessibilityIdentifier("doc-first-run-fallback")
    }

    private func copyCode() {
        guard let code = verification.code else { return }
        UIPasteboard.general.string = code
        withAnimation(.easeOut(duration: 0.16)) {
            didCopyCode = true
        }
    }
}

struct DocGoogleFirstRunView: View {
    let isConnecting: Bool
    let isWaitingForApproval: Bool
    let canConnect: Bool
    let isPreparing: Bool
    let errorMessage: String?
    let startupErrorMessage: String?
    let onConnect: () -> Void
    let onRetryStartup: () -> Void

    var body: some View {
        DocFirstRunScaffold(
            systemImage: "doc.text.fill",
            title: "Connect Google",
            message: "Your doc lives in your Google account, where it stays yours to open and share."
        ) {
            EmptyView()
        } action: {
            actionContent
        }
        .accessibilityIdentifier("doc-first-run-google")
    }

    private var actionContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            if isWaitingForApproval {
                Label("Waiting for approval…", systemImage: "ellipsis")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
                    .accessibilityIdentifier("doc-first-run-google-waiting")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("doc-first-run-google-error")
            } else if let startupErrorMessage, !canConnect {
                Text(startupErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if startupErrorMessage != nil, !canConnect {
                Button("Try again", action: onRetryStartup)
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
            } else {
                connectButton
            }
        }
    }

    private var connectButton: some View {
        let isAvailable: Bool = canConnect && !isConnecting
        return Button(action: onConnect) {
            connectButtonLabel
        }
        .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
        .frame(minHeight: 44.0)
        .disabled(isConnecting)
        .docFirstRunButtonAvailability(isAvailable: isAvailable)
        .accessibilityHint(isPreparing ? "Connects automatically when ready" : "")
        .accessibilityIdentifier("doc-first-run-google-connect")
    }

    @ViewBuilder
    private var connectButtonLabel: some View {
        if isConnecting {
            ProgressView()
                .tint(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Connecting Google")
        } else if isPreparing {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                Text("Getting ready…")
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            Text(errorMessage == nil ? "Connect Google" : "Try again")
        }
    }
}

private struct DocFirstRunScaffold<Details: View, Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let details: Details
    let action: Action

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder details: () -> Details,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.details = details()
        self.action = action()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: DesignConstants.Spacing.step8x)
                    Image(systemName: systemImage)
                        .font(.system(size: 56.0, weight: .medium))
                        .foregroundStyle(.colorLava)
                        .frame(width: 96.0, height: 96.0)
                        .background(
                            .colorFillMinimal,
                            in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                        )
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.colorTextPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: Constant.maximumTextWidth)
                        .padding(.top, DesignConstants.Spacing.step6x)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)

                    Text(message)
                        .font(.title3)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Constant.maximumTextWidth)
                        .padding(.top, DesignConstants.Spacing.step3x)
                        .padding(.horizontal, DesignConstants.Spacing.step8x)

                    details
                        .frame(maxWidth: Constant.maximumTextWidth)
                        .padding(.top, DesignConstants.Spacing.step5x)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)

                    Spacer(minLength: DesignConstants.Spacing.step8x)

                    action
                        .frame(maxWidth: Constant.maximumActionWidth)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)
                        .padding(.bottom, DesignConstants.Spacing.step6x)
                }
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Color.colorBackgroundSurfaceless)
    }
}

private extension View {
    func docFirstRunButtonAvailability(isAvailable: Bool) -> some View {
        opacity(isAvailable ? 1.0 : 0.45)
    }
}

private enum Constant {
    static let maximumTextWidth: CGFloat = 560.0
    static let maximumActionWidth: CGFloat = 440.0
}
