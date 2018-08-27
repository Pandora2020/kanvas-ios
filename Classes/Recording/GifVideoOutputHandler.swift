//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Foundation
import UIKit
import AVFoundation

private struct GifHandlerConstants {
    static let Queue = "GifQueue"
}

/// A handler for recording videos in the gif (forwards then backwards) method
final class GifVideoOutputHandler: NSObject {

    // bool for whether the handler is currently in a recording state
    private(set) var recording = false

    private let gifQueue = DispatchQueue(label: GifHandlerConstants.Queue)

    private var currentVideoSampleBuffer: CMSampleBuffer?
    private var videoOutput: AVCaptureVideoDataOutput?

    private var gifLink: CADisplayLink?
    private var gifBuffers: [CMSampleBuffer] = []
    private var gifFrames: Int = 0
    private var gifCompletion: ((Bool) -> Void)?

    private var assetWriter: AVAssetWriter?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    required init(videoOutput: AVCaptureVideoDataOutput?) {
        self.videoOutput = videoOutput
    }

    // MARK: - external methods
    
    /// Starts capturing frames for creating a gif video
    ///
    /// - Parameters:
    ///   - assetWriter: The asset writer to append buffers to
    ///   - pixelBufferAdaptor: The pixel buffer adaptor that is attached to the asset writer
    ///   - videoInput: Video input for pixel buffer adaptor
    ///   - audioInput: Audio input for the asset writer. Is necessary since the asset writer setup is the same
    ///   - completion: returns a success boolean
    func takeGifMovie(assetWriter: AVAssetWriter?,
                      pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?,
                      videoInput: AVAssetWriterInput?,
                      audioInput: AVAssetWriterInput?,
                      completion: @escaping (Bool) -> Void) {

        guard !recording else {
            completion(false)
            return
        }

        self.assetWriter = assetWriter
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.videoInput = videoInput
        self.audioInput = audioInput

        gifFrames = 0
        gifCompletion = completion

        let link = CADisplayLink(target: self, selector: #selector(gifLoop))
        link.preferredFramesPerSecond = KanvasCameraTimes.GifPreferredFramesPerSecond
        link.add(to: RunLoop.main, forMode: RunLoopMode.defaultRunLoopMode)
        gifLink = link
    }

    /// Cancels the current frame loops and invalidates the display link
    func cancelGif() {
        invalidateLink()
        gifCompletion?(false)
        gifCompletion = nil
        recording = false
    }

    // MARK: - sample buffer processing

    /// Helper method for processing frames
    ///
    /// - Parameter sampleBuffer: the video CMSampleBuffer
    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        currentVideoSampleBuffer = sampleBuffer
    }

    // MARK: - private helper methods

     @objc private func gifLoop() {
        guard videoOutput != nil else {
            cancelGif()
            return
        }
        guard let buffer = currentVideoSampleBuffer else {
            // current video sample buffer may not be set yet, so don't necessarily cancelGif
            return
        }
        // we need to create a copy of the CMSampleBuffer, the other one will be automatically reused by the video data output
        var newBuffer: CMSampleBuffer? = nil
        CMSampleBufferCreateCopy(kCFAllocatorDefault, buffer, &newBuffer)
        if let buffer = newBuffer {
            gifBuffers.append(buffer)
            gifFrames += 1
            if gifFrames >= KanvasCameraTimes.GifTotalFrames {
                gifFinishedBursting()
            }
        }
    }

    private func gifFinishedBursting() {
        invalidateLink()

        var nextTime = CMTime(value: 0, timescale: KanvasCameraTimes.GifTimeScale)
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: nextTime)

        gifBuffers = sampleBuffersWithReverse(array: gifBuffers)
        for (index, buffer) in self.gifBuffers.enumerated() {
            let appendTime = nextTime
            nextTime = CMTimeAdd(nextTime, KanvasCameraTimes.GifFrameTime)
            gifQueue.async { [unowned self] in
                if let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
                    self.pixelBufferAdaptor?.append(buffer: pixelBuffer, time: appendTime, completion: { [unowned self] appended in
                        if index == self.gifBuffers.count - 1 {
                            self.exportGif(endTime: nextTime)
                        }
                    })
                }
            }
        }
    }

    private func sampleBuffersWithReverse(array: [CMSampleBuffer]) -> [CMSampleBuffer] {
        guard array.count > 1 else {
            NSLog("array needs to be at least two elements to reverse")
            return array
        }
        var newArray: [CMSampleBuffer] = array.map{ $0 }
        var reversedArray: [CMSampleBuffer] = []
        reversedArray.append(contentsOf: array.reversed())
        if reversedArray.count > 1 {
            reversedArray.removeFirst()
            reversedArray.removeLast()
        }

        newArray.append(contentsOf: reversedArray)

        return newArray
    }

    private func exportGif(endTime: CMTime) {
        assetWriter?.endSession(atSourceTime: endTime)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        gifQueue.async { [unowned self] in
            self.assetWriter?.finishWriting(completionHandler: {
                self.recording = false
                self.gifCompletion?(self.assetWriter?.status == .completed)
                self.gifCompletion = nil
                self.gifBuffers.removeAll()
            })
        }
    }

    private func invalidateLink() {
        gifLink?.invalidate()
        gifLink?.remove(from: RunLoop.main, forMode: RunLoopMode.defaultRunLoopMode)
        gifLink = nil
    }
}