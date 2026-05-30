//
//  Camera+ManualControls.swift
//
//
//  Created by Dan Murfin on 2026/05/17.
//

import Foundation
import AVFoundation

#if os(iOS)

@available(iOS 10.0, *)
@available(tvOS, unavailable)
@available(macOS, unavailable)
@available(macCatalyst, unavailable)
extension Camera {

    // MARK: - Focus

    /// Set the focus mode (e.g. `.locked`, `.autoFocus`, `.continuousAutoFocus`).
    /// Throws `Camera.ManualControlError.modeNotSupported` if the device does not support the requested mode.
    public func setFocusMode(_ mode: AVCaptureDevice.FocusMode) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isFocusModeSupported(mode) else { throw ManualControlError.modeNotSupported }
        try device.lockForConfiguration()
        device.focusMode = mode
        device.unlockForConfiguration()
    }

    /// Manually set the focus by lens position. `position` is normalized: `0.0` is the shortest focal distance
    /// (near) and `1.0` is the longest (far). iOS does not expose the real-world distance these values map to.
    /// The value is clamped to `[0.0, 1.0]`. Switches the device to `.locked` focus mode.
    public func setLensPosition(_ position: Float, completion: ((CMTime) -> Void)? = nil) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isFocusModeSupported(.locked) else { throw ManualControlError.modeNotSupported }
        let clamped = simd_clamp(position, 0.0, 1.0)
        try device.lockForConfiguration()
        device.setFocusModeLocked(lensPosition: clamped, completionHandler: completion)
        device.unlockForConfiguration()
    }

    // MARK: - Exposure

    /// Set the exposure mode (e.g. `.locked`, `.autoExpose`, `.continuousAutoExposure`, `.custom`).
    /// Throws `Camera.ManualControlError.modeNotSupported` if the device does not support the requested mode.
    public func setExposureMode(_ mode: AVCaptureDevice.ExposureMode) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isExposureModeSupported(mode) else { throw ManualControlError.modeNotSupported }
        try device.lockForConfiguration()
        device.exposureMode = mode
        device.unlockForConfiguration()
    }

    /// Set both shutter speed (exposure duration) and ISO at once using `.custom` exposure mode.
    /// `duration` is clamped to the device's supported range; `iso` is clamped to `[minISO, maxISO]`.
    public func setCustomExposure(duration: CMTime, iso: Float, completion: ((CMTime) -> Void)? = nil) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isExposureModeSupported(.custom) else { throw ManualControlError.modeNotSupported }
        let clampedDuration = clampExposureDuration(duration, device: device)
        let clampedISO = simd_clamp(iso, device.activeFormat.minISO, device.activeFormat.maxISO)
        try device.lockForConfiguration()
        device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO, completionHandler: completion)
        device.unlockForConfiguration()
    }

    /// Set the shutter speed (exposure duration), keeping the current ISO. Switches the device to `.custom` exposure mode.
    public func setExposureDuration(_ duration: CMTime, completion: ((CMTime) -> Void)? = nil) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isExposureModeSupported(.custom) else { throw ManualControlError.modeNotSupported }
        let clampedDuration = clampExposureDuration(duration, device: device)
        try device.lockForConfiguration()
        device.setExposureModeCustom(duration: clampedDuration, iso: AVCaptureDevice.currentISO, completionHandler: completion)
        device.unlockForConfiguration()
    }

    /// Set the ISO, keeping the current exposure duration. Switches the device to `.custom` exposure mode.
    public func setISO(_ iso: Float, completion: ((CMTime) -> Void)? = nil) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isExposureModeSupported(.custom) else { throw ManualControlError.modeNotSupported }
        let clampedISO = simd_clamp(iso, device.activeFormat.minISO, device.activeFormat.maxISO)
        try device.lockForConfiguration()
        device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: clampedISO, completionHandler: completion)
        device.unlockForConfiguration()
    }

    // MARK: - White Balance

    /// Set the white balance mode (e.g. `.locked`, `.autoWhiteBalance`, `.continuousAutoWhiteBalance`).
    /// Throws `Camera.ManualControlError.modeNotSupported` if the device does not support the requested mode.
    public func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isWhiteBalanceModeSupported(mode) else { throw ManualControlError.modeNotSupported }
        try device.lockForConfiguration()
        device.whiteBalanceMode = mode
        device.unlockForConfiguration()
    }

    /// Set the white balance using temperature (Kelvin) and tint. Locks the device's white balance.
    /// Gains derived from the temperature/tint pair are clamped to the device's supported range.
    public func setWhiteBalance(temperature: Float, tint: Float, completion: ((CMTime) -> Void)? = nil) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { throw ManualControlError.modeNotSupported }
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
        let gains = clampWhiteBalanceGains(device.deviceWhiteBalanceGains(for: values), device: device)
        try device.lockForConfiguration()
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: completion)
        device.unlockForConfiguration()
    }

    /// Set the white balance using raw RGB gains. Each channel gain is clamped to `[1.0, maxWhiteBalanceGain]`.
    public func setWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains, completion: ((CMTime) -> Void)? = nil) throws {
        guard let device = self.videoDevice else { throw ManualControlError.noVideoDevice }
        guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { throw ManualControlError.modeNotSupported }
        let clamped = clampWhiteBalanceGains(gains, device: device)
        try device.lockForConfiguration()
        device.setWhiteBalanceModeLocked(with: clamped, completionHandler: completion)
        device.unlockForConfiguration()
    }

    // MARK: - Current Values

    /// The current focus mode of the active video device, or `nil` if no video device is configured.
    public var currentFocusMode: AVCaptureDevice.FocusMode? {
        return self.videoDevice?.focusMode
    }

    /// The current lens position (`0.0`…`1.0`), or `nil` if no video device is configured.
    /// Note: this reflects the current actual lens position, which may still be settling toward a requested value.
    public var currentLensPosition: Float? {
        return self.videoDevice?.lensPosition
    }

    /// The current exposure mode of the active video device, or `nil` if no video device is configured.
    public var currentExposureMode: AVCaptureDevice.ExposureMode? {
        return self.videoDevice?.exposureMode
    }

    /// The current exposure duration (shutter), or `nil` if no video device is configured.
    public var currentExposureDuration: CMTime? {
        return self.videoDevice?.exposureDuration
    }

    /// The current ISO, or `nil` if no video device is configured.
    public var currentISO: Float? {
        return self.videoDevice?.iso
    }

    /// The current exposure target bias (EV), or `nil` if no video device is configured.
    public var currentExposureTargetBias: Float? {
        return self.videoDevice?.exposureTargetBias
    }
    
    /// The current exposure target offset (EV), or `nil` if no video device is configured.
    public var currentExposureTargetOffset: Float? {
        videoDevice?.exposureTargetOffset
    }

    /// The current white balance mode, or `nil` if no video device is configured.
    public var currentWhiteBalanceMode: AVCaptureDevice.WhiteBalanceMode? {
        return self.videoDevice?.whiteBalanceMode
    }

    /// The current device white balance gains, or `nil` if no video device is configured.
    public var currentWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains? {
        return self.videoDevice?.deviceWhiteBalanceGains
    }

    /// The current white balance as temperature (Kelvin) and tint, or `nil` if no video device is configured.
    public var currentWhiteBalanceTemperatureAndTint: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues? {
        guard let device = self.videoDevice else { return nil }
        let gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        // the system may briefly report sub-unity gains during capture session
        // startup or immediately after a white-balance mode change
        guard (1...maxGain).contains(gains.redGain),
              (1...maxGain).contains(gains.greenGain),
              (1...maxGain).contains(gains.blueGain) else {
            return nil
        }
        return device.temperatureAndTintValues(for: gains)
    }

    // MARK: - Supported Ranges

    /// The supported lens position range. Always `0.0`…`1.0` when a device is present, otherwise `nil`.
    public var supportedLensPositionRange: ClosedRange<Float>? {
        return self.videoDevice == nil ? nil : 0.0...1.0
    }

    /// The supported exposure duration (shutter) range for the active format, or `nil` if no video device is configured.
    public var supportedExposureDurationRange: (min: CMTime, max: CMTime)? {
        guard let format = self.videoDevice?.activeFormat else { return nil }
        return (format.minExposureDuration, format.maxExposureDuration)
    }

    /// The supported ISO range for the active format, or `nil` if no video device is configured.
    public var supportedISORange: ClosedRange<Float>? {
        guard let format = self.videoDevice?.activeFormat else { return nil }
        return format.minISO...format.maxISO
    }

    /// The supported exposure target bias (EV) range, or `nil` if no video device is configured.
    public var supportedExposureTargetBiasRange: ClosedRange<Float>? {
        guard let device = self.videoDevice else { return nil }
        return device.minExposureTargetBias...device.maxExposureTargetBias
    }

    /// The maximum supported white balance gain per channel (minimum is always `1.0`), or `nil` if no video device is configured.
    public var supportedWhiteBalanceGainRange: ClosedRange<Float>? {
        guard let device = self.videoDevice else { return nil }
        return 1.0...device.maxWhiteBalanceGain
    }

    // MARK: - Capability Queries

    public func isFocusModeSupported(_ mode: AVCaptureDevice.FocusMode) -> Bool {
        return self.videoDevice?.isFocusModeSupported(mode) ?? false
    }

    public func isExposureModeSupported(_ mode: AVCaptureDevice.ExposureMode) -> Bool {
        return self.videoDevice?.isExposureModeSupported(mode) ?? false
    }

    public func isWhiteBalanceModeSupported(_ mode: AVCaptureDevice.WhiteBalanceMode) -> Bool {
        return self.videoDevice?.isWhiteBalanceModeSupported(mode) ?? false
    }

    /// Whether the device supports locking white balance using arbitrary device gains (required for `setWhiteBalance(temperature:tint:)` and `setWhiteBalanceGains(_:)`).
    public var isLockingWhiteBalanceWithCustomGainsSupported: Bool {
        return self.videoDevice?.isLockingWhiteBalanceWithCustomDeviceGainsSupported ?? false
    }

    // MARK: - Errors

    public enum ManualControlError: Swift.Error {
        case noVideoDevice
        case modeNotSupported
    }

    // MARK: - Helpers

    private func clampExposureDuration(_ duration: CMTime, device: AVCaptureDevice) -> CMTime {
        let format = device.activeFormat
        if CMTimeCompare(duration, format.minExposureDuration) < 0 {
            return format.minExposureDuration
        }
        if CMTimeCompare(duration, format.maxExposureDuration) > 0 {
            return format.maxExposureDuration
        }
        return duration
    }

    private func clampWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        var clamped = gains
        clamped.redGain = simd_clamp(clamped.redGain, 1.0, maxGain)
        clamped.greenGain = simd_clamp(clamped.greenGain, 1.0, maxGain)
        clamped.blueGain = simd_clamp(clamped.blueGain, 1.0, maxGain)
        return clamped
    }
}

#endif
