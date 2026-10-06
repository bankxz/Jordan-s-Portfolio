import AuthenticationServices
import PeakKit
import SwiftUI

/// Shown until the creator connects Roblox. Roblox's own consent page opens in a system browser sheet;
/// Peak never sees the Roblox password.
struct SignInView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Peak")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Live players, revenue and alerts for your Roblox games, with what changed and what to do next.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                VStack(alignment: .leading, spacing: 14) {
                    Label("Peak can only read your stats. It can't change your games, prices, ads or groups.",
                          systemImage: "eye")
                    Label("On Roblox's page you choose which games Peak can see.", systemImage: "checkmark.shield")
                    Label("You sign in on Roblox. Peak never sees your password.", systemImage: "lock")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                if let message = account.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("signInMessage")
                }

                Button {
                    Task { await account.signIn(authenticate: authenticate) }
                } label: {
                    Group {
                        if account.state == .signingIn {
                            ProgressView()
                        } else {
                            Text("Sign in with Roblox")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(account.state == .signingIn)
                .accessibilityIdentifier("signInButton")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Opens Roblox's consent page and returns Peak's callback URL. Closing the sheet counts as cancelling.
    private func authenticate(_ url: URL) async throws -> URL {
        do {
            if #available(iOS 17.4, *) {
                return try await webAuthenticationSession.authenticate(
                    using: url, callback: .customScheme(Route.scheme), preferredBrowserSession: nil,
                    additionalHeaderFields: [:])
            }
            return try await webAuthenticationSession.authenticate(
                using: url, callbackURLScheme: Route.scheme, preferredBrowserSession: nil)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw CancellationError()
        }
    }
}

#Preview {
    SignInView()
        .environment(PreviewSupport.account(signedIn: false))
}
