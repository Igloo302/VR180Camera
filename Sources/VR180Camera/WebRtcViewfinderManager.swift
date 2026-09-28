import Foundation
import SwiftUI
import WebRTC
import AppKit
import CryptoKit
import VR180Protocol

@MainActor
final class WebRtcViewfinderManager: NSObject, ObservableObject, RTCPeerConnectionDelegate {
    @Published var isStreaming = false
    @Published var statusMessage = "未启动取景"
    @Published var remoteVideoTrack: RTCVideoTrack? = nil

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var localIceCandidates: [RTCIceCandidate] = []
    private var sessionName = UUID().uuidString
    private var isNegotiating = false

    override init() {
        super.init()
        RTCInitializeSSL()
    }

    deinit {
    }

    func startViewfinder(cameraIP: String, cameraPort: String, key: SymmetricKey, clockSkew: Int64) {
        guard !isStreaming, !isNegotiating else { return }
        isNegotiating = true
        statusMessage = "正在初始化 WebRTC 引擎..."

        sessionName = UUID().uuidString.lowercased()
        localIceCandidates.removeAll()
        remoteVideoTrack = nil

        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let pcFactory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        self.factory = pcFactory

        let rtcConfig = RTCConfiguration()
        rtcConfig.tcpCandidatePolicy = .enabled
        rtcConfig.keyType = .ECDSA

        let optionalConstraints = ["DtlsSrtpKeyAgreement": "true"]
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: optionalConstraints
        )

        guard let pc = pcFactory.peerConnection(with: rtcConfig, constraints: constraints, delegate: self) else {
            statusMessage = "创建 PeerConnection 失败"
            isNegotiating = false
            return
        }
        self.peerConnection = pc
        statusMessage = "正在生成 SDP 提议..."

        pc.offer(for: constraints) { [weak self] offer, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.statusMessage = "创建 Offer 失败: \(error.localizedDescription)"
                    self.isNegotiating = false
                    return
                }
                guard let offer else {
                    self.statusMessage = "未生成有效的本地 Offer"
                    self.isNegotiating = false
                    return
                }

