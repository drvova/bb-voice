import AVFoundation
import ExpoModulesCore
import MediaPlayer
import UIKit

// iOS counterpart of the Android foreground service. iOS keeps an app with the
// `audio` background mode running only while its audio session is playing or
// recording, and the recognizer stops between sessions. We hold the session
// open with a silent loop for as long as hands-free is on, so the JS voice loop
// (timers, fetch, WebSocket, WebRTC events) keeps running with the screen off.
// The lock screen's Now Playing controls stand in for the notification's Stop.
public class BbVoiceNativeModule: Module {
  private var player: AVAudioPlayer?
  private var keepingAlive = false
  private var callRoute = false
  private var observers: [NSObjectProtocol] = []
  private var commandTargets: [(MPRemoteCommand, Any)] = []

  public func definition() -> ModuleDefinition {
    Name("BbVoiceNative")
    Events("onStopRequested")

    OnCreate {
      self.observeAudioSession()
    }

    Function("startKeepAlive") { (title: String, text: String) -> Bool in
      DispatchQueue.main.async {
        self.keepingAlive = true
        self.activateSession()
        self.startPlayer()
        self.enableRemoteCommands()
        self.setNowPlaying(title: title, text: text)
      }
      return true
    }

    Function("updateKeepAlive") { (title: String, text: String) in
      DispatchQueue.main.async {
        guard self.keepingAlive else { return }
        // The recognizer and WebRTC reconfigure the shared session; make sure
        // the silent loop survived it.
        if self.player?.isPlaying != true { self.startPlayer() }
        self.setNowPlaying(title: title, text: text)
      }
    }

    Function("stopKeepAlive") {
      DispatchQueue.main.async {
        self.keepingAlive = false
        self.player?.stop()
        self.player = nil
        self.disableRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !self.callRoute {
          try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
      }
    }

    // WebRTC configures the session for voice chat, which plays through the
    // earpiece. Route the call to a headset if one is connected, otherwise the
    // loudspeaker.
    Function("setCallAudioRoute") { (active: Bool) in
      DispatchQueue.main.async {
        self.callRoute = active
        self.applyCallRoute()
      }
    }

    OnDestroy {
      self.observers.forEach { NotificationCenter.default.removeObserver($0) }
      self.observers = []
      self.player?.stop()
      self.player = nil
      self.disableRemoteCommands()
    }
  }

  // ---- audio session ----------------------------------------------------------

  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // Matches the recognizer's iosCategory in voiceSession.ts so starting a
      // recognition session doesn't reroute audio.
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
      try session.setActive(true)
    } catch {
      NSLog("[bbvoice] audio session: \(error)")
    }
  }

  private func startPlayer() {
    do {
      if player == nil {
        let p = try AVAudioPlayer(data: Self.silentWav)
        p.numberOfLoops = -1
        p.prepareToPlay()
        player = p
      }
      player?.play()
    } catch {
      NSLog("[bbvoice] keep-alive player: \(error)")
    }
  }

  private func applyCallRoute() {
    let session = AVAudioSession.sharedInstance()
    guard callRoute else {
      try? session.overrideOutputAudioPort(.none)
      return
    }
    let outputs = session.currentRoute.outputs.map(\.portType)
    // Only the earpiece is overridden; headsets, Bluetooth and CarPlay keep the call.
    if outputs.contains(.builtInReceiver) {
      try? session.overrideOutputAudioPort(.speaker)
    }
  }

  private func observeAudioSession() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    observers.append(
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
        guard let self, self.callRoute else { return }
        self.applyCallRoute()
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
        guard let self, self.keepingAlive,
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else { return }
        // A phone call or Siri took the session; take it back when they're done.
        self.activateSession()
        self.startPlayer()
        self.applyCallRoute()
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
        guard let self, self.keepingAlive else { return }
        self.player = nil
        self.activateSession()
        self.startPlayer()
        self.applyCallRoute()
      })
  }

  // ---- lock screen ------------------------------------------------------------

  private func enableRemoteCommands() {
    guard commandTargets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    for command in [center.pauseCommand, center.stopCommand, center.togglePlayPauseCommand] {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        self?.sendEvent("onStopRequested", [:])
        return .success
      }
      commandTargets.append((command, target))
    }
    center.playCommand.isEnabled = false
    UIApplication.shared.beginReceivingRemoteControlEvents()
  }

  private func disableRemoteCommands() {
    for (command, target) in commandTargets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    commandTargets = []
    UIApplication.shared.endReceivingRemoteControlEvents()
  }

  private func setNowPlaying(title: String, text: String) {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: text,
      MPNowPlayingInfoPropertyIsLiveStream: true,
      MPNowPlayingInfoPropertyPlaybackRate: 1.0,
    ]
  }

  // One second of 8 kHz mono 16-bit silence as a WAV file.
  private static let silentWav: Data = {
    let sampleRate: UInt32 = 8000
    let dataSize: UInt32 = sampleRate * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(sampleRate)
    append(sampleRate * 2)  // byte rate
    append(UInt16(2))  // block align
    append(UInt16(16))  // bits per sample
    data.append(contentsOf: Array("data".utf8))
    append(dataSize)
    data.append(Data(count: Int(dataSize)))
    return data
  }()
}
