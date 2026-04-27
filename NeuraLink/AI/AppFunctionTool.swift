//
//  AppFunctionTool.swift
//  NeuraLink
//
//  Declares the OpenAI Realtime tool schemas for iOS app interactions.
//  These are injected into session.update so the AI can call them naturally.
//
//  Created by Dedicatus on 27/04/2026.
//

import Foundation

/// All tool definitions sent to OpenAI during session.update.
enum AppFunctionTool {

    // MARK: - Tool name constants

    static let getWeather = "get_weather"
    static let searchWeb = "search_web"
    static let playMusic = "play_music"
    static let createReminder = "create_reminder"
    static let createNote = "create_note"
    static let openApp = "open_app"
    static let analyzeCamera = "analyze_camera"

    // MARK: - OpenAI tool schema array

    /// Returns the full `tools` array ready to embed in a session.update payload.
    static var all: [[String: Any]] {
        [weatherTool, searchTool, musicTool, reminderTool, noteTool, openAppTool, cameraTool]
    }

    // MARK: - Individual schemas

    private static var weatherTool: [String: Any] {
        [
            "type": "function",
            "name": getWeather,
            "description": "Get the current weather for any city or location. "
                + "Call this whenever the user asks about weather, temperature, rain, or climate.",
            "parameters": [
                "type": "object",
                "properties": [
                    "location": [
                        "type": "string",
                        "description": "City name or location, e.g. 'Tokyo' or 'New York, US'"
                    ]
                ],
                "required": ["location"]
            ]
        ]
    }

    private static var searchTool: [String: Any] {
        [
            "type": "function",
            "name": searchWeb,
            "description": "Search the web via Safari. Use this when the user asks you to look "
                + "something up, search for information, or open a website.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search query or URL to open"
                    ]
                ],
                "required": ["query"]
            ]
        ]
    }

    private static var musicTool: [String: Any] {
        [
            "type": "function",
            "name": playMusic,
            "description": "Search for and play music in Apple Music. Use this when the user "
                + "asks to play a song, artist, album, or playlist.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Song name, artist, album, or playlist to play"
                    ]
                ],
                "required": ["query"]
            ]
        ]
    }

    private static var reminderTool: [String: Any] {
        [
            "type": "function",
            "name": createReminder,
            "description": "Create a reminder in the Reminders app. Use this when the user "
                + "asks to set a reminder, alert, or todo item.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "The reminder text"
                    ],
                    "notes": [
                        "type": "string",
                        "description": "Optional additional details for the reminder"
                    ]
                ],
                "required": ["title"]
            ]
        ]
    }

    private static var noteTool: [String: Any] {
        [
            "type": "function",
            "name": createNote,
            "description": "Open the Notes app and create a new note. Use this when the user "
                + "asks to write something down, take a note, or save information.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Title of the note"
                    ],
                    "body": [
                        "type": "string",
                        "description": "The main content of the note"
                    ]
                ],
                "required": ["title", "body"]
            ]
        ]
    }

    private static var cameraTool: [String: Any] {
        [
            "type": "function",
            "name": analyzeCamera,
            "description": "Look through the device camera and describe what you see. "
                + "Use this whenever the user asks you to look, see, observe, or describe "
                + "something in front of the camera.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description":
                            "Optional focus for the description, e.g. 'describe the person' "
                            + "or 'what objects are visible'"
                    ]
                ],
                "required": []
            ]
        ]
    }

    private static var openAppTool: [String: Any] {
        [
            "type": "function",
            "name": openApp,
            "description": "Open a built-in iOS app by name. Use this when the user asks to "
                + "open an app like Maps, Photos, Calendar, Settings, Camera, or Clock.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": [
                        "type": "string",
                        "enum": [
                            "Maps", "Photos", "Calendar", "Settings",
                            "Camera", "Clock", "Health", "FaceTime"
                        ],
                        "description": "The name of the app to open"
                    ]
                ],
                "required": ["app"]
            ]
        ]
    }
}
