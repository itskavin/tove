import AVFoundation
import CallKit
import Flutter
import UIKit

#if canImport(WebRTC)
  import WebRTC
#endif
#if canImport(flutter_webrtc)
  import flutter_webrtc
#endif

/// CallKit integration for Tove voice sessions that the app starts.
///
/// Channel `io.github.tovechat.tove/call`:
///  * Flutter -> native: `startCall {muted}`, `updateCall {muted}`, `endCall {}`.
///  * Native -> Flutter: `onMute {muted}`, `onEnd {}`.
///
/// Only outgoing, app-originated calls are reported (CXStartCallAction). There
/// is no PushKit and no incoming-call reporting.
///
/// Audio: CallKit owns activation of the shared AVAudioSession. Before the call
/// is requested, WebRTC is put in manual-audio mode and the flutter_webrtc
/// AVAudioEngine audio device module is made unavailable, so neither starts
/// audio I/O on its own. `provider(_:didActivate:)` hands the CallKit-activated
/// session to `RTCAudioSession` and makes the engine available again;
/// `didDeactivate` does the reverse. flutter_webrtc's own session management
/// stays enabled: it only sets the category (already playAndRecord/voiceChat
/// here) and the speaker route, so the app's speaker toggle keeps working.
///
/// Every Flutter result is answered exactly once, including on CallKit errors,
/// permission denial and cancellation during setup.
final class HermesCallKit: NSObject, FlutterPlugin {
  static let channelName = "io.github.tovechat.tove/call"

  /// Dart must answer onMute/onEnd within this, or it is treated as unreachable.
  private static let flutterAckTimeout: TimeInterval = 6

  /// Keeps the instance alive for the life of the engine.
  private static var shared: HermesCallKit?

  private let channel: FlutterMethodChannel
  private let provider: CXProvider
  private let callController = CXCallController()

