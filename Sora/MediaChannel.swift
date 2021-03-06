import Foundation

/// メディアチャネルのイベントハンドラです。
public final class MediaChannelHandlers {
    
    /// 接続成功時に呼ばれるブロック
    public var onConnectHandler: ((Error?) -> Void)?
    
    /// 接続解除時に呼ばれるブロック
    public var onDisconnectHandler: ((Error?) -> Void)?
    
    /// ストリームが追加されたときに呼ばれるブロック
    public var onAddStreamHandler: ((MediaStream) -> Void)?
    
    /// ストリームが除去されたときに呼ばれるブロック
    public var onRemoveStreamHandler: ((MediaStream) -> Void)?
    
    /// シグナリング受信時に呼ばれるブロック
    public var onReceiveSignalingHandler: ((Signaling) -> Void)?

}

// MARK: -

/**
 
 一度接続を行ったメディアチャネルは再利用できません。
 同じ設定で接続を行いたい場合は、新しい接続を行う必要があります。
 
 ## 接続が解除されるタイミング
 
 メディアチャネルの接続が解除される条件を以下に示します。
 いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル
 (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます。

 - シグナリングチャネル (`SignalingChannel`) の接続が解除される。
 - WebSocket チャネル (`WebSocketChannel`) の接続が解除される。
 - ピアチャネル (`PeerChannel`) の接続が解除される。
 - サーバーから受信したシグナリング `ping` に対して `pong` を返さない。
   これはピアチャネルの役目です。
 
 */
public final class MediaChannel {
        
    // MARK: - イベントハンドラ
    
    /// イベントハンドラ
    public var handlers: MediaChannelHandlers = MediaChannelHandlers()
    
    /// 内部処理で使われるイベントハンドラ
    var internalHandlers: MediaChannelHandlers = MediaChannelHandlers()

    // MARK: - 接続情報
    
    /// クライアントの設定
    public let configuration: Configuration
    
    /**
     クライアント ID 。接続後にセットされます。
     */
    public var clientId: String? {
        get {
            return peerChannel.clientId
        }
    }
    
    /// 接続状態
    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .mediaChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    /// 接続中 (`state == .connected`) であれば ``true``
    public var isAvailable: Bool {
        get { return state == .connected }
    }
    
    /// 接続開始時刻。
    /// 接続中にのみ取得可能です。
    public private(set) var connectionStartTime: Date?
    
    /// 接続時間 (秒) 。
    /// 接続中にのみ取得可能です。
    public var connectionTime: Int? {
        get {
            if let start = connectionStartTime {
                return Int(Date().timeIntervalSince(start))
            } else {
                return nil
            }
        }
    }
    
    // MARK: 接続中のチャネルの情報
    
    /// 同チャネルに接続中のクライアントの数。
    /// サーバーから通知を受信可能であり、かつ接続中にのみ取得可能です。
    public var connectionCount: Int? {
        get {
            switch (publisherCount, subscriberCount) {
            case (.some(let pub), .some(let sub)):
                return pub + sub
            default:
                return nil
            }
        }
    }
    
    /// 同チャネルに接続中のクライアントのうち、パブリッシャーの数。
    /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
    public private(set) var publisherCount: Int?
    
    /// 同チャネルに接続中のクライアントの数のうち、サブスクライバーの数。
    /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
    public private(set) var subscriberCount: Int?
    
    // MARK: 接続チャネル
    
    /// シグナリングチャネル
    public let signalingChannel: SignalingChannel
    
    /// ピアチャネル
    public let peerChannel: PeerChannel
        
    /// ストリームのリスト
    public var streams: [MediaStream] {
        return peerChannel.streams
    }
    
    /// 先頭のストリーム
    public var mainStream: MediaStream? {
        return streams.first
    }

    private var connectionTimer: ConnectionTimer
    private let manager: Sora
    
    // MARK: - インスタンスの生成
    
    /**
     初期化します。
     
     - parameter manager: `Sora` オブジェクト
     - parameter configuration: クライアントの設定
     */
    init(manager: Sora, configuration: Configuration) {
        Logger.debug(type: .mediaChannel,
                  message: "create signaling channel (\(configuration._signalingChannelType))")
        Logger.debug(type: .mediaChannel,
                  message: "create peer channel (\(configuration._peerChannelType))")
        
        self.manager = manager
        self.configuration = configuration
        signalingChannel = configuration._signalingChannelType
            .init(configuration: configuration)
        signalingChannel.handlers =
            configuration.signalingChannelHandlers
        peerChannel = configuration._peerChannelType
            .init(configuration: configuration,
                  signalingChannel: signalingChannel)
        peerChannel.handlers =
            configuration.peerChannelHandlers
        handlers = configuration.mediaChannelHandlers
        
        connectionTimer = ConnectionTimer(monitors: [
            .webSocketChannel(signalingChannel.webSocketChannel),
            .signalingChannel(signalingChannel),
            .peerChannel(peerChannel)],
                                          timeout: configuration.connectionTimeout)
    }
    
