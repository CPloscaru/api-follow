import Foundation

/// Reads (never writes/modifies) Claude Code CLI's own OAuth credentials
/// from the system Keychain, to reuse for Claude plan usage tracking.
///
/// This is a genuinely different trust model from `KeychainStore`: that
/// type owns keys THIS app creates, so `SecItemCopyMatching` on them is
/// safe and instant. This type reads a credential owned by a DIFFERENT
/// app (Claude Code) — accessing another app's Keychain item can trigger
/// a macOS authorization prompt ("APIFollow wants to access a Keychain
/// item owned by Claude Code"), and in a non-interactive/automated
/// context (including this app's own background poller, and CI/test
/// runs) nobody is there to click it — `SecItemCopyMatching` then hangs
/// until a long OS-level timeout. Confirmed by hitting this directly: a
/// test exercising the real reader took ~31s instead of instant.
///
/// Fix, matching what community Claude usage trackers already had to
/// engineer around for the same reason: shell out to `/usr/bin/security`
/// as a subprocess with an explicit, short, hard timeout — if it doesn't
/// return in time, kill it and treat the credential as unavailable
/// rather than let the whole poller hang forever on one blocked call.
struct ClaudeCodeCredentialReader {
    private static let legacyServiceName = "Claude Code-credentials"
    private static let commandTimeout: TimeInterval = 3.0

    struct OAuthCredentials: Decodable {
        struct Inner: Decodable {
            let accessToken: String
        }
        let claudeAiOauth: Inner
    }

    /// Returns the access token, or nil if Claude Code isn't installed/
    /// logged in on this machine, or the read didn't complete within
    /// the timeout (treated as "unavailable this cycle", not an error —
    /// the poller just tries again next cycle).
    func readAccessToken() -> String? {
        guard let json = runSecurityFindPassword() else { return nil }
        guard let data = json.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(OAuthCredentials.self, from: data)
        else {
            return nil
        }
        return credentials.claudeAiOauth.accessToken
    }

    /// Runs `security find-generic-password -w` as a bounded subprocess.
    /// Never calls `SecItemCopyMatching` directly for this cross-app
    /// item — see the type's doc comment for why.
    private func runSecurityFindPassword() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", Self.legacyServiceName,
            "-a", NSUserName(),
            "-w",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + Self.commandTimeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 0.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
