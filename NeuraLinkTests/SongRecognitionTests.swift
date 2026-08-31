//
//  SongRecognitionTests.swift
//  NeuraLinkTests
//
//  Tests for the song-recognition domain entity (link building).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Song Recognition Tests")
struct SongRecognitionTests {

    @Test("YouTube link encodes title and artist")
    @MainActor
    func youtubeLink() {
        let song = RecognizedSong(
            title: "Golden Hour", artist: "JVKE", artworkURL: nil, appleMusicURL: nil)
        #expect(
            song.youtubeLink?.absoluteString
                == "https://www.youtube.com/results?search_query=Golden%20Hour%20JVKE")
    }

    @Test("Apple Music link prefers the exact catalog URL from the match")
    @MainActor
    func appleMusicCatalogLink() {
        let catalog = URL(string: "https://music.apple.com/us/album/golden-hour/1629178474")!
        let song = RecognizedSong(
            title: "Golden Hour", artist: "JVKE", artworkURL: nil, appleMusicURL: catalog)
        #expect(song.appleMusicLink == catalog)
    }

    @Test("Apple Music link falls back to a search when the match has no catalog URL")
    @MainActor
    func appleMusicSearchFallback() {
        let song = RecognizedSong(
            title: "Ramen & Sushi", artist: "Tokyo Band", artworkURL: nil, appleMusicURL: nil)
        let link = song.appleMusicLink?.absoluteString ?? ""
        #expect(link.hasPrefix("https://music.apple.com/search?term="))
        #expect(link.contains("Ramen%20%26%20Sushi"))
        #expect(!link.contains(" "))
    }
}
