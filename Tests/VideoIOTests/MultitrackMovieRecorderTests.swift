import XCTest
@testable import VideoIO
import AVFoundation

@available(iOS 10.0, tvOS 10.0, macOS 10.13, *)
final class MultitrackMovieRecorderTests: XCTestCase {

    private static let frameDuration = CMTime(value: 1, timescale: 30)

    // capture timestamps are host time, far from zero
    private static let startTime = CMTime(value: 3000, timescale: 30)

    private var temporaryDirectory: URL!

    private var movieURL: URL {
        temporaryDirectory.appendingPathComponent("movie.mov")
    }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MultitrackMovieRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeRecorder(numberOfAudioTracks: Int = 0) throws -> MultitrackMovieRecorder {
        let configuration = MultitrackMovieRecorder.Configuration(numberOfVideoTracks: 1, numberOfAudioTracks: numberOfAudioTracks, shouldOptimizeForNetworkUse: false)
        return try MultitrackMovieRecorder(url: movieURL, configuration: configuration)
    }

    private func makeVideoSampleBuffer(at presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, [:] as CFDictionary, &pixelBuffer)
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(pixelBuffer), formatDescriptionOut: &formatDescription)
        var timingInfo = CMSampleTimingInfo(duration: Self.frameDuration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(pixelBuffer), formatDescription: try XCTUnwrap(formatDescription), sampleTiming: &timingInfo, sampleBufferOut: &sampleBuffer)
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeAudioSampleBuffer(at presentationTime: CMTime) throws -> CMSampleBuffer {
        let frames = 1600
        var streamDescription = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        let length = frames * Int(streamDescription.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: try XCTUnwrap(blockBuffer), offsetIntoDestination: 0, dataLength: length)
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: try XCTUnwrap(blockBuffer), formatDescription: try XCTUnwrap(formatDescription), sampleCount: frames, presentationTimeStamp: presentationTime, packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        return try XCTUnwrap(sampleBuffer)
    }

    private func stop(_ recorder: MultitrackMovieRecorder) -> Error? {
        let stopped = expectation(description: "stopped")
        var stopError: Error?
        recorder.stopRecording { error in
            stopError = error
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 10)
        return stopError
    }

    private func assertRejected(_ expected: MultitrackMovieRecorder.BufferAppendingError, file: StaticString = #filePath, line: UInt = #line, _ append: () throws -> Void) {
        XCTAssertThrowsError(try append(), file: file, line: line) { error in
            XCTAssertEqual(error as? MultitrackMovieRecorder.BufferAppendingError, expected, file: file, line: line)
        }
    }

    func testNonIncreasingVideoTimestampsAreRejectedWithoutFailingTheRecording() throws {
        let recorder = try makeRecorder()
        let failed = expectation(description: "failure handler")
        failed.isInverted = true
        recorder.failureHandler = { _ in failed.fulfill() }

        // appends are paced because the writer inputs expect real-time media
        var lastTime = Self.startTime
        for frame in 0..<60 {
            lastTime = Self.startTime + CMTimeMultiply(Self.frameDuration, multiplier: Int32(frame))
            try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: lastTime)])
            if frame == 30 {
                // a repeated frame, an earlier frame, and a frame stamped zero as delivered after a capture session restart
                assertRejected(.nonIncreasingPresentationTimeStamp) { try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: lastTime)]) }
                assertRejected(.nonIncreasingPresentationTimeStamp) { try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: lastTime - Self.frameDuration)]) }
                assertRejected(.nonIncreasingPresentationTimeStamp) { try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: .zero)]) }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertNil(stop(recorder))
        XCTAssertEqual(recorder.duration.seconds, (lastTime - Self.startTime).seconds, accuracy: 0.1)
        wait(for: [failed], timeout: 0.5)
    }

    func testInvalidVideoTimestampIsRejected() throws {
        let recorder = try makeRecorder()
        assertRejected(.invalidPresentationTimeStamp) { try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: .invalid)]) }
        // an invalid timestamp is not accepted as the latest, so a later valid one still is
        XCTAssertNoThrow(try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: Self.startTime)]))
        _ = stop(recorder)
    }

    func testRepeatedAudioTimestampIsRejected() throws {
        let recorder = try makeRecorder(numberOfAudioTracks: 1)
        try recorder.appendAudioSampleBuffers([makeAudioSampleBuffer(at: Self.startTime)])
        assertRejected(.nonIncreasingPresentationTimeStamp) { try recorder.appendAudioSampleBuffers([makeAudioSampleBuffer(at: Self.startTime)]) }
        // audio and video timestamps are checked independently
        XCTAssertNoThrow(try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: Self.startTime)]))
        _ = stop(recorder)
    }

    func testFailureHandlerIsCalledOnceOnTheMainQueueWhenWritingFails() throws {
        let recorder = try makeRecorder()
        // the writer cannot create its file once the folder is gone, so it fails to start writing
        try FileManager.default.removeItem(at: temporaryDirectory)

        let failed = expectation(description: "failure handler")
        var handledErrors: [Error] = []
        recorder.failureHandler = { error in
            XCTAssertTrue(Thread.isMainThread)
            handledErrors.append(error)
            failed.fulfill()
        }

        // buffers enqueued before the failure is recorded must not report it again
        try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: Self.startTime)])
        try? recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: Self.startTime + Self.frameDuration)])
        wait(for: [failed], timeout: 5)

        XCTAssertThrowsError(try recorder.appendVideoSampleBuffers([makeVideoSampleBuffer(at: Self.startTime + CMTimeMultiply(Self.frameDuration, multiplier: 2))]))

        let stopError = stop(recorder)
        XCTAssertEqual(handledErrors.count, 1)
        XCTAssertNotNil(stopError)
        XCTAssertEqual(stopError as NSError?, handledErrors.first as NSError?)
    }

    func testMovieRecorderForwardsFailureHandler() throws {
        let recorder = try MovieRecorder(url: movieURL, configuration: MovieRecorder.Configuration(hasAudio: false, shouldOptimizeForNetworkUse: false))
        try FileManager.default.removeItem(at: temporaryDirectory)

        let failed = expectation(description: "failure handler")
        recorder.failureHandler = { _ in failed.fulfill() }
        try recorder.appendSampleBuffer(makeVideoSampleBuffer(at: Self.startTime))
        wait(for: [failed], timeout: 5)

        let stopped = expectation(description: "stopped")
        recorder.stopRecording { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 10)
    }
}
