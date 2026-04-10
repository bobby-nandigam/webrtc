import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: VideoCallPage());
  }
}

class VideoCallPage extends StatefulWidget {
  const VideoCallPage({super.key});

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  late WebSocketChannel channel;

  // User IDs
  late String _userId;
  String? _remoteUserId;

  // Call state flags
  bool _inCall = false;
  bool _incomingCall = false;
  String? _incomingOffer;

  // Connection status
  String _connectionStatus = "Connecting...";
  String _iceConnectionStatus = "Gathering...";
  
  // Keep-alive timer
  Timer? _keepAliveTimer;
  
  // Active users list
  List<String> _activeUsers = [];

  late TextEditingController _remoteUserIdController;

  @override
  void initState() {
    super.initState();
    _userId = 'user_${Random().nextInt(100000)}';
    _remoteUserIdController = TextEditingController();
    _initializeApp();
  }

  void _initializeApp() {
    requestPermissions().then((_) {
      initRenderers().then((_) {
        connectSocket();
        start();
      });
    });
  }

  Future<void> initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  void connectSocket() {
    channel = WebSocketChannel.connect(
      Uri.parse('wss://webrtc-server-mb4o.onrender.com'),
    );

    // Send join message
    channel.sink.add(jsonEncode({'type': 'join', 'id': _userId}));
    
    // Start keep-alive ping (every 20 seconds to prevent timeout)
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(Duration(seconds: 20), (_) {
      try {
        channel.sink.add(jsonEncode({'type': 'ping'}));
        print('💓 Keep-alive ping sent');
      } catch (e) {
        print('⚠️ Failed to send ping: $e');
      }
    });

    channel.stream.listen((message) async {
      var data = jsonDecode(message);

      // Handle active users list from server
      if (data['type'] == 'users_list') {
        setState(() {
          _activeUsers = List<String>.from(data['users'] ?? []);
        });
        print('📋 Active users: ${_activeUsers.join(', ') == '' ? 'none' : _activeUsers.join(', ')}');
        return;
      }
      
      // Handle new user joined
      if (data['type'] == 'user_joined') {
        setState(() {
          _activeUsers = List<String>.from(data['activeUsers'] ?? []);
        });
        print('✅ New user joined: ${data['userId']} | Active: ${_activeUsers.join(', ')}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ ${data['userId']} is now online')),
        );
        return;
      }
      
      // Handle user left
      if (data['type'] == 'user_left') {
        setState(() {
          _activeUsers = List<String>.from(data['activeUsers'] ?? []);
        });
        print('❌ User left: ${data['userId']} | Active: ${_activeUsers.join(', ')}');
        if (_remoteUserId == data['userId']) {
          _remoteUserIdController.clear();
          _remoteUserId = null;
        }
        return;
      }

      // Track remote user
      if (data['from'] != null && _remoteUserId == null) {
        _remoteUserId = data['from'];
      }

      if (data['type'] == 'offer') {
        setState(() {
          _incomingCall = true;
          _incomingOffer = data['sdp'];
        });
        _showIncomingCallDialog(data['sdp']);
      }

      if (data['type'] == 'answer') {
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(data['sdp'], 'answer'),
        );
      }

