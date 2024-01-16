//
//  CameraView+RecordVideo.swift
//  mrousavy
//
//  Created by Marc Rousavy on 16.12.20.
//  Copyright © 2020 mrousavy. All rights reserved.
//

struct TorchControl {
    var torchDuration: Double
    var torchDelay: Double
}

struct RecordingTimestamps {
    var actualRecordingStartedAt: Double?
    var actualTorchOnAt: Double?
    var actualTorchOffAt: Double?
    var actualRecordingEndedAt: Double?
    var requestTorchOnAt: Double?
    var requestTorchOffAt: Double?
    var actualBackgroundTorchOnAt: Double?
    var actualBackgroundTorchOffAt: Double?
    var requestBackgroundTorchOnAt: Double?
    var requestBackgroundTorchOffAt: Double?
}

import AVFoundation


// MARK: - CameraView + AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraView: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
  /**
   Starts a video + audio recording with a custom Asset Writer.
   */
  func startRecording(options: NSDictionary, callback jsCallbackFunc: @escaping RCTResponseSenderBlock) {
    cameraQueue.async {
      ReactLogger.log(level: .info, message: "Starting Video recording...")
      let callback = Callback(jsCallbackFunc)

      var fileType = AVFileType.mov
      if let fileTypeOption = options["fileType"] as? String {
        guard let parsed = try? AVFileType(withString: fileTypeOption) else {
          callback.reject(error: .parameter(.invalid(unionName: "fileType", receivedValue: fileTypeOption)))
          return
        }
        fileType = parsed
      }

      let errorPointer = ErrorPointer(nilLiteral: ())
      let fileExtension = fileType.descriptor ?? "mov"
      guard let tempFilePath = RCTTempFilePath(fileExtension, errorPointer) else {
        callback.reject(error: .capture(.createTempFileError), cause: errorPointer?.pointee)
        return
      }

      ReactLogger.log(level: .info, message: "File path: \(tempFilePath)")
      let tempURL = URL(string: "file://\(tempFilePath)")!

      if let flashMode = options["flash"] as? String {
        // use the torch as the video's flash
        self.setTorchMode(flashMode)
      }

      guard let videoOutput = self.videoOutput else {
        if self.video?.boolValue == true {
          callback.reject(error: .session(.cameraNotReady))
          return
        } else {
          callback.reject(error: .capture(.videoNotEnabled))
          return
        }
      }
      guard let videoInput = self.videoDeviceInput else {
        callback.reject(error: .session(.cameraNotReady))
        return
      }

      // TODO: The startRecording() func cannot be async because RN doesn't allow
      //       both a callback and a Promise in a single function. Wait for TurboModules?
      //       This means that any errors that occur in this function have to be delegated through
      //       the callback, but I'd prefer for them to throw for the original function instead.

      let enableAudio = self.audio?.boolValue == true

      let onFinish = { (recordingSession: RecordingSession, status: AVAssetWriter.Status, error: Error?) in
        defer {
          if enableAudio {
            self.audioQueue.async {
              self.deactivateAudioSession()
            }
          }
          if options["flash"] != nil {
            // Set torch mode back to what it was before if we used it for the video flash.
            self.setTorchMode(self.torch)
          }
        }

        self.recordingSession = nil
        self.isRecording = false
        ReactLogger.log(level: .info, message: "RecordingSession finished with status \(status.descriptor).")

        if let error = error as NSError? {
          if error.domain == "capture/aborted" {
            callback.reject(error: .capture(.aborted), cause: error)
          } else {
            callback.reject(error: .capture(.unknown(message: "An unknown recording error occured! \(error.description)")), cause: error)
          }
        } else {
          if status == .completed {
              let metadata = [
                "actualRecordingStartedAt": self.recordingTimestamps.actualRecordingStartedAt,
                "actualTorchOnAt": self.recordingTimestamps.actualTorchOnAt,
                "actualTorchOffAt": self.recordingTimestamps.actualTorchOffAt,
                "actualRecordingEndedAt": self.recordingTimestamps.actualRecordingEndedAt,
                "requestTorchOnAt": self.recordingTimestamps.requestTorchOnAt,
                "requestTorchOffAt": self.recordingTimestamps.requestTorchOffAt,
                "requestBackgroundTorchOnAt": self.recordingTimestamps.requestBackgroundTorchOnAt,
                "requestBackgroundTorchOffAt": self.recordingTimestamps.requestBackgroundTorchOffAt,
                "actualBackgroundTorchOnAt": self.recordingTimestamps.actualBackgroundTorchOnAt,
                "actualBackgroundTorchOffAt": self.recordingTimestamps.actualBackgroundTorchOffAt,
              ]
              
            print("recordingTimestamps \(self.recordingTimestamps)")
            callback.resolve([
              "path": recordingSession.url.absoluteString,
              "duration": recordingSession.duration,
              "metadata": metadata,
            ])
          } else {
            callback.reject(error: .unknown(message: "AVAssetWriter completed with status: \(status.descriptor)"))
          }
        }
      }

      let recordingSession: RecordingSession
      do {
        recordingSession = try RecordingSession(url: tempURL,
                                                fileType: fileType,
                                                completion: onFinish)
      } catch let error as NSError {
        callback.reject(error: .capture(.createRecorderError(message: nil)), cause: error)
        return
      }
      self.recordingSession = recordingSession

      var videoCodec: AVVideoCodecType?
      if let codecString = options["videoCodec"] as? String {
        videoCodec = AVVideoCodecType(withString: codecString)
      }

      // Init Video
      guard let videoSettings = self.recommendedVideoSettings(videoOutput: videoOutput, fileType: fileType, videoCodec: videoCodec),
            !videoSettings.isEmpty else {
        callback.reject(error: .capture(.createRecorderError(message: "Failed to get video settings!")))
        return
      }

      // get pixel format (420f, 420v, x420)
      let pixelFormat = CMFormatDescriptionGetMediaSubType(videoInput.device.activeFormat.formatDescription)
      recordingSession.initializeVideoWriter(withSettings: videoSettings,
                                             pixelFormat: pixelFormat)

      // Init Audio (optional, async)
      if enableAudio {
        // Activate Audio Session (blocking)
        self.activateAudioSession()

        if let audioOutput = self.audioOutput,
           let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: fileType) {
          recordingSession.initializeAudioWriter(withSettings: audioSettings)
        }
      }

      // start recording session with or without audio.
      do {
        try recordingSession.start()
      } catch let error as NSError {
        callback.reject(error: .capture(.createRecorderError(message: "RecordingSession failed to start writing.")), cause: error)
        return
      }
      self.isRecording = true
        let recordingStartTimestamp = NSDate().timeIntervalSince1970
        ReactLogger.log(level: .info, message: "recordingStartTimestamp:  \(recordingStartTimestamp)")
        self.recordingTimestamps.actualRecordingStartedAt = NSDate().timeIntervalSince1970
        
        print("torchDelay:", self.torchDelay)
        print("torchDuration:", self.torchDuration)
        var torchDelay = DispatchTimeInterval.milliseconds(Int(self.torchDelay))
        var torchEnd = DispatchTimeInterval.milliseconds(Int(self.torchDelay) + Int(self.torchDuration))
        
        var backgroundDelay = DispatchTimeInterval.milliseconds(Int(self.backgroundDelay))
        var backgroundTorchEnd = DispatchTimeInterval.milliseconds(Int(self.backgroundDelay) + Int(self.backgroundDuration))
        
        if let backgroundLevelValue = self.backgroundLevel as? Double {
            if backgroundLevelValue > 0.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + backgroundDelay) {
                    self.recordingTimestamps.requestBackgroundTorchOnAt = NSDate().timeIntervalSince1970
                    self.setBackgroundLight(self.backgroundLevel, torchMode:"on")
                    self.recordingTimestamps.actualBackgroundTorchOnAt = NSDate().timeIntervalSince1970
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + backgroundTorchEnd) {
                    self.recordingTimestamps.requestBackgroundTorchOffAt = NSDate().timeIntervalSince1970
                    self.setTorchMode("off")
                    self.recordingTimestamps.actualBackgroundTorchOffAt = NSDate().timeIntervalSince1970
                }
            }
        }
        
        if Int(self.torchDuration) > 0 {
             DispatchQueue.main.asyncAfter(deadline: .now() + torchDelay) {
                 self.recordingTimestamps.requestTorchOnAt = NSDate().timeIntervalSince1970
                 self.setTorchMode("off")
                 self.setTorchMode("on")
                 self.recordingTimestamps.actualTorchOnAt = NSDate().timeIntervalSince1970
             }
             
             DispatchQueue.main.asyncAfter(deadline: .now() + torchEnd) {
                 self.recordingTimestamps.requestTorchOffAt = NSDate().timeIntervalSince1970
                 self.setTorchMode("off")
                 if let backgroundLevelValue = self.backgroundLevel as? Double {
                     if backgroundLevelValue > 0.0 {
                         self.setBackgroundLight(self.backgroundLevel, torchMode:"on")
                     }
                 }
                 self.recordingTimestamps.actualTorchOffAt = NSDate().timeIntervalSince1970
             }
        }
    }
  }

  func stopRecording(promise: Promise) {
    cameraQueue.async {
      self.isRecording = false

      withPromise(promise) {
        guard let recordingSession = self.recordingSession else {
          throw CameraError.capture(.noRecordingInProgress)
        }
        recordingSession.finish()
          let recordingStopTimestamp = NSDate().timeIntervalSince1970
          ReactLogger.log(level: .info, message: "recordingStopTimestamp:  \(recordingStopTimestamp)")
          self.recordingTimestamps.actualRecordingEndedAt = NSDate().timeIntervalSince1970
        return nil
      }
    }
  }

  func pauseRecording(promise: Promise) {
    cameraQueue.async {
      withPromise(promise) {
        guard self.recordingSession != nil else {
          // there's no active recording!
          throw CameraError.capture(.noRecordingInProgress)
        }
        self.isRecording = false
          let recordingStopTimestamp = NSDate().timeIntervalSince1970
          ReactLogger.log(level: .info, message: "recordingStopTimestamp:  \(recordingStopTimestamp)")
        return nil
      }
    }
  }

  func resumeRecording(promise: Promise) {
    cameraQueue.async {
      withPromise(promise) {
        guard self.recordingSession != nil else {
          // there's no active recording!
          throw CameraError.capture(.noRecordingInProgress)
        }
        self.isRecording = true
        return nil
      }
    }
  }

  public final func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
    // Video Recording runs in the same queue
    if isRecording {
      guard let recordingSession = recordingSession else {
        invokeOnError(.capture(.unknown(message: "isRecording was true but the RecordingSession was null!")))
        return
      }

      switch captureOutput {
      case is AVCaptureVideoDataOutput:
        recordingSession.appendBuffer(sampleBuffer, type: .video, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      case is AVCaptureAudioDataOutput:
        let timestamp = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                          from: audioCaptureSession.masterClock!,
                                          to: captureSession.masterClock!)
        recordingSession.appendBuffer(sampleBuffer, type: .audio, timestamp: timestamp)
      default:
        break
      }
    }

    if let frameProcessor = frameProcessorCallback, captureOutput is AVCaptureVideoDataOutput {
      // check if last frame was x nanoseconds ago, effectively throttling FPS
      let lastFrameProcessorCallElapsedTime = DispatchTime.now().uptimeNanoseconds - lastFrameProcessorCall.uptimeNanoseconds
      let secondsPerFrame = 1.0 / actualFrameProcessorFps
      let nanosecondsPerFrame = secondsPerFrame * 1_000_000_000.0

      if lastFrameProcessorCallElapsedTime > UInt64(nanosecondsPerFrame) {
        if !isRunningFrameProcessor {
          // we're not in the middle of executing the Frame Processor, so prepare for next call.
          CameraQueues.frameProcessorQueue.async {
            self.isRunningFrameProcessor = true

            let perfSample = self.frameProcessorPerformanceDataCollector.beginPerformanceSampleCollection()
            let frame = Frame(buffer: sampleBuffer, orientation: self.bufferOrientation)
            frameProcessor(frame)
            perfSample.endPerformanceSampleCollection()

            self.isRunningFrameProcessor = false
          }
          lastFrameProcessorCall = DispatchTime.now()
        } else {
          // we're still in the middle of executing a Frame Processor for a previous frame, so a frame was dropped.
          ReactLogger.log(level: .warning, message: "The Frame Processor took so long to execute that a frame was dropped.")
        }
      }

      if isReadyForNewEvaluation {
        // last evaluation was more than 1sec ago, evaluate again
        evaluateNewPerformanceSamples()
      }
    }
  }

  private func evaluateNewPerformanceSamples() {
    lastFrameProcessorPerformanceEvaluation = DispatchTime.now()
    guard let videoDevice = videoDeviceInput?.device else { return }
    guard frameProcessorPerformanceDataCollector.hasEnoughData else { return }

    let maxFrameProcessorFps = Double(videoDevice.activeVideoMinFrameDuration.timescale) * Double(videoDevice.activeVideoMinFrameDuration.value)
    let averageFps = 1.0 / frameProcessorPerformanceDataCollector.averageExecutionTimeSeconds
    let suggestedFrameProcessorFps = max(floor(min(averageFps, maxFrameProcessorFps)), 1)

    if frameProcessorFps.intValue == -1 {
      // frameProcessorFps="auto"
      actualFrameProcessorFps = suggestedFrameProcessorFps
    } else {
      // frameProcessorFps={someCustomFpsValue}
      invokeOnFrameProcessorPerformanceSuggestionAvailable(currentFps: frameProcessorFps.doubleValue,
                                                           suggestedFps: suggestedFrameProcessorFps)
    }
  }

  private func recommendedVideoSettings(videoOutput: AVCaptureVideoDataOutput, fileType: AVFileType, videoCodec: AVVideoCodecType?) -> [String: Any]? {
    if videoCodec != nil {
      return videoOutput.recommendedVideoSettings(forVideoCodecType: videoCodec!, assetWriterOutputFileType: fileType)
    } else {
      return videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: fileType)
    }
  }

  private var isReadyForNewEvaluation: Bool {
    let lastPerformanceEvaluationElapsedTime = DispatchTime.now().uptimeNanoseconds - lastFrameProcessorPerformanceEvaluation.uptimeNanoseconds
    return lastPerformanceEvaluationElapsedTime > 1_000_000_000
  }

  /**
   Gets the orientation of the CameraView's images (CMSampleBuffers).
   */
  var bufferOrientation: UIImage.Orientation {
    guard let cameraPosition = videoDeviceInput?.device.position else {
      return .up
    }

    switch UIDevice.current.orientation {
    case .portrait:
      return cameraPosition == .front ? .leftMirrored : .right

    case .landscapeLeft:
      return cameraPosition == .front ? .downMirrored : .up

    case .portraitUpsideDown:
      return cameraPosition == .front ? .rightMirrored : .left

    case .landscapeRight:
      return cameraPosition == .front ? .upMirrored : .down

    case .unknown, .faceUp, .faceDown:
      fallthrough
    @unknown default:
      return .up
    }
  }
}
