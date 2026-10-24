import Foundation

#if SAYALL_SIRI_REMOTE_ENABLED

/// 开源构建的 Siri Remote 驱动（候选，待真实设备矩阵验收）。
///
/// 组合开放的 `AppleSiriRemoteAdapter`（IOHID 按键/触摸）与
/// `AppleRemoteAudioClient`（HCI 租约 → BTPacketLogger → Opus → PCM），
/// 对外提供与私有包 `SayAllSiriRemoteFeature` 等价的宿主接口，由
/// `SiriRemoteFeatureIntegration` 在 `!canImport(SayAllSiriRemote)` 时实例化。
///
/// v1 范围：A2540（PID 0x0314）与 A2854（PID 0x0315）按键 + Siri 语音，
/// 其中 A2540 为本次新增适配目标，A2854 共享同一开放链路。语音帧为 TOC `0xB8`
/// CELT 48 kHz Opus，`AppleRemoteOpusDecoder(sampleRate: 16_000)` 由
/// libopus 内置重采样直接输出 16 kHz PCM，与 A2854 路径相同；
/// 电量/电源快照不发送（UI 自动隐藏）。激活写入由
/// `SayAllAppleRemoteAudioCapture` helper 按 `0xAF → Feature 0xFF` 完成。
final class OpenSiriRemoteFeature {
    /// 开放驱动声明的能力：按键边沿、触摸面、连续滚动与语音流。
    /// A2540 的触摸桥与按键共用同一 HID 匹配，触摸输出是否可用取决于系统
    /// MultitouchSupport 动态加载；声明保留以等待实机验证，不代表已验收。
    private static let declaredCapabilities: SiriRemoteDeclaredCapabilities =
        [.controlEdges, .touchSurface, .continuousScroll, .voiceStream]

