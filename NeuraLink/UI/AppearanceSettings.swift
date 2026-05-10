//
//  AppearanceSettings.swift
//  NeuraLink
//
//  Created by Dedicatus on 08/05/2026. 
// 

import Foundation
import SwiftUI

/// Manages appearance preferences such as environment visibility and custom backgrounds.
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    // For storing the custom background image data to the app's documents directory
    private let backgroundImageFilename = "custom_background.jpg"
    
    /// Loads the custom background image data from disk, if it exists.
    var backgroundImageData: Data? {
        guard let url = backgroundImageURL else { return nil }
        return try? Data(contentsOf: url)
    }
    
    /// Returns the UI image representation of the background, if available.
    var backgroundUIImage: UIImage? {
        guard let data = backgroundImageData else { return nil }
        return UIImage(data: data)
    }

    /// Saves a new custom background image to disk.
    func saveBackgroundImage(_ data: Data?) {
        guard let url = backgroundImageURL else { return }
        if let data = data {
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var backgroundImageURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(backgroundImageFilename)
    }
}