    // MARK: - 接続
    
    /**
     サーバーに接続します。
     
     - parameter webRTCConfiguration: WebRTC の設定
     - parameter timeout: タイムアウトまでの秒数
     - parameter handler: 接続試行後に呼ばれるブロック
     - parameter error: (接続失敗時) エラー
     */
    func connect(webRTCConfiguration: WebRTCConfiguration,
                 timeout: Int = 30,
                 handler: @escaping (_ error: Error?) -> Void) -> ConnectionTask {
        let task = ConnectionTask()
        if state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "MediaChannel is already connected"))
            task.complete()
            return task
        }
        
        DispatchQueue.global().async {
            self.basicConnect(connectionTask: task,
                              webRTCConfiguration: webRTCConfiguration,
                              timeout: timeout,
                              handler: handler)
        }
        return task
    }
    
    private func basicConnect(connectionTask: ConnectionTask,
                              webRTCConfiguration: WebRTCConfiguration,
                              timeout: Int,
                              handler: @escaping (Error?) -> Void) {
        Logger.debug(type: .mediaChannel, message: "try connecting")
        state = .connecting
        connectionStartTime = nil
        connectionTask.peerChannel = peerChannel

        peerChannel.internalHandlers.onDisconnectHandler = { error in
            if self.state == .connecting || self.state == .connected {
                self.disconnect(error: error)
            }
            connectionTask.complete()
        }
        
        peerChannel.internalHandlers.onAddStreamHandler = { stream in
            Logger.debug(type: .mediaChannel, message: "added a stream")
            Logger.debug(type: .mediaChannel, message: "call onAddStreamHandler")
            self.internalHandlers.onAddStreamHandler?(stream)
            self.handlers.onAddStreamHandler?(stream)
        }
        
        peerChannel.internalHandlers.onRemoveStreamHandler = { stream in
            Logger.debug(type: .mediaChannel, message: "removed a stream")
            Logger.debug(type: .mediaChannel, message: "call onRemoveStreamHandler")
            self.internalHandlers.onRemoveStreamHandler?(stream)
            self.handlers.onRemoveStreamHandler?(stream)
        }
        
        peerChannel.internalHandlers.onReceiveSignalingHandler = { message in
            Logger.debug(type: .mediaChannel, message: "receive signaling")
            switch message {
            case .notifyConnection(let message):
                self.publisherCount = message.publisherCount
                self.subscriberCount = message.subscriberCount
            default:
                break
            }
            
            Logger.debug(type: .mediaChannel, message: "call onReceiveSignalingHandler")
            self.internalHandlers.onReceiveSignalingHandler?(message)
            self.handlers.onReceiveSignalingHandler?(message)
        }
        
        peerChannel.connect() { error in
            self.connectionTimer.stop()
            connectionTask.complete()
            
            if let error = error {
                Logger.error(type: .mediaChannel, message: "failed to connect")
                self.disconnect(error: error)
                handler(error)
                
                Logger.debug(type: .mediaChannel, message: "call onConnectHandler")
                self.internalHandlers.onConnectHandler?(error)
                self.handlers.onConnectHandler?(error)
                return
            }
            Logger.debug(type: .mediaChannel, message: "did connect")
            self.state = .connected
            handler(nil)
            Logger.debug(type: .mediaChannel, message: "call onConnectHandler")
            self.internalHandlers.onConnectHandler?(nil)
            self.handlers.onConnectHandler?(nil)
        }
        
        self.connectionStartTime = Date()
        connectionTimer.run {
            Logger.error(type: .mediaChannel, message: "connection timeout")
            self.disconnect(error: SoraError.connectionTimeout)
        }
    }

    /**
     接続を解除します。
     
     - parameter error: 接続解除の原因となったエラー
     */
    public func disconnect(error: Error?) {
        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .mediaChannel, message: "try disconnecting")
            if let error = error {
                Logger.error(type: .mediaChannel,
                             message: "error: \(error.localizedDescription)")
            }
            
            state = .disconnecting
            connectionTimer.stop()
            peerChannel.disconnect(error: error)
            Logger.debug(type: .mediaChannel, message: "did disconnect")
            state = .disconnected
            
            Logger.debug(type: .mediaChannel, message: "call onDisconnectHandler")
            internalHandlers.onDisconnectHandler?(error)
            handlers.onDisconnectHandler?(error)
        }
    }
    
}

extension MediaChannel: CustomStringConvertible {
    
    /// :nodoc:
    public var description: String {
        get {
            return "MediaChannel(clientId: \(clientId ?? "-"), role: \(configuration.role))"
        }
    }
    
}

/// :nodoc:
extension MediaChannel: Equatable {
    
    public static func ==(lhs: MediaChannel, rhs: MediaChannel) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    
}
