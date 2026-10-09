//
//  AppVersion+Channel.swift
//  Neodisk
//

import NeodiskKit

extension AppVersion {
    /// The version as shown: a nightly says so.
    package static var display: String {
        AppChannel.current == .nightly ? "\(string) nightly" : string
    }
}
