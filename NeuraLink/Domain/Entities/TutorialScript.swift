//
//  TutorialScript.swift
//  NeuraLink
//
//  The onboarding tour, written out as data. Adding, removing or rewording a
//  beat only touches this file — bump `version` whenever the change is big
//  enough that people who already finished the tour should see it again.
//
//  Created by Dedicatus on 15/09/2026.
//

import Foundation

enum TutorialScript {

    /// Bumping this replays the tour once for everyone on next launch.
    /// v2 added the "bring your own brain" and profile/memory beats.
    static let version = 2

    static let steps: [TutorialStep] = [
        TutorialStep(
            id: "welcome",
            icon: "sparkles",
            title: "Welcome to NeuraLink",
            body:
                "Your companion lives here, in 3D, on your device. This quick tour walks through every control — about a minute.",
            tip: "Tap anywhere to continue."),

        TutorialStep(
            id: "stage",
            icon: "hand.draw",
            title: "The Stage",
            body:
                "Drag to orbit the camera, pinch to zoom, and tap your companion to poke them — they react to it.",
            tip: "The sky and lighting follow your real local time of day."),

        TutorialStep(
            id: "voice",
            icon: "waveform",
            title: "Just Talk",
            body:
                "This capsule is your companion's status: Ready, Listening, Thinking, Speaking. When it says \"Start talking\", speak out loud — there's no button to hold down.",
            tip: "While it reads \"Tap to configure LLMs\", tap it to pick a brain: OpenAI, or a fully offline on-device model.",
            anchor: .statusHint),

        TutorialStep(
            id: "brains",
            icon: "key.fill",
            title: "Bring Your Own Brain",
            body:
                "NeuraLink ships without an AI of its own. Either paste your own OpenAI API key — it stays on this device and the usage is billed to your account — or download a local model and run everything offline, free, with no account at all.",
            tip:
                "Both live in Settings: \"Enable OpenAI\" for the key, \"Model Library\" for the offline models. One at a time — turning one on turns the other off.",
            anchor: .statusHint),

        TutorialStep(
            id: "history",
            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            title: "Chat History",
            body:
                "Every conversation is saved on device. Open the sidebar to reread a past chat, start a fresh one, or jump to your profile.",
            tip: "Starting a new chat clears the companion's working context — memories are kept.",
            anchor: .chatHistory),

        TutorialStep(
            id: "profile",
            icon: "person.crop.circle",
            title: "You, and What They Remember",
            body:
                "Your profile sits at the top of that sidebar: photo, name, gender and birthday. Your companion reads it, so they know who they're talking to — and they'll remember your birthday.",
            tip:
                "\"Memory & Facts\" in there lists everything they've picked up about you, oldest to newest. Anything you'd rather they forget can be deleted.",
            anchor: .chatHistory),

        TutorialStep(
            id: "menu",
            icon: "square.grid.2x2",
            title: "The Menu",
            body:
                "Everything else hides behind this grid. Tap it to fan the action buttons out, and tap the ✕ to put them away.",
            anchor: .menuToggle),

        TutorialStep(
            id: "settings",
            icon: "gear",
            title: "Settings",
            body:
                "Choose the AI brain, write the persona and pick its voice, and decide how autonomous your companion is allowed to be.",
            anchor: .fabSettings,
            menu: .primary),

        TutorialStep(
            id: "relationship",
            icon: "suit.heart.fill",
            title: "Acquaintances",
            body:
                "Your bond meter. It grows the more you talk. Tap the meter itself to open your companion's journal — their private notes about you.",
            anchor: .fabRelationship,
            menu: .primary),

        TutorialStep(
            id: "chevron",
            icon: "chevron.down",
            title: "More Tools",
            body: "The chevron unfolds a second row of buttons, and labels everything.",
            anchor: .fabChevron,
            menu: .primary),

        TutorialStep(
            id: "models",
            icon: "person.crop.square.on.square.angled",
            title: "Characters",
            body:
                "Swap companions, or import your own .vrm avatar. Each character keeps its own persona, voice and memories.",
            tip: "Long-press a character in the picker to delete it — chat history survives.",
            anchor: .fabModels,
            menu: .secondary),

        TutorialStep(
            id: "camera",
            icon: "video.doorbell.fill",
            title: "Eyes",
            body:
                "Opens the camera so your companion can see what you're showing them, and talk about it. Tap again to close the eye.",
            anchor: .fabCamera,
            menu: .secondary),

        TutorialStep(
            id: "photo",
            icon: "photo.on.rectangle",
            title: "Show a Photo",
            body:
                "Pick a picture from your library to show your companion. They'll react to it — and remember it, with the date it was taken.",
            tip: "Say who or where it is while you pick (\"this is my sister at the lake\") and that goes into the memory too.",
            anchor: .fabPhoto,
            menu: .secondary),

        TutorialStep(
            id: "song",
            icon: "music.note",
            title: "Identify Song",
            body:
                "Tap to name the track playing around you; the result appears as a capsule at the top.",
            tip:
                "Long-press instead to start a co-listening session — your companion keeps listening and reacts to each new song.",
            anchor: .fabSong,
            menu: .secondary),

        TutorialStep(
            id: "pip",
            icon: "pip.fill",
            title: "Picture in Picture",
            body:
                "Pops your companion into a floating window so they stay with you while you use other apps.",
            anchor: .fabPiP,
            menu: .secondary),

        TutorialStep(
            id: "phone",
            icon: "iphone",
            title: "The Companion's Phone",
            body:
                "When your companion looks something up — a web search, a song, a note, the weather — a little phone slides in from the bottom-left. Tap it to open the result.",
            tip: "Drag the phone anywhere you like; it stays parked there. ✕ puts it away."),

        TutorialStep(
            id: "done",
            icon: "checkmark.seal.fill",
            title: "You're Ready",
            body: "That's the whole cockpit. Say hello — they've been waiting.",
            tip: "Replay this tour any time from Settings › Help › Replay Tutorial.")
    ]
}