      if (data['type'] == 'candidate') {
        _peerConnection!.addCandidate(
          RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          ),
        );
      }

      if (data['type'] == 'ice_restart') {
        print('📨 Received ICE_RESTART from ${data['from']}');
        if (_peerConnection != null) {
          try {
            await _peerConnection!.restartIce();
            print('🔄 ICE restart acknowledged and processed');
          } catch (e) {
            print('❌ Error restarting ICE: $e');
          }
        }
      }
    });
  }

  Future<void> start() async {
    // Step 1: Get local stream
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true,
    });

    print('✅ Local stream acquired: ${_localStream!.id}');
    print('🎬 Video tracks: ${_localStream!.getVideoTracks().length}');
    print('🎤 Audio tracks: ${_localStream!.getAudioTracks().length}');

    // Step 2: Set local renderer immediately
    setState(() {
      _localRenderer.srcObject = _localStream;
    });
    print('✅ Local renderer set with stream');

    // Step 3: Create peer connection with multiple STUN + TURN servers
    _peerConnection = await createPeerConnection({
      'iceServers': [
        // Google STUN servers
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {'urls': 'stun:stun3.l.google.com:19302'},
        // Primary TURN (OpenRelay)
        {
          'urls': ['turn:openrelay.metered.ca:80', 'turn:openrelay.metered.ca:443'],
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        // Backup TURN (Twillio - public test account)
        {
          'urls': 'turn:numb.viagenie.ca',
          'username': 'webrtc@example.com',
          'credential': 'webrtccredential',
        },
      ],
    });
    print('✅ Peer connection created with multi-server ICE config');

    // Step 4: Setup handlers BEFORE adding tracks
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      print('🎥 onTrack fired! Track kind: ${event.track.kind}');
      print('📊 Streams available: ${event.streams.length}');

      if (event.streams.isNotEmpty) {
        print('✅ Setting remote stream: ${event.streams[0].id}');
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
        });
        print('✅ Remote renderer updated');
      } else {
        print('❌ No streams in event');
      }
    };

    // Connection state handlers
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      print('🔗 Connection State: $state');
      setState(() {
        _connectionStatus = state.toString().split('.').last;
      });

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        print('✅ PEER CONNECTION ESTABLISHED!');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Connected! Video stream ready'),
            duration: Duration(seconds: 2),
          ),
        );
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        print('❌ PEER CONNECTION FAILED! Attempting ICE restart...');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Connection failed - retrying with different route...'),
            duration: Duration(seconds: 3),
          ),
        );

        // Attempt ICE restart with delay
        if (_remoteUserId != null && _peerConnection != null) {
          await Future.delayed(Duration(seconds: 2));
          try {
            _peerConnection!.restartIce();
            print('🔄 ICE restart initiated');
            
            // Send ICE_RESTART signal to remote peer
            channel.sink.add(
              jsonEncode({
                'type': 'ice_restart',
                'from': _userId,
                'to': _remoteUserId,
              }),
            );
            print('📨 Sent ICE_RESTART to $_remoteUserId');
          } catch (e) {
            print('❌ ICE restart failed: $e');
            
            // If restart fails, offer to reconnect
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Connection error. Try ending call and retrying.'),
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'End Call',
                  onPressed: () {
                    setState(() => _inCall = false);
                    _peerConnection?.close();
                  },
                ),
              ),
            );
          }
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        print('❌ PEER CONNECTION CLOSED');
        setState(() {
          _inCall = false;
        });
      }
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      String stateStr = state.toString().split('.').last;
      print('🧊 ICE Connection State: $stateStr');
      setState(() {
        _iceConnectionStatus = stateStr;
      });
      
      // Log state transitions for debugging
      if (stateStr.contains('Connected')) {
        print('✅ ICE Connected - media should flow');
      } else if (stateStr.contains('Failed')) {
        print('❌ ICE Failed - checking alternate candidates');
      } else if (stateStr.contains('Disconnected')) {
        print('⚠️ ICE Disconnected - may recover');
      } else if (stateStr.contains('Closed')) {
        print('❌ ICE Closed - connection ended');
      }
    };

    _peerConnection!.onSignalingState = (RTCSignalingState state) {
      print('📡 Signaling State: $state');
    };

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      print('🌍 ICE Gathering State: $state');
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
      if (candidate != null && _remoteUserId != null) {
        print('🧊 ICE candidate: ${candidate.candidate}');
        channel.sink.add(
          jsonEncode({
            'type': 'candidate',
            'from': _userId,
            'to': _remoteUserId,
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }),
        );
      }
    };

    // Step 5: Add local tracks to peer connection
    print(
      '📤 Adding ${_localStream!.getTracks().length} tracks to peer connection',
    );
    _localStream!.getTracks().forEach((track) {
      print('➕ Adding track: ${track.kind} (${track.id})');
      _peerConnection!.addTrack(track, _localStream!);
    });
    print('✅ All tracks added to peer connection');
  }

  Future<void> createOffer() async {
    // Validate target user
    if (_remoteUserId == null || _remoteUserId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid target user ID')),
      );
      print('Invalid target user');
      return;
    }
    
    // Prevent self-calls
    if (_remoteUserId == _userId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot call yourself')),
      );
      print('Cannot call yourself');
      return;
    }

    var offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    channel.sink.add(
      jsonEncode({
        'type': 'offer',
        'from': _userId,
        'to': _remoteUserId,
        'sdp': offer.sdp,
      }),
    );

    setState(() => _inCall = true);
  }

  void _showIncomingCallDialog(String offerSdp) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Incoming Call"),
        content: const Text("Someone is calling you..."),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _rejectCall();
            },
            child: const Text("Reject"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _acceptCall(offerSdp);
            },
            child: const Text("Accept"),
          ),
        ],
      ),
    );
  }

  Future<void> _acceptCall(String offerSdp) async {
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, 'offer'),
    );

    var answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    channel.sink.add(
      jsonEncode({
        'type': 'answer',
        'from': _userId,
        'to': _remoteUserId,
        'sdp': answer.sdp,
      }),
    );

    setState(() {
      _inCall = true;
    });
  }

  void _rejectCall() {
    setState(() {
      _incomingCall = false;
      _incomingOffer = null;
    });
  }

  Future<void> requestPermissions() async {
    try {
      await Permission.camera.request();
      await Permission.microphone.request();
      print('✅ Permission requests completed');
    } catch (e) {
      print('❌ Permission error: $e');
    }
  }

  @override
  void dispose() {
    // Cancel keep-alive timer
    _keepAliveTimer?.cancel();
    print('⏹️ Keep-alive timer cancelled');
    
    // Close peer connection properly
    if (_peerConnection != null) {
      _peerConnection!.close();
      _peerConnection = null;
      print('🔌 Peer connection closed');
    }
    
    // Clean up renderers
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    
    // Close WebSocket
    try {
      channel.sink.close();
    } catch (e) {
      print('⚠️ Error closing channel: $e');
    }
    
    _remoteUserIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Free Video Call")),
      body: Column(
        children: [
          // User ID Info - Compact
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Your ID: $_userId",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // Connection Status
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Status: $_connectionStatus | ICE: $_iceConnectionStatus",
                        style: TextStyle(
                          fontSize: 10,
                          color: _connectionStatus.contains('connected')
                              ? Colors.green
                              : Colors.orange,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Active Users List
                if (!_inCall && _activeUsers.isNotEmpty)
                  SizedBox(
                    height: 32,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _activeUsers.length,
                      itemBuilder: (context, index) {
                        final userId = _activeUsers[index];
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: GestureDetector(
                            onTap: () {
                              _remoteUserIdController.text = userId;
                              setState(() => _remoteUserId = userId);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('✅ Selected: $userId'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: _remoteUserId == userId
                                    ? Colors.blue
                                    : Colors.grey[300],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Center(
                                child: Text(
                                  userId,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _remoteUserId == userId
                                        ? Colors.white
                                        : Colors.black,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 4),
                if (!_inCall)
                  SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _remoteUserIdController,
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        hintText: 'Enter remote user ID',
                        hintStyle: const TextStyle(fontSize: 12),
                        border: OutlineInputBorder(),
                        suffix: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          icon: const Icon(Icons.clear),
                          onPressed: () => _remoteUserIdController.clear(),
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _remoteUserId = value.isEmpty ? null : value;
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
          // Video Views - Big
          Expanded(child: RTCVideoView(_localRenderer, mirror: true)),
          Expanded(child: RTCVideoView(_remoteRenderer)),
          // Call Buttons
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (!_inCall)
                  ElevatedButton(
                    onPressed: createOffer,
                    child: const Text("Start Call"),
                  ),
                if (_inCall)
                  ElevatedButton(
                    onPressed: () {
                      setState(() => _inCall = false);
                      _peerConnection?.close();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                    child: const Text("End Call"),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
