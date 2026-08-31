//
//  RecognizedSong.swift
//  NeuraLink
//
//  Domain entity for a song identified from ambient audio.
//  Framework-free on purpose: the ShazamKit mapping lives in the Data layer
//  (SongRecognitionManager) so this stays a pure value type.
//
//  Created by Dedicatus on 31/08/2026.
//

import Foundation

/// A song identified from the microphone (song-recognition feature).
struct RecognizedSong: Equatable {
    let title: String
    let artist: String
    let artworkURL: URL?
    /// Direct Apple Music catalog URL from the match, when the catalog has one.
    let appleMusicURL: URL?

    /// Apple Music link: the exact catalog URL when the match carried one,
    /// otherwise a search deep link. `https://music.apple.com` universal links
    /// open the Music app directly — no LSApplicationQueriesSchemes entry needed.
    var appleMusicLink: URL? {
        appleMusicURL ?? URL(string: "https://music.apple.com/search?term=\(searchQuery.urlEncoded)")
    }

    /// YouTube search results for the song. Uses https so no scheme
    /// declaration is required; iOS hands it to the YouTube app when installed.
    var youtubeLink: URL? {
        URL(string: "https://www.youtube.com/results?search_query=\(searchQuery.urlEncoded)")
    }

    private var searchQuery: String { "\(title) \(artist)" }
}
