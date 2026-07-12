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
        // Google Drive is always available (empty until its OAuth client is
        // configured, in which case the connect button appears). The JSON
        // fixture named by NEODISK_CLOUD_FIXTURE is appended for tests and
        // screenshots — its account shows without OAuth.
        var providers: [any CloudProvider] = []
        var connectMenu: [(id: String, title: String)] = []

        let googleConfig = GoogleOAuthConfiguration.fromEnvironment(environment)
        let google = GoogleDriveProvider(
            configuration: googleConfig,
            transport: URLSessionTransport(),
            tokenStore: KeychainTokenStore()
        )
        providers.append(google)
        if googleConfig.isConfigured {
            connectMenu.append((id: google.providerID, title: "Connect Google Drive…"))
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
