import SwiftUI

struct AppleAdsPlatformCredentialsSection: View {
    @Binding var clientID: String
    @Binding var teamID: String
    @Binding var keyID: String
    @Binding var privateKey: String
    @Binding var adAccountID: String

    let privateKeyValidationIssue: String?
    let canVerify: Bool
    let hasStoredCredentials: Bool
    let isVerifying: Bool
    let status: VerificationStatus?
    let verifyAction: () -> Void
    let clearAction: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Client ID")
                    .font(.callout)
                    .bold()
                TextField("Client ID", text: $clientID, prompt: Text("SEARCHADS.…"))
                    .labelsHidden()
                    .textContentType(.username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("The OAuth client identifier issued by Apple Ads.")
            }

            VStack(alignment: .leading) {
                Text("Team ID")
                    .font(.callout)
                    .bold()
                TextField("Team ID", text: $teamID, prompt: Text("SEARCHADS.…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("The Apple Ads team identifier associated with the private key.")
            }

            VStack(alignment: .leading) {
                Text("Key ID")
                    .font(.callout)
                    .bold()
                TextField("Key ID", text: $keyID, prompt: Text("Key identifier"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("The identifier for the Apple Ads private key.")
            }

            VStack(alignment: .leading) {
                Text("Private key")
                    .font(.callout)
                    .bold()
                TextField(
                    "Private key",
                    text: $privateKey,
                    prompt: Text("Paste BEGIN PRIVATE KEY…"),
                    axis: .vertical
                )
                .labelsHidden()
                .lineLimit(3...7)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .privacySensitive()
                .accessibilityHint("Paste the complete private p8 key. Public keys cannot authenticate requests.")

                if let privateKeyValidationIssue {
                    Label(privateKeyValidationIssue, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading) {
                Text("Ad account")
                    .font(.callout)
                    .bold()
                TextField("Ad account", text: $adAccountID, prompt: Text("Select automatically"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("Optional. Leave empty to use the first accessible Apple Ads account.")
            }

            HStack(spacing: 10) {
                Button("Verify & Save", action: verifyAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isVerifying || !canVerify || privateKeyValidationIssue != nil)

                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Verifying Apple Ads credentials")
                }

                Spacer()

                Link(
                    "Setup guide",
                    destination: URL(string: "https://developer.apple.com/documentation/apple-ads-platform-api")!
                )

                Button("Clear", role: .destructive, action: clearAction)
                    .disabled(isVerifying || !hasStoredCredentials)
            }

            if let status {
                Label(status.message, systemImage: status.systemImage)
                    .foregroundStyle(status.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Apple Ads Platform API")
        } footer: {
            Text("The private key is stored in macOS Keychain. Search Term Popularity and other Apple Ads requests use this API connection.")
        }
    }
}
