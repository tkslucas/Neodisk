//
//  CloudScanFactory.swift
//  Neodisk
//
//  Builds the CloudScan integration for the app, or returns nil when the
//  feature is unavailable (CloudScanKit excluded from the build) or unasked
//  for (no fixture; real providers come later). The app wires whatever this
//  returns into the view model and the routing scan service.
//

import Foundation
import NeodiskKit
#if canImport(CloudScanKit)
import AppKit
import CloudScanKit
#endif

enum CloudScanFactory {
#if canImport(CloudScanKit)
    @MainActor
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any CloudScanIntegrating)? {
        // Every provider is always constructed (stored accounts keep working);
        // its connect action appears only once its OAuth client is configured.
        // The JSON fixture named by NEODISK_CLOUD_FIXTURE is appended for
        // tests and screenshots — its account shows without OAuth.
        var providers: [any CloudProvider] = []
        var connectMenu: [(id: String, title: String)] = []

        // Headless capture modes must not read the Keychain: account restore
        // runs at launch, and from a binary whose code signature differs from
        // the one that wrote the token item (e.g. a dev `swift run` build vs
        // the packaged app) macOS puts an access prompt on screen — the one
        // thing a headless run must never do. An empty in-memory store keeps
        // captures deterministic; the fixture provider is unaffected.
        let headlessCapture = environment["NEODISK_UI_SNAPSHOT"] != nil
            || CommandLine.arguments.contains("--render-png")
        func makeTokenStore() -> any TokenStoring {
            headlessCapture ? InMemoryTokenStore() : KeychainTokenStore()
        }

        let googleConfig = GoogleOAuthConfiguration.fromEnvironment(environment)
        let google = GoogleDriveProvider(
            configuration: googleConfig,
            transport: URLSessionTransport(),
            tokenStore: makeTokenStore()
        )
        providers.append(google)
        if googleConfig.isConfigured {
            connectMenu.append((id: google.providerID, title: "Connect Google Drive…"))
        }

        let dropboxConfig = DropboxOAuthConfiguration.fromEnvironment(environment)
        let dropbox = DropboxProvider(
            configuration: dropboxConfig,
            transport: URLSessionTransport(),
            tokenStore: makeTokenStore()
        )
        providers.append(dropbox)
        if dropboxConfig.isConfigured {
            connectMenu.append((id: dropbox.providerID, title: "Connect Dropbox…"))
        }

        let oneDriveConfig = OneDriveOAuthConfiguration.fromEnvironment(environment)
        let oneDrive = OneDriveProvider(
            configuration: oneDriveConfig,
            transport: URLSessionTransport(),
            tokenStore: makeTokenStore()
        )
        providers.append(oneDrive)
        if oneDriveConfig.isConfigured {
            connectMenu.append((id: oneDrive.providerID, title: "Connect OneDrive…"))
        }

        if let fixturePath = environment["NEODISK_CLOUD_FIXTURE"] {
            do {
                providers.append(try FixtureCloudProvider(contentsOf: URL(filePath: fixturePath)))
            } catch {
                FileHandle.standardError.write(
                    Data("Neodisk: could not load cloud fixture at \(fixturePath): \(error)\n".utf8)
                )
            }
        }

        let service = CloudScanService(providers: providers)
        return CloudScanModel(
            service: service,
            providers: providers,
            connectMenu: connectMenu,
            // NSWorkspace wants the main thread; the authorizer calls this
            // from a background task.
            openURL: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        )
    }
#else
    @MainActor
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any CloudScanIntegrating)? {
        nil
    }
#endif
}
