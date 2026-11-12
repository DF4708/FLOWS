// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AVFoundation
import Foundation

#if canImport(Speech)
    import Speech
#endif

// AN UNSAFE ISLAND (see UnsafeIslands.swift).
//
// PROMISE: the box is retained once when the tap is made and released once,
// by the tap's finalize callback, or here when the tap could not be made.
// Between those two points the tap owns it, so the process callback may
// borrow it without retaining.

#if canImport(Speech)
    /// The audio tap that feeds decoded samples to the recognizer.
    ///
    /// Kept in its own type because MTAudioProcessingTap callbacks are C
    /// function pointers: they cannot capture Swift context, so the request is
    /// passed through the tap's storage as an unmanaged reference.
    enum ScannerAudioTap {
        private final class Box {
            let request: SFSpeechAudioBufferRecognitionRequest
            init(_ r: SFSpeechAudioBufferRecognitionRequest) { request = r }
        }

        static func attach(
            to params: AVMutableAudioMixInputParameters,
            request: SFSpeechAudioBufferRecognitionRequest
        ) {
            let box = unsafe Unmanaged.passRetained(Box(request)).toOpaque()
            var callbacks = unsafe MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: box,
                init: { _, clientInfo, storageOut in unsafe storageOut.pointee = unsafe clientInfo },
                finalize: { tap in
                    if let storage = unsafe MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? {
                        unsafe Unmanaged<Box>.fromOpaque(storage).release()
                    }
                },
                prepare: nil, unprepare: nil,
                process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                    let status = unsafe MTAudioProcessingTapGetSourceAudio(
                        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                    guard status == noErr else { return }
                    let storage = unsafe MTAudioProcessingTapGetStorage(tap)
                    let box = unsafe Unmanaged<Box>.fromOpaque(storage).takeUnretainedValue()
                    guard let format = ScannerAudioTap.format(frames: numberFrames),
                        let buffer = unsafe AVAudioPCMBuffer(
                            pcmFormat: format,
                            bufferListNoCopy: bufferListInOut)
                    else { return }
                    box.request.append(buffer)
                })
            // The current SDK imports the out-parameter as a managed optional,
            // so ARC balances the tap for us.
            var tap: MTAudioProcessingTap?
            let err = unsafe MTAudioProcessingTapCreate(
                kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard err == noErr, let created = tap else {
                unsafe Unmanaged<Box>.fromOpaque(box).release()
                return
            }
            params.audioTapProcessor = created
        }

        /// The tap delivers 32-bit float, non-interleaved, at the stream's rate;
        /// relay feeds are 22.05 kHz mono in practice.
        private static let sharedFormat =
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 22_050,
                channels: 1, interleaved: false)

        nonisolated static func format(frames: CMItemCount) -> AVAudioFormat? {
            sharedFormat
        }
    }
#endif
