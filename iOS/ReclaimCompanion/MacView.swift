import ReclaimKit
import SwiftUI

/// One Mac: pairing if it has to happen, then the tabs it has open.
struct MacView: View {
    let mac: DiscoveredMac
    @StateObject private var session: MacSession

    init(mac: DiscoveredMac) {
        self.mac = mac
        _session = StateObject(wrappedValue: MacSession(mac: mac))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch session.phase {
            case .connecting:
                Notice(icon: "antenna.radiowaves.left.and.right",
                       title: "Reaching \(mac.name)", busy: true)
            case .needsPairing(let info):
                PairingView(info: info) { code in await session.pair(code: code) }
            case .failed(let message):
                Notice(icon: "exclamationmark.triangle", title: "Cannot reach \(mac.name)",
                       detail: message,
                       action: ("Try Again", { Task { await session.connect() } }))
            case .ready:
                TabsView(session: session)
            }
        }
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.panel, for: .navigationBar)
        .task { await session.connect() }
    }
}

/// Typing the six digits the Mac is showing.
struct PairingView: View {
    let info: CompanionAPI.ServiceInfo
    let pair: (String) async -> String?

    @State private var code = ""
    @State private var failure: String?
    @State private var working = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.desktopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(Theme.ember)
            Text("Pair with \(info.name)").font(.headline)
            Text(info.pairingOpen
                 ? "Type the six digits showing on your Mac."
                 : "On your Mac, open Reclaim → Settings → Companion and press "
                     + "Pair a Device. Then type the six digits it shows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($typing)
                .padding(.vertical, 10)
                .frame(maxWidth: 260)
                .panel()
                .onChange(of: code) { _, entered in
                    // Digits only, six of them, and it submits itself: a
                    // six-digit code has no other shape to check.
                    code = String(entered.filter(\.isNumber).prefix(6))
                    if code.count == 6 { submit() }
                }

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.caution)
                    .multilineTextAlignment(.center)
            }
            if working { ProgressView() }
        }
        .padding(28)
        .frame(maxWidth: 420)
        .onAppear { typing = true }
    }

    private func submit() {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            let result = await pair(code)
            working = false
            if let result {
                failure = result
                code = ""
                typing = true
            }
        }
    }
}
