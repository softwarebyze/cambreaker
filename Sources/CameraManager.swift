import AVFoundation
import Combine
import Foundation

/// Owns the AVCaptureSession that keeps Camera Control routed to this app,
/// and exposes a custom AVCaptureSlider whose swipe value drives the paddle.
@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var paddlePosition: Float = 0.5
    @Published var statusMessage: String = "Starting camera…"
    @Published var controlsActive: Bool = false
    @Published var supportsControls: Bool = false
    @Published var eventLog: [String] = []
    @Published var lastSliderEvent: Date = .distantPast
    @Published var cameraPosition: AVCaptureDevice.Position = .back

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.ebenfeld.cambreaker.session")
    private var paddleSlider: AVCaptureSlider?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: session)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: session)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session)
        requestAccessAndConfigure()
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? AVCaptureSession.InterruptionReason

        Task { @MainActor in
            self.appendLog("session INTERRUPTED (\(String(describing: reason)))")
            self.statusMessage = "Camera interrupted (\(String(describing: reason))) — reopen the app."
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {

        Task { @MainActor in
            self.appendLog("session interruption ended")
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? AVError

        Task { @MainActor in
            self.appendLog("session ERROR \(err?.localizedDescription ?? "?")")
        }
    }

    /// Swaps the session between front and back camera without dropping the
    /// Camera Control slider (it's app-defined, not tied to a device).
    func setCameraPosition(_ position: AVCaptureDevice.Position) {
        guard position != cameraPosition else { return }
        Task { @MainActor in self.cameraPosition = position }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                    ?? AVCaptureDevice.default(for: .video) else {
                Task { @MainActor in
                    self.appendLog("no \(position == .front ? "front" : "back") camera found")
                }
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                Task { @MainActor in
                    self.appendLog("camera → \(position == .front ? "front" : "back")")
                }
            } catch {
                Task { @MainActor in
                    self.appendLog("camera switch failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func setPaddleFromTouchUI(_ value: Float) {
        paddlePosition = value
        // Keep the hardware control in sync so the overlay doesn't go stale.
        // AVCaptureSlider asserts on its own queue, never the main thread.
        if #available(iOS 18.0, *), let slider = paddleSlider {
            sessionQueue.async { slider.value = value }
        }
    }

    // MARK: - Setup

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.configure()
                    } else {
                        self?.statusMessage = "Camera permission denied — Camera Control needs an active camera session."
                    }
                }
            }
        default:
            statusMessage = "Camera permission denied — enable it in Settings so Camera Control stays in this app."
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            // Video input — required so the system considers us "actively using the camera".
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video) else {
                self.session.commitConfiguration()
                Task { @MainActor in
                    self.statusMessage = "No camera found on this device."
                }
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
            } catch {
                self.session.commitConfiguration()
                Task { @MainActor in
                    self.statusMessage = "Camera input failed: \(error.localizedDescription)"
                }
                return
            }

            // Custom Camera Control slider — this is the paddle steering.
            var paddleSlider: AVCaptureSlider?
            if #available(iOS 18.0, *) {
                let supports = self.session.supportsControls

                Task { @MainActor in
                    self.supportsControls = supports
                }
                if supports {
                    // Remove any stale controls first.
                    for control in self.session.controls {
                        self.session.removeControl(control)
                    }
                    let slider = AVCaptureSlider("Paddle", symbolName: "slider.horizontal.3", in: Float(0)...Float(1))
                    slider.value = 0.5
                    slider.setActionQueue(self.sessionQueue) { [weak self] newValue in

                        Task { @MainActor in
                            self?.paddlePosition = newValue
                            self?.lastSliderEvent = Date()
                            self?.appendLog("slider → \(String(format: "%.3f", newValue))")
                        }
                    }
                    if self.session.canAddControl(slider) {
                        self.session.addControl(slider)
                        paddleSlider = slider

                        Task { @MainActor in
                            self.statusMessage = "Camera running — light-press Camera Control, pick Paddle, swipe to steer."
                        }
                    } else {

                        Task { @MainActor in
                            self.statusMessage = "Camera running, but session refused the Paddle control (limit reached?)."
                        }
                    }
                } else {
                    Task { @MainActor in
                        self.statusMessage = "This device reports supportsControls = false (needs iPhone 16+ with Camera Control)."
                    }
                }
            } else {
                Task { @MainActor in
                    self.statusMessage = "Needs iOS 18+ for Camera Control sliders."
                }
            }

            // Commit MUST come before startRunning — calling startRunning
            // inside begin/commit throws NSGenericException and crashes.
            self.session.commitConfiguration()

            if #available(iOS 18.0, *), let paddleSlider {
                self.paddleSlider = paddleSlider
                self.session.setControlsDelegate(self, queue: DispatchQueue.main)
            }

            self.session.startRunning()
            if self.statusMessage == "Starting camera…" {
                Task { @MainActor in
                    self.statusMessage = "Camera running."
                }
            }
        }
    }

    private func appendLog(_ line: String) {
        let stamped = "\(Date().formatted(date: .omitted, time: .standard))  \(line)"
        eventLog.append(stamped)
        if eventLog.count > 30 { eventLog.removeFirst(eventLog.count - 30) }
    }

    func logPress(phase: String) {
        appendLog("press \(phase)")
    }
}

// MARK: - AVCaptureSessionControlsDelegate
extension CameraManager: AVCaptureSessionControlsDelegate {
    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {

        Task { @MainActor in
            self.controlsActive = true
            self.appendLog("controls became ACTIVE")
        }
    }

    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        Task { @MainActor in
            self.appendLog("controls fullscreen IN")
        }
    }

    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        Task { @MainActor in
            self.appendLog("controls fullscreen OUT")
        }
    }

    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {

        Task { @MainActor in
            self.controlsActive = false
            self.appendLog("controls became inactive")
        }
    }
}