    var onConnection: ((SiriRemoteConnection) -> Void)?
    var onDeclaredCapabilitiesChange: ((SiriRemoteDeclaredCapabilities) -> Void)?
    var onControlEvent: ((SiriRemoteControlEvent) -> Void)?
    var onSamples: (([Int16]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onTouchFeedback: ((SiriRemoteTouchFeedbackKind) -> Void)?
    var onContextualScroll: ((Double) -> Bool)?
    var onCenterTapConfirmation: ((SiriRemoteDeviceIdentity) -> Bool)?

    private let adapter: AppleSiriRemoteAdapter
    private let audioClient: AppleRemoteAudioClient
    private let logger: (String) -> Void
    private var touchInterpreter = AppleSiriRemoteTouchInterpreter()
    private var touchSuppressed = false
    private var touchRoutingMode: SiriRemoteTouchRoutingMode = .standard
    private var connectedTokens: Set<String> = []

    init(
        acceptedProductIDs: Set<Int> = AppleSiriRemoteDeviceMatch.supportedProductIDs,
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.logger = logger
        adapter = AppleSiriRemoteAdapter(
            acceptedProductIDs: acceptedProductIDs,
            logger: logger
        )
        audioClient = AppleRemoteAudioClient(logger: logger)
        adapter.onConnection = { [weak self] connection in self?.handleConnection(connection) }
        adapter.onControlEvent = { [weak self] event in self?.handleControlEvent(event) }
        adapter.onTouchEvent = { [weak self] event in self?.handleTouchEvent(event) }
        audioClient.onSamples = { [weak self] samples in self?.onSamples?(samples) }
        audioClient.onStatus = { [weak self] status in self?.onStatus?(status) }
    }

    deinit {
        audioClient.stop()
    }

    func start(userInitiated: Bool = false) {
        // customMappingEnabled 由宿主随后经 restart(customMappingEnabled:) 下发；
        // 首启不抢占按键原生语义，与私有路径的用户手势语义保持一致。
        adapter.start(customMappingEnabled: false)
        audioClient.start()
        if userInitiated {
            logger("APPLE REMOTE START reason=user_initiated")
        }
    }

    func restart(customMappingEnabled: Bool) {
        adapter.restart(customMappingEnabled: customMappingEnabled)
    }

    func stop() {
        adapter.stop(reason: .adapterStopped, suppressNextRelease: false)
        audioClient.stop()
        if !connectedTokens.isEmpty {
            connectedTokens.removeAll()
            onDeclaredCapabilitiesChange?([])
        }
    }

    @discardableResult
    func beginCapture() -> Bool {
        audioClient.beginCapture()
    }

    @discardableResult
    func resumeCaptureIfStopping() -> Bool {
        audioClient.resumeCaptureIfStopping()
    }

    func stopCapture(completion: @escaping () -> Void) {
        audioClient.stopCapture(completion: completion)
    }

    func setVoiceTouchSuppressed(_ suppressed: Bool) {
        touchSuppressed = suppressed
        if suppressed {
            touchInterpreter.suppressCurrentContact()
        }
    }

    func setTouchRoutingMode(_ mode: SiriRemoteTouchRoutingMode) {
        guard mode != touchRoutingMode else { return }
        touchRoutingMode = mode
        touchInterpreter.setRoutingMode(mode)
        logger("APPLE REMOTE TOUCH routing_mode=\(mode.rawValue)")
    }

    private func handleConnection(_ connection: AppleSiriRemoteAdapter.Connection) {
        let device = SiriRemoteDeviceIdentity(
            adapterID: connection.device.adapterID,
            instanceToken: connection.device.instanceID
        )
        if connection.isConnected {
            connectedTokens.insert(device.instanceToken)
            onDeclaredCapabilitiesChange?(Self.declaredCapabilities)
        } else {
            connectedTokens.remove(device.instanceToken)
            if connectedTokens.isEmpty {
                onDeclaredCapabilitiesChange?([])
            }
        }
        onConnection?(SiriRemoteConnection(
            device: device,
            model: connection.model,
            fingerprint: connection.fingerprint,
            isConnected: connection.isConnected
        ))
    }

    private func handleControlEvent(_ event: RemoteHardwareControlEvent) {
        guard let control = SiriRemoteControl(rawValue: event.controlID),
              let phase = SiriRemoteControlPhase(rawValue: event.phase.rawValue)
        else { return }
        let device = SiriRemoteDeviceIdentity(
            adapterID: event.device.adapterID,
            instanceToken: event.device.instanceID
        )
        onControlEvent?(SiriRemoteControlEvent(
            device: device,
            control: control,
            phase: phase,
            sequence: event.sequence,
            cancellationReason: event.cancellationReason?.rawValue
        ))
    }

    private func handleTouchEvent(_ event: RemoteHardwareTouchEvent) {
        // 语音会话与尾音排空期间屏蔽触摸输出，与私有路径语义一致。
        guard !touchSuppressed else { return }
        let device = SiriRemoteDeviceIdentity(
            adapterID: event.device.adapterID,
            instanceToken: event.device.instanceID
        )
        for output in touchInterpreter.handle(event) {
            if touchRoutingMode == .circularNavigation {
                // 圆周导航会话：滚动只交宿主上下文消费，点击只做中心确认，
                // 绝不回退到系统指针移动/滚动/点击。
                switch output {
                case let .scroll(pixels):
                    if onContextualScroll?(pixels) == true {
                        onTouchFeedback?(.scrolled(pixels: pixels, speed: abs(pixels)))
                    }
                case .click:
                    if onCenterTapConfirmation?(device) == true {
                        onTouchFeedback?(.clicked)
                    }
                case .move:
                    break
                }
                continue
            }
            switch output {
            case let .move(deltaX, deltaY):
                guard AppleSiriRemotePointerController.perform(
                    .move(deltaX: deltaX, deltaY: deltaY)
                ) else { continue }
                onTouchFeedback?(.pointerMoved(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    speed: (deltaX * deltaX + deltaY * deltaY).squareRoot()
                ))
            case let .scroll(pixels):
                // 滚动先给宿主上下文消费（如 AppSwitcher），未消费再落到指针滚动。
                guard onContextualScroll?(pixels) != true else {
                    onTouchFeedback?(.scrolled(pixels: pixels, speed: abs(pixels)))
                    continue
                }
                guard AppleSiriRemotePointerController.perform(.scroll(pixels: pixels))
                else { continue }
                onTouchFeedback?(.scrolled(pixels: pixels, speed: abs(pixels)))
            case .click:
                guard onCenterTapConfirmation?(device) != true else {
                    onTouchFeedback?(.clicked)
                    continue
                }
                guard AppleSiriRemotePointerController.perform(.click) else { continue }
                onTouchFeedback?(.clicked)
            }
        }
    }
}

#endif // SAYALL_SIRI_REMOTE_ENABLED
