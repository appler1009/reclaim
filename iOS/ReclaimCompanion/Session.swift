import Foundation
import ReclaimKit
import SwiftUI
import UIKit

/// One Mac, once the app has decided to talk to it.
///
/// Owns the connection, the pairing state and the tab list. Views observe it;
/// nothing in here knows what a view looks like.
@MainActor
final class MacSession: ObservableObject {
    enum Phase: Equatable {
        case connecting
        /// Reached, but this device is not allowed in yet.
        case needsPairing(CompanionAPI.ServiceInfo)
        case ready
        case failed(String)
    }

    let mac: DiscoveredMac
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var tabs: [CompanionAPI.TabSummary] = []
    /// Set by a failed refresh, so a stale list can stay on screen with a note
    /// above it rather than being replaced by an error page.
    @Published private(set) var warning: String?

    private var client: CompanionClient?

    init(mac: DiscoveredMac) {
        self.mac = mac
    }

    /// Resolves the Mac, works out whether this device is paired, and loads the
    /// tabs if it is.
    func connect() async {
        phase = .connecting
        do {
            let base = try await Resolver.baseURL(for: mac)
            let client = CompanionClient(baseURL: base, token: TokenStore.token(for: mac.id))
            self.client = client

            if await client.isPaired {
                try await loadTabs(client)
                phase = .ready
            } else {
                phase = .needsPairing(try await client.info())
            }
        } catch CompanionClient.Failure.notPaired {
            TokenStore.forget(mac.id)
            await askToPair()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Trades a code for a token and goes straight on to the tabs, because that
    /// is what the person typing it wanted.
    /// The device name is read here rather than defaulted in the signature: a
    /// default argument is evaluated outside this actor, and `UIDevice` belongs
    /// to the main one.
    func pair(code: String, device: String? = nil) async -> String? {
        guard let client else { return "Not connected to this Mac." }
        do {
            let paired = try await client.pair(code: code,
                                               device: device ?? UIDevice.current.name)
            TokenStore.save(paired.token, for: mac.id)
            try await loadTabs(client)
            phase = .ready
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refresh() async {
        guard let client, case .ready = phase else { return }
        do {
            try await loadTabs(client)
            warning = nil
        } catch CompanionClient.Failure.notPaired {
            TokenStore.forget(mac.id)
            await askToPair()
        } catch {
            warning = error.localizedDescription
        }
    }

    /// One folder of one tab. Thrown errors are the caller's to show, because
    /// the caller is a screen that may already be showing something useful.
    func node(tab: String, path: String?) async throws -> CompanionAPI.Node {
        guard let client else { throw CompanionClient.Failure.notPaired }
        return try await client.node(tab: tab, path: path)
    }

    func unpair() {
        TokenStore.forget(mac.id)
        tabs = []
        Task { await connect() }
    }

    private func loadTabs(_ client: CompanionClient) async throws {
        tabs = try await client.tabs()
    }

    private func askToPair() async {
        guard let client else { return }
        do {
            phase = .needsPairing(try await client.info())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