  private var callUUID: UUID?
  private var muted = false
  private var pendingStart: FlutterResult?
  /// Mute value that Flutter asked CallKit to show; its CXSetMutedCallAction
  /// must not be echoed back to Flutter as onMute.
  private var flutterMuteTarget: Bool?
  /// The CXEndCallAction in flight came from Flutter's endCall.
  private var endFromFlutter = false
  private var pendingEndResults: [FlutterResult] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let instance = HermesCallKit(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    shared = instance
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    // AI voice sessions are not phone calls: keep them out of Phone > Recents.
    configuration.includesCallsInRecents = false
    if let icon = UIImage(named: "CallKitIcon") {
      configuration.iconTemplateImageData = icon.pngData()
    }
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: nil)  // main queue
  }

  // MARK: - Flutter -> native

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startCall":
      guard let muted = Self.mutedArgument(call) else {
        return result(Self.badArguments(call.method))
      }
      startCall(muted: muted, result: result)
    case "updateCall":
      guard let muted = Self.mutedArgument(call) else {
        return result(Self.badArguments(call.method))
      }
      updateCall(muted: muted, result: result)
    case "endCall":
      endCall(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startCall(muted: Bool, result: @escaping FlutterResult) {
    if callUUID != nil, pendingStart == nil {
      // Idempotent: already live, just sync the mute state.
      updateCall(muted: muted) { _ in result(Self.startedPayload) }
      return
    }
    if pendingStart != nil {
      return result(FlutterError(code: "busy", message: "A call is already starting.", details: nil))
    }
    if UIApplication.shared.applicationState == .background {
      return result(
        FlutterError(
          code: "not_visible",
          message: "Start a call only while Tove is open on screen.",
          details: nil))
    }
    pendingStart = result
    self.muted = muted

    Self.ensureMicrophonePermission { [weak self] granted in
      guard let self, self.pendingStart != nil else { return }
      guard granted else {
        self.resolveStart(
          error: FlutterError(
            code: "microphone_denied",
            message: "Microphone access is off. Allow it in Settings > Tove to talk to Hermes.",
            details: nil))
        return
      }
      self.requestStartTransaction()
    }
  }

  private func requestStartTransaction() {
    let uuid = UUID()
    callUUID = uuid
    prepareAudioForCallKit()

    let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: "Hermes"))
    action.isVideo = false
    callController.request(CXTransaction(action: action)) { [weak self] error in
      DispatchQueue.main.async {
        guard let self, let error else { return }  // success continues in perform(CXStartCallAction)
        NSLog("HermesCallKit: start transaction failed: \(error)")
        if self.callUUID == uuid { self.callUUID = nil }
        // Hand audio back to flutter_webrtc so Flutter can still continue
        // without CallKit (for example where CallKit is unavailable).
        self.restorePluginAudio()
        self.resolveStart(
          error: FlutterError(
            code: "callkit_failed",
            message: "iOS did not allow the call (\(error.localizedDescription)). Lock-screen controls are unavailable.",
            details: nil))
      }
    }
  }

  private func updateCall(muted: Bool, result: @escaping FlutterResult) {
    guard let uuid = callUUID else { return result(["active": false]) }
    if muted == self.muted { return result(["active": true]) }
    self.muted = muted
    applyLocalMute(muted)
    flutterMuteTarget = muted
    callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) {
      [weak self] error in
      DispatchQueue.main.async {
        if let error {
          NSLog("HermesCallKit: mute transaction failed: \(error)")
          self?.flutterMuteTarget = nil
        }
        result(["active": true])
      }
    }
  }

  private func endCall(result: @escaping FlutterResult) {
    guard let uuid = callUUID else {
      // Hung up while still asking for the microphone, or nothing to end.
      resolveStart(error: Self.cancelled)
      return result(nil)
    }
    pendingEndResults.append(result)
    if endFromFlutter { return }  // an end is already in flight
    endFromFlutter = true
    callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
      DispatchQueue.main.async {
        guard let self, let error else { return }  // success continues in perform(CXEndCallAction)
        NSLog("HermesCallKit: end transaction failed: \(error)")
        // CallKit no longer knows the call (or refused): close it locally.
        self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        self.finishCall()
      }
    }
  }

  // MARK: - Native -> Flutter

  /// `completion(true)` only when Dart answered without error and did not return false.
  private func sendToFlutter(
    _ method: String, _ arguments: [String: Any], completion: @escaping (Bool) -> Void
  ) {
    var done = false
    let finish: (Bool) -> Void = { delivered in
      if done { return }
      done = true
      completion(delivered)
    }
    channel.invokeMethod(method, arguments: arguments) { response in
      DispatchQueue.main.async {
        if response is FlutterError {
          finish(false)
        } else if let object = response as AnyObject?, object === FlutterMethodNotImplemented {
          finish(false)
        } else if let flag = response as? Bool, flag == false {
          finish(false)
        } else {
          finish(true)
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.flutterAckTimeout) {
      if !done { NSLog("HermesCallKit: \(method) not answered by Dart in time") }
      finish(false)
    }
  }

  // MARK: - Call state

  private func resolveStart(error: FlutterError?) {
    guard let result = pendingStart else { return }
    pendingStart = nil
    if let error {
      result(error)
    } else {
      result(Self.startedPayload)
    }
  }

  /// Local cleanup once the call is over, however it ended.
  private func finishCall() {
    callUUID = nil
    flutterMuteTarget = nil
    endFromFlutter = false
    silenceWebRTC()
    resolveStart(error: Self.cancelled)
    let results = pendingEndResults
    pendingEndResults.removeAll()
    results.forEach { $0(nil) }
  }

  // MARK: - Audio

  private func prepareAudioForCallKit() {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.useManualAudio = true
      session.isAudioEnabled = false
      session.lockForConfiguration()
      do {
        // Configure, but do not activate: CallKit activates it.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
      } catch {
        NSLog("HermesCallKit: setCategory failed: \(error)")
      }
      session.unlockForConfiguration()
    #else
      NSLog("HermesCallKit: WebRTC module not importable; CallKit audio hand-off disabled")
    #endif
    setEngineAvailable(false)
    applyLocalMute(muted)
  }

  /// Back to flutter_webrtc's default behaviour (used when CallKit is refused).
  private func restorePluginAudio() {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.isAudioEnabled = true
      session.useManualAudio = false
    #endif
    setEngineAvailable(true)
    applyLocalMute(muted)
  }

  /// Native guarantee that the microphone stops when the call ends, even if
  /// Dart has not (yet) disposed its tracks: mute the ADM input and make the
  /// audio engine unavailable, which stops input and output I/O. It stays that
  /// way until the next startCall prepares a new CallKit call.
  private func silenceWebRTC() {
    applyLocalMute(true)
    setEngineAvailable(false)
    #if canImport(WebRTC)
      RTCAudioSession.sharedInstance().isAudioEnabled = false
    #endif
  }

  private func applyLocalMute(_ value: Bool) {
    #if canImport(flutter_webrtc)
      guard let adm = Self.audioDeviceModule else { return }
      if adm.isMicrophoneMuted != value {
        _ = adm.setMicrophoneMuted(value)
      }
    #endif
  }

  private func setEngineAvailable(_ available: Bool) {
    #if canImport(flutter_webrtc)
      guard let adm = Self.audioDeviceModule else { return }
      let availability = RTCAudioEngineAvailability(
        isInputAvailable: ObjCBool(available), isOutputAvailable: ObjCBool(available))
      let status = adm.setEngineAvailability(availability)
      if status != 0 {
        NSLog("HermesCallKit: setEngineAvailability(\(available)) returned \(status)")
      }
    #endif
  }

  #if canImport(flutter_webrtc)
    /// The AVAudioEngine ADM that flutter_webrtc 1.6.x creates its factory with.
    /// Nil until Dart's first WebRTC call (getUserMedia) creates the factory.
    private static var audioDeviceModule: RTCAudioDeviceModule? {
      FlutterWebRTCPlugin.sharedSingleton()?.peerConnectionFactory?.audioDeviceModule
    }
  #endif

  // MARK: - Helpers

  private static let startedPayload: [String: Any] = ["callKit": true, "notificationsVisible": true]

  private static let cancelled = FlutterError(
    code: "cancelled", message: "The call ended before it started.", details: nil)

  private static func mutedArgument(_ call: FlutterMethodCall) -> Bool? {
    (call.arguments as? [String: Any])?["muted"] as? Bool
  }

  private static func badArguments(_ method: String) -> FlutterError {
    FlutterError(code: "bad_arguments", message: "\(method) needs {muted: bool}.", details: nil)
  }

  private static func ensureMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
    let deliver: (Bool) -> Void = { granted in DispatchQueue.main.async { completion(granted) } }
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: deliver(true)
      case .denied: deliver(false)
      case .undetermined: AVAudioApplication.requestRecordPermission(completionHandler: deliver)
      @unknown default: deliver(false)
      }
    } else {
      let session = AVAudioSession.sharedInstance()
      switch session.recordPermission {
      case .granted: deliver(true)
      case .denied: deliver(false)
      case .undetermined: session.requestRecordPermission(deliver)
      @unknown default: deliver(false)
      }
    }
  }
}

