// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

#if canImport(Speech)
    import AVFoundation
    import Speech

    /// The one call the microphone tap makes on a speech request: hand it the
    /// next buffer of sound. The tap runs on the audio thread, so the request
    /// has to cross to it.
    ///
    /// PROMISE: Apple documents `append(_:)` on an audio-buffer recognition
    /// request as the call to make from the audio tap while the recognizer
    /// reads the same request elsewhere. Only `append` is reachable through
    /// this type; ending the audio and cancelling stay with the owner, on the
    /// main actor.
    struct SpeechAudioFeed: @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest

        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    }
#endif
