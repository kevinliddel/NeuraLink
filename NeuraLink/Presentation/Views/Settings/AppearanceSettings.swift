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
    
    var backgroundImageData: Data?
    
    /// Returns the UI image representation of the background, if available.
    var backgroundUIImage: UIImage?
    
    private init() {
        if let url = backgroundImageURL, let data = try? Data(contentsOf: url) {
            self.backgroundImageData = data
            self.backgroundUIImage = UIImage(data: data)
        }
    }

    /// Saves a new custom background image to disk.
    func saveBackgroundImage(_ data: Data?) {
        guard let url = backgroundImageURL else { return }
        if let data = data {
            try? data.write(to: url)
            self.backgroundImageData = data
            self.backgroundUIImage = UIImage(data: data)
        } else {
            try? FileManager.default.removeItem(at: url)
            self.backgroundImageData = nil
            self.backgroundUIImage = nil
        }
    }

    private var backgroundImageURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(backgroundImageFilename)
    }
}
