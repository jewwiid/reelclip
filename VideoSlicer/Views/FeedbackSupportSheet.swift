import Foundation
import MessageUI
import SwiftUI
import UIKit

/// The category describes feedback, not the user, so it is useful to triage
/// without requiring an account or analytics identifier.
enum FeedbackCategory: String, CaseIterable, Codable, Identifiable {
    case bug
    case featureRequest
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return "Bug"
        case .featureRequest: return "Feature request"
        case .general: return "General"
        }
    }
}

struct FeedbackDiagnostics: Codable {
    let appVersion: String
    let build: String
    let systemVersion: String
    let deviceModel: String

    static var current: FeedbackDiagnostics {
        FeedbackDiagnostics(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model
        )
    }
}

struct FeedbackPayload: Codable {
    let category: FeedbackCategory
    let message: String
    let replyEmail: String?
    let diagnostics: FeedbackDiagnostics?
}

/// Reads public delivery configuration from Info.plist. A Convex HTTP Action
/// URL is public by design; never place an admin key or other secret in an app
/// bundle.
struct FeedbackConfiguration {
    let endpoint: URL?
    let supportEmail: String?

    static let current = FeedbackConfiguration(bundle: .main)

    init(bundle: Bundle) {
        let endpointValue = (bundle.object(forInfoDictionaryKey: "ReelClipFeedbackEndpoint") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateEndpoint = endpointValue.flatMap(URL.init(string:))
        endpoint = candidateEndpoint?.scheme?.lowercased() == "https" ? candidateEndpoint : nil

        let emailValue = (bundle.object(forInfoDictionaryKey: "ReelClipFeedbackEmail") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        supportEmail = Self.isValidEmail(emailValue) ? emailValue : nil
    }

    private static func isValidEmail(_ value: String?) -> Bool {
        guard let value,
              let atIndex = value.firstIndex(of: "@"),
              atIndex != value.startIndex,
              atIndex < value.index(before: value.endIndex)
        else {
            return false
        }
        return value[value.index(after: atIndex)...].contains(".")
    }
}

enum FeedbackDeliveryError: LocalizedError {
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "The support service did not accept the feedback."
        }
    }
}

enum FeedbackDeliveryClient {
    static func submit(_ payload: FeedbackPayload, to endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw FeedbackDeliveryError.unexpectedResponse
        }
    }
}