// MARK: - CXProviderDelegate

extension HermesCallKit: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    // The system dropped every call (for example the CallKit daemon restarted).
    let hadCall = callUUID != nil
    finishCall()
    if hadCall { sendToFlutter("onEnd", [:]) { _ in } }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    guard action.callUUID == callUUID else { return action.fail() }
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()

    let update = CXCallUpdate()
    update.localizedCallerName = "Hermes"
    update.hasVideo = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    provider.reportCall(with: action.callUUID, updated: update)
    // The session counts as connected from the user's point of view: Flutter
    // shows its own connecting state, and the CallKit timer starts now.
    provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())

    if muted {
      // Make the CallKit UI show the initial mute state.
      flutterMuteTarget = true
      callController.request(
        CXTransaction(action: CXSetMutedCallAction(call: action.callUUID, muted: true))
      ) { [weak self] error in
        if error != nil { DispatchQueue.main.async { self?.flutterMuteTarget = nil } }
      }
    }
    resolveStart(error: nil)
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    guard action.callUUID == callUUID else { return action.fail() }
    let target = action.isMuted
    let fromFlutter = flutterMuteTarget == target
    flutterMuteTarget = nil
    muted = target
    // Enforced natively first, so a lock-screen mute holds even if Dart is slow.
    applyLocalMute(target)
    action.fulfill()
    if !fromFlutter {
      sendToFlutter("onMute", ["muted": target]) { delivered in
        if !delivered { NSLog("HermesCallKit: onMute not delivered; ADM mute still applied") }
      }
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard action.callUUID == callUUID else { return action.fail() }
    let fromFlutter = endFromFlutter
    finishCall()  // silences WebRTC natively right away
    action.fulfill()
    if !fromFlutter {
      sendToFlutter("onEnd", [:]) { delivered in
        if !delivered { NSLog("HermesCallKit: onEnd not delivered; WebRTC audio engine left stopped") }
      }
    }
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    action.fail()  // holding is not supported
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.audioSessionDidActivate(audioSession)
      session.isAudioEnabled = callUUID != nil
    #endif
    guard callUUID != nil else { return }  // activated after the call already ended
    setEngineAvailable(true)
    applyLocalMute(muted)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    #if canImport(WebRTC)
      let session = RTCAudioSession.sharedInstance()
      session.audioSessionDidDeactivate(audioSession)
      session.isAudioEnabled = false
    #endif
    setEngineAvailable(false)
  }
}