                self.peerConnection?.setLocalDescription(offer) { [weak self] setErr in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let setErr {
                            self.statusMessage = "设置 LocalDescription 失败: \(setErr.localizedDescription)"
                            self.isNegotiating = false
                            return
                        }
                        self.statusMessage = "正在收集 ICE 候选网络节点..."
                        // Give 1.5 seconds to gather local host & reflexive ICE candidates before sending
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            self?.sendOfferToCamera(offer: offer, cameraIP: cameraIP, cameraPort: cameraPort, key: key, clockSkew: clockSkew)
                        }
                    }
                }
            }
        }
    }

    private func sendOfferToCamera(offer: RTCSessionDescription, cameraIP: String, cameraPort: String, key: SymmetricKey, clockSkew: Int64) {
        statusMessage = "正在与相机交换 SDP 会话..."

        let candidates = localIceCandidates.map { (mid: $0.sdpMid ?? "0", mline: Int($0.sdpMLineIndex), sdp: $0.sdp) }
        let requestBody = CameraProtocol.startWebRtcRequest(
            sessionName: sessionName,
            sdpOffer: offer.sdp,
            iceCandidates: candidates,
            skew: clockSkew
        )

        let requestPath = "/daydreamcamera"
        let authHeader = CameraProtocol.computeAuthorizationHeader(method: "POST", path: requestPath, body: requestBody, key: key)
        let urlString = "https://\(cameraIP):\(cameraPort)\(requestPath)"

        guard let url = URL(string: urlString) else {
            statusMessage = "无效的相机端点 URL: \(urlString)"
            isNegotiating = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15.0
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = requestBody

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        let session = URLSession(configuration: config, delegate: TrustSelfSignedDelegate(), delegateQueue: .main)

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isNegotiating = false
                if let error {
                    self.statusMessage = "向相机发送 WebRTC 请求失败: \(error.localizedDescription)"
                    return
                }
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, let data else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    print("[WebRTC] Camera HTTP error \(code), body: \(bodyStr)")
                    self.statusMessage = "相机返回 HTTP 错误: \(code)"
                    return
                }

                do {
                    let respPB = try PB(data)
                    // Check CameraApiResponse response_status (field 1)
                    if let statusData = respPB.fields[1]?.first {
                        let statusPB = try PB(statusData)
                        let code = statusPB.optionalUInt(1) ?? 0
                        if code != 0 {
                            self.statusMessage = "相机拒绝 WebRTC 会话，错误码: \(code)"
                            return
                        }
                    }

                    // Field 11 = webrtc_answer (WebRtcSessionDescription)
                    guard let answerData = respPB.fields[11]?.first else {
                        self.statusMessage = "相机响应中缺少 WebRTC Answer 数据"
                        return
                    }

                    let answerPB = try PB(answerData)
                    guard let sdpBytes = answerPB.fields[1]?.first, let remoteSdp = String(data: sdpBytes, encoding: .utf8) else {
                        self.statusMessage = "相机 Answer SDP 解析失败"
                        return
                    }

                    self.statusMessage = "正在建立 P2P 取景通道..."
                    let answerDesc = RTCSessionDescription(type: .answer, sdp: remoteSdp)
                    self.peerConnection?.setRemoteDescription(answerDesc) { [weak self] setErr in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let setErr {
                                self.statusMessage = "设置 RemoteDescription 失败: \(setErr.localizedDescription)"
                                return
                            }

                            // Add remote ICE candidates (field 2 of WebRtcSessionDescription)
                            for candData in answerPB.fields[2] ?? [] {
                                if let candPB = try? PB(candData) {
                                    let mid = (try? candPB.data(1)).flatMap { String(data: $0, encoding: .utf8) } ?? "0"
                                    let line = Int32(candPB.optionalUInt(2) ?? 0)
                                    let sdp = (try? candPB.data(3)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                    if !sdp.isEmpty {
                                        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line, sdpMid: mid)
                                        self.peerConnection?.add(candidate) { err in
                                            if let err {
                                                print("Add ICE candidate error: \(err.localizedDescription)")
                                            }
                                        }
                                    }
                                }
                            }
                            self.statusMessage = "WebRTC 媒体流握手完成，正在接收视频..."
                            self.isStreaming = true
                        }
                    }
                } catch {
                    self.statusMessage = "解析相机响应失败: \(error.localizedDescription)"
                }
            }
        }
        task.resume()
    }

    func stopViewfinder() {
        if isStreaming {
            isStreaming = false
            statusMessage = "取景已关闭"
        }
        peerConnection?.close()
        peerConnection = nil
        remoteVideoTrack = nil
        localIceCandidates.removeAll()
        factory = nil
    }

    // MARK: - RTCPeerConnectionDelegate
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            if let videoTrack = stream.videoTracks.first {
                videoTrack.isEnabled = true
                self.remoteVideoTrack = videoTrack
                self.statusMessage = "实时双目画面已就绪"
                self.isStreaming = true
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor in
            if let videoTrack = transceiver.receiver.track as? RTCVideoTrack {
                videoTrack.isEnabled = true
                self.remoteVideoTrack = videoTrack
                self.statusMessage = "实时双目画面已就绪"
                self.isStreaming = true
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor in
            if let videoTrack = receiver.track as? RTCVideoTrack {
                videoTrack.isEnabled = true
                self.remoteVideoTrack = videoTrack
                self.statusMessage = "实时双目画面已就绪"
                self.isStreaming = true
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            if self.remoteVideoTrack != nil {
                self.remoteVideoTrack = nil
                self.statusMessage = "相机视频流已停止"
            }
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed:
                self.statusMessage = "取景画面传输中 (P2P 已建立)"
                self.isStreaming = true
            case .checking:
                self.statusMessage = "正在打通 P2P 网络连接..."
            case .failed, .disconnected:
                self.statusMessage = "取景连接中断"
                self.isStreaming = false
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            self.localIceCandidates.append(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - SwiftUI Metal Video View Wrapper
struct WebRTCVideoView: NSViewRepresentable {
    let videoTrack: RTCVideoTrack?

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero)
        videoTrack?.add(view)
        return view
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        videoTrack?.add(nsView)
    }

    static func dismantleNSView(_ nsView: RTCMTLNSVideoView, coordinator: ()) {
        // cleanup if needed
    }
}