struct FeedbackSupportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let configuration = FeedbackConfiguration.current

    @State private var category: FeedbackCategory = .bug
    @State private var message = ""
    @State private var replyEmail = ""
    @State private var includeDiagnostics = false
    @State private var isSubmitting = false
    @State private var deliveryMessage: String?
    @State private var deliveryError: String?
    @State private var isMailComposerPresented = false

    private var normalizedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedReplyEmail: String? {
        let value = replyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var payload: FeedbackPayload {
        FeedbackPayload(
            category: category,
            message: normalizedMessage,
            replyEmail: normalizedReplyEmail,
            diagnostics: includeDiagnostics ? .current : nil
        )
    }

    private var submitTitle: String {
        configuration.endpoint == nil ? "Send by email" : "Send feedback"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        form
                        privacyNote
                        statusMessage
                        submitButton
                    }
                    .padding(18)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppPalette.accent)
                }
            }
        }
        .tint(AppPalette.accent)
        .sheet(isPresented: $isMailComposerPresented) {
            if let supportEmail = configuration.supportEmail {
                FeedbackMailComposer(
                    recipient: supportEmail,
                    subject: "ReelClip feedback: \(category.title)",
                    body: emailBody(for: payload)
                ) { result in
                    isMailComposerPresented = false
                    if result == .sent {
                        deliveryMessage = "Thanks. Your feedback was sent."
                        deliveryError = nil
                        PolishKit.Haptics.success.play()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppPalette.background)
                .frame(width: 42, height: 42)
                .background(AppPalette.accent, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Help shape ReelClip")
                    .font(.title3.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                Text("Report a problem or request what should come next.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Feedback type")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 0)
                Picker("Feedback type", selection: $category) {
                    ForEach(FeedbackCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppPalette.accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What happened or what would you like to see?")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                TextEditor(text: $message)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.sentences)
                    .font(.body)
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(minHeight: 156)
                    .padding(10)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }

                Text("\(normalizedMessage.count)/4000")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppPalette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Reply email (optional)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                TextField("name@example.com", text: $replyEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .font(.body)
                    .foregroundStyle(AppPalette.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }
            }

            Toggle(isOn: $includeDiagnostics) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Include app diagnostics")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("App version, iOS version, and device model only.")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                }
            }
            .tint(AppPalette.accent)
        }
        .premiumSurface()
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 20)
            Text("Nothing leaves this device until you send it. Video, projects, transcripts, and usage analytics are never included.")
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let deliveryMessage {
            feedbackStatusRow(deliveryMessage, systemImage: "checkmark.circle.fill", color: AppPalette.success)
        } else if let deliveryError {
            VStack(alignment: .leading, spacing: 10) {
                feedbackStatusRow(deliveryError, systemImage: "exclamationmark.triangle.fill", color: AppPalette.danger)
                if configuration.supportEmail != nil, configuration.endpoint != nil {
                    Button("Send by email instead") {
                        sendViaEmail()
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                }
            }
        }
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .tint(AppPalette.background)
                } else {
                    Image(systemName: configuration.endpoint == nil ? "envelope.fill" : "paperplane.fill")
                }
                Text(isSubmitting ? "Sending..." : submitTitle)
            }
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(AppPalette.background)
            .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || normalizedMessage.count < 4 || normalizedMessage.count > 4_000)
        .opacity(isSubmitting || normalizedMessage.count < 4 || normalizedMessage.count > 4_000 ? 0.45 : 1)
        .polishPressFeedback()
    }

    private func feedbackStatusRow(_ message: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.subheadline.weight(.bold))
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.5), lineWidth: 1)
        }
    }

    private func submit() {
        deliveryMessage = nil
        deliveryError = nil

        guard normalizedMessage.count >= 4, normalizedMessage.count <= 4_000 else {
            deliveryError = "Add between 4 and 4,000 characters before sending."
            return
        }

        if let endpoint = configuration.endpoint {
            isSubmitting = true
            Task {
                defer { isSubmitting = false }
                do {
                    try await FeedbackDeliveryClient.submit(payload, to: endpoint)
                    deliveryMessage = "Thanks. Your feedback was sent."
                    PolishKit.Haptics.success.play()
                } catch {
                    deliveryError = "We couldn't send that right now. Try again or send it by email."
                    PolishKit.Haptics.error.play()
                }
            }
        } else {
            sendViaEmail()
        }
    }

    private func sendViaEmail() {
        guard let supportEmail = configuration.supportEmail else {
            deliveryError = "Feedback delivery is not configured in this build."
            return
        }

        if MFMailComposeViewController.canSendMail() {
            isMailComposerPresented = true
            return
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ReelClip feedback: \(category.title)"),
            URLQueryItem(name: "body", value: emailBody(for: payload))
        ]
        guard let mailURL = components.url else {
            deliveryError = "Feedback email could not be prepared."
            return
        }
        openURL(mailURL)
        deliveryMessage = "Your email app has been opened with the feedback draft."
    }

    private func emailBody(for payload: FeedbackPayload) -> String {
        var sections = [
            "Type: \(payload.category.title)",
            "",
            payload.message
        ]
        if let replyEmail = payload.replyEmail {
            sections += ["", "Reply email: \(replyEmail)"]
        }
        if let diagnostics = payload.diagnostics {
            sections += [
                "",
                "Diagnostics (opted in):",
                "App: \(diagnostics.appVersion) (\(diagnostics.build))",
                "iOS: \(diagnostics.systemVersion)",
                "Device: \(diagnostics.deviceModel)"
            ]
        }
        return sections.joined(separator: "\n")
    }
}

private struct FeedbackMailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let onFinished: (MFMailComposeResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinished: (MFMailComposeResult) -> Void

        init(onFinished: @escaping (MFMailComposeResult) -> Void) {
            self.onFinished = onFinished
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinished(result)
            controller.dismiss(animated: true)
        }
    }
}
