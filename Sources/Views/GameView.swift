import AVKit
import SpriteKit
import SwiftUI

// MARK: - SKView wrapper
//
// SwiftUI's SpriteView doesn't expose `allowsTransparency`, which we need
// for the optional live-camera game background — so we host an SKView
// directly. `.resizeFill` keeps the scene matched to the view size.

struct GameSKView: UIViewRepresentable {
    let scene: CamBreakerScene

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        view.allowsTransparency = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 60
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {}
}

// MARK: - Game screen

struct GameView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var gameState: GameState
    @Binding var path: NavigationPath

    @State private var scene: CamBreakerScene?
    @State private var pausedFromUI = false
    @State private var controlMode: ControlMode

    init(camera: CameraManager, gameState: GameState, path: Binding<NavigationPath>, controlMode: ControlMode) {
        self.camera = camera
        self.gameState = gameState
        self._path = path
        self._controlMode = State(initialValue: controlMode)
    }

    var body: some View {
        GeometryReader { geo in
            gameContent(bottomClearance: max(100, geo.size.height * 0.22))
        }
    }

    private func gameContent(bottomClearance: CGFloat) -> some View {
        ZStack {
            // ONE persistent camera preview, never created/destroyed while the
            // session runs (churning preview layers under a live capture
            // session crashes AVFoundation). It either fills the screen behind
            // the game or shrinks to a peephole above it.
            CameraPreviewView(session: camera.session)
                .zIndex(gameState.useCameraBackground ? 0 : 2)
                .frame(width: gameState.useCameraBackground ? nil : 104,
                       height: gameState.useCameraBackground ? nil : 78)
                .clipShape(RoundedRectangle(cornerRadius: gameState.useCameraBackground ? 0 : 10))
                .overlay(
                    RoundedRectangle(cornerRadius: gameState.useCameraBackground ? 0 : 10)
                        .stroke(Color.white.opacity(gameState.useCameraBackground ? 0 : 0.35), lineWidth: 1)
                )
                .padding(.leading, gameState.useCameraBackground ? 0 : 12)
                .padding(.top, gameState.useCameraBackground ? 0 : 70)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(gameState.useCameraBackground ? .all : [])
                .allowsHitTesting(false)

            if gameState.useCameraBackground {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(0.5)
            }

            if let scene {
                GameSKView(scene: scene)
                    .ignoresSafeArea()
                    .zIndex(1)
            }

            // HUD strip. Everything informational lives in the TOP half —
            // the bottom belongs to the paddle and ball alone.
            VStack(spacing: 0) {
                hudBar
                messageBanner
                Spacer()
                if gameState.phase == .serving {
                    serveHint
                        .padding(.bottom, bottomClearance)
                } else {
                    Spacer()
                        .frame(height: bottomClearance)
                }
            }
            .allowsHitTesting(false)

            // The one and only pause button. It must live outside the
            // touch-transparent HUD above to receive taps, aligned with the
            // score row via matching padding.
            VStack {
                HStack {
                    Spacer()
                    Button {
                        pausedFromUI = true
                        scene?.isPaused = true
                        gameState.phase = .paused
                    } label: {
                        Image(systemName: "pause.fill")
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                Spacer()
            }

            if pausedFromUI { pauseMenu }
            if gameState.phase == .levelClear { levelClearCard }
            if gameState.phase == .gameOver { gameOverCard }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarHidden(true)
        // Claim the Camera Control button for the game (like the test screen
        // does). Without this interaction the system never hands us the
        // controls overlay, so swipes have nowhere to go. Full press acts as
        // the BlackBerry SPACE key: launch / fire.
        .onCameraCaptureEvent { event in
            if event.phase == .ended {
                scene?.primaryAction()
            }
        }
        .onAppear {
            if scene == nil {
                let s = CamBreakerScene(size: UIScreen.main.bounds.size)
                s.gameState = gameState
                s.cameraLink = camera
                s.controlMode = controlMode
                s.useCameraBackground = gameState.useCameraBackground
                s.cameraPaddle01 = controlMode == .cameraControl ? CGFloat(camera.paddlePosition) : nil
                scene = s
                gameState.resetRun()
                s.startLevel(gameState.level)
            }
            scene?.isPaused = false
        }
        .onDisappear { scene?.isPaused = true }
        .onChange(of: controlMode) { _, mode in
            scene?.controlMode = mode
            scene?.cameraPaddle01 = mode == .cameraControl ? CGFloat(camera.paddlePosition) : nil
        }
        .onChange(of: gameState.useCameraBackground) { _, v in
            scene?.useCameraBackground = v
        }
    }

    // MARK: HUD

    private var hudBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if gameState.pureCameraRun && controlMode == .cameraControl {
                        Text("📷")
                            .font(.caption)
                    }
                    Text("SCORE \(gameState.score)")
                        .font(.system(.headline, design: .monospaced))
                }
                Text("BEST \(gameState.highScore)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("LEVEL \(gameState.level)")
                .font(.system(.headline, design: .monospaced))
            Spacer()
            LivesView(lives: gameState.lives)
            // Pause lives here visually, but the actual tappable button is
            // pauseOverlay below: anything inside this touch-transparent HUD
            // can't receive taps, and SwiftUI has no child opt-out.
            Color.clear
                .frame(width: 40, height: 40)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.black.opacity(gameState.useCameraBackground ? 0.45 : 0.85))
    }

    private var messageBanner: some View {
        VStack(spacing: 8) {
            if let msg = gameState.message {
                Text(msg)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.yellow)
                    .clipShape(Capsule())
                    .transition(.scale)
            }
            bonusPills
        }
        .padding(.top, 6)
        .animation(.easeInOut, value: gameState.message)
    }

    /// Serve coaching: the full Camera Control recipe only until the first
    /// swipe lands, then a short reminder. Fewer words, more game.
    private var serveHint: some View {
        Text(serveHintText)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15))
            .clipShape(Capsule())
            .padding(.horizontal, 30)
    }

    private var serveHintText: String {
        if controlMode == .cameraControl {
            if camera.lastSliderEvent == .distantPast {
                return "Light-press Camera Control → pick Paddle → swipe. Tap to launch."
            }
            return "Swipe to aim — tap to launch"
        }
        return "Drag to aim — tap to launch"
    }

    @ViewBuilder
    private var bonusPills: some View {
        let pills: [(String, Bool)] = [
            ("GUN \(gameState.ammo)", gameState.ammo > 0),
            ("LASER", gameState.hasLaser),
            ("CATCH", gameState.hasCatch),
            ("LONG", gameState.hasLong),
            ("FLIP", gameState.isFlipped),
            ("WRAP", gameState.isWrapped),
            ("SLOW", gameState.ballIsSlow),
            ("BOMB", gameState.bombArmed),
        ]
        .filter { $0.1 }
        HStack(spacing: 6) {
            ForEach(pills.map(\.0), id: \.self) { name in
                Text(name)
                    .font(.caption2.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cyan)
                    .clipShape(Capsule())
            }
            if gameState.ballCount > 1 {
                Text("x\(gameState.ballCount) BALLS")
                    .font(.caption2.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: Overlays

    private var pauseMenu: some View {
        MenuCard(title: "Paused") {
            settingRow(label: "Steering") {
                Picker("", selection: $controlMode) {
                    ForEach(ControlMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
            }
            if controlMode == .cameraControl {
                settingRow(label: "📷 swipe") {
                    Text(String(format: "%.2f", camera.paddlePosition))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            }
            settingRow(label: "Camera background") {
                Toggle("", isOn: $gameState.useCameraBackground)
            }
            settingRow(label: "Camera") {
                Picker("", selection: Binding(
                    get: { camera.cameraPosition },
                    set: { camera.setCameraPosition($0) }
                )) {
                    Text("Back").tag(AVCaptureDevice.Position.back)
                    Text("Front").tag(AVCaptureDevice.Position.front)
                }
                .pickerStyle(.segmented)
            }
            settingRow(label: "Sound") {
                Toggle("", isOn: Binding(
                    get: { SoundManager.shared.enabled },
                    set: { SoundManager.shared.enabled = $0 }
                ))
            }
            Button("Resume") {
                pausedFromUI = false
                scene?.resumeFromPause()
            }
            .buttonStyle(BigButton(color: .green))
            Button("Restart level") {
                pausedFromUI = false
                scene?.isPaused = false
                scene?.startLevel(gameState.level)
            }
            .buttonStyle(BigButton(color: .gray))
            Button("Quit to menu") {
                scene?.isPaused = true
                path.removeLast(path.count)
            }
            .buttonStyle(BigButton(color: .red))
        }
    }

    private var levelClearCard: some View {
        MenuCard(title: "Level \(gameState.level) clear!") {
            Text("Score: \(gameState.score)")
                .foregroundStyle(.white)
            Button("Next level →") {
                scene?.advanceToNextLevel()
            }
            .buttonStyle(BigButton(color: .green))
        }
    }

    private var gameOverCard: some View {
        MenuCard(title: "Game Over") {
            Text("Score: \(gameState.score)")
                .foregroundStyle(.white)
            if gameState.score > gameState.highScoreAtRunStart, gameState.score > 0 {
                Text("New best! 🏆")
                    .foregroundStyle(.yellow)
            } else {
                Text("Best: \(gameState.highScore)")
                    .foregroundStyle(.secondary)
            }
            if gameState.pureCameraRun && controlMode == .cameraControl {
                if gameState.score > gameState.cameraBestAtRunStart, gameState.score > 0 {
                    Text("New 📷 best! 🏆")
                        .foregroundStyle(.cyan)
                } else {
                    Text("📷 Best: \(gameState.cameraBest)")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("📷 Best: \(gameState.cameraBest)")
                    .foregroundStyle(.secondary)
            }
            Button("Play again") {
                gameState.resetRun()
                scene?.startLevel(gameState.level)
            }
            .buttonStyle(BigButton(color: .green))
            Button("Menu") {
                path.removeLast(path.count)
            }
            .buttonStyle(BigButton(color: .gray))
        }
    }

    private func settingRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).foregroundStyle(.white)
            Spacer()
            content().frame(maxWidth: 170)
        }
    }
}

// MARK: - Shared bits

struct LivesView: View {
    let lives: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(lives, 0), id: \.self) { _ in
                Circle().fill(Color.white).frame(width: 10, height: 10)
            }
        }
    }
}

struct MenuCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
            content()
        }
        .padding(22)
        .frame(maxWidth: 320)
        .background(Color(white: 0.12).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.2)))
    }
}

struct BigButton: ButtonStyle {
    var color: Color = .green
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
