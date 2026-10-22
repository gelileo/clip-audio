Here is a high-level Product Requirement Document (PRD) and Technical Design Specification for a client-side iOS application named **"ClipAudio"** (or a custom moniker) designed to fulfill your requirement safely, keeping all processing locally on the user's phone.

---

# Product Requirement Document (PRD): ClipAudio (iOS Link-to-Audio Player)

## 1. Executive Summary

**ClipAudio** is a lightweight, client-side iOS utility application that allows users to copy a media link (YouTube, SoundCloud, etc.), paste it into a clean UI, extract the direct audio stream locally on-device using embedded Python/extraction routing, and stream the audio instantly using native iOS audio playback mechanisms.

The architecture guarantees **zero central backend liability**, as no servers store, process, or proxy media files.

## 2. Core Objectives

* **Frictionless Link-to-Audio:** Allow rapid paste-and-play workflows for media links.
* **On-Device Sovereignty:** Perform extraction parsing directly on the user’s device hardware.
* **Native Audio Experience:** Deliver background playback, lock-screen controls, and system audio routing (AirPlay/Headphones).
* **Zero-Liability Distribution:** Maintain clear open-source/sideloading parameters, making it clear that extraction happens entirely locally via the client.

## 3. User Stories & Functional Requirements

* **US-01: Paste & Extract**
* As a user, I can paste a copied URL into a text field and tap "Play" to trigger stream resolution.

* **US-02: Instant Audio Streaming**
* As a user, once the link is parsed, audio streams immediately without forcing a full file download to disk.

* **US-03: Background Playball & Controls**
* As a user, I can lock my phone, use control center, or use headphones to pause/play/skip the active stream.

* **US-04: History / Queue Management**
* As a user, I can view recently played or pasted links during the current app session.

---

# Technical Design Specification

## 1. High-Level Architecture

```
+-------------------------------------------------------+
|                    iOS App (Swift)                    |
|                                                       |
|  +--------------------+     +----------------------+  |
|  |   SwiftUI Engine   | --> |  AVPlayer (Audio)    |  |
|  +--------------------+     +----------------------+  |
|            |                           ^              |
|            v (URL string)              | (Direct URL) |
|  +-------------------------------------+--------------+  |
|  |           Embedded Python / Extraction Layer       |  |
|  |      (Python-Apple-Support + yt-dlp logic)         |  |
|  +----------------------------------------------------+  |
+-------------------------------------------------------+

```

## 2. Component Stack

* **UI Layer:** SwiftUI (Single-view minimalistic design: Input text box, prominent "Play" action button, simple track status indicator/mini-player).
* **Extraction Layer:** Embedded CPython runtime for iOS (`Python-Apple-Support` / `PythonKit`) running an embedded extraction module or executing lightweight stream extraction scripts. *(Alternatively, leveraging a Swift-native parsing helper or local web-kit evaluation bindings matching modern signature extraction).*
* **Playback Layer:** Apple's **`AVPlayer`** and **`AVQueuePlayer`** wrapped in `AVAudioSession` configured for `AVAudioSession.Category.playback` (enabling background audio and lock screen MPRemoteCommandCenter controls).

## 3. Data Flow (Step-by-Step)

1. **Input:** User pastes a URL (e.g., `[https://youtube.com/watch?v=](https://youtube.com/watch?v=)...`) into the SwiftUI text field.
2. **Execution:** App calls the embedded Python/extraction bridge asynchronously, passing the target URL string.
3. **Extraction:** The local runtime queries the target source parameters to resolve the dynamic direct CDN stream URL (audio-only manifest link).
4. **Handoff:** The direct streaming URL string is returned to the Swift environment.
5. **Playback:** `AVPlayer` initializes with the direct CDN URL, and audio output starts seamlessly to the device speaker or active bluetooth output.

## 4. Edge Cases & Error Handling

* **Geo-restrictions / Broken Links:** If the extractor fails or returns a sign-in wall error, catch the exception cleanly and present a native user-friendly toast notification (*"Unable to extract stream from this URL"*).
* **Network Interruption:** Implement `AVPlayerItem` status observers to handle drops gracefully, notifying the user or attempting auto-reconnection.
* **App Lifecycle (Backgrounding):** Properly configure the Xcode project's *Background Modes* capability (`Audio, AirPlay, and Picture in Picture`) to prevent iOS from killing the extraction/playback task when the screen locks.

## 5. Deployment / Distribution Considerations

* Because tools dealing with on-the-fly media stream parsing often face strict automated review hurdles on public app storefronts (as highlighted by community packaging history), this application is ideally built for **personal side-loading** (via AltStore, Sideloadly, or direct Xcode compilation to your personal device), matching the workflow of power-user utilities like cliamp.
