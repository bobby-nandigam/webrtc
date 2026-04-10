import 'dart:convert';
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

  late TextEditingController _remoteUserIdController;

  @override
  void initState() {
    super.initState();
    // Generate unique user ID
    _userId = 'user_${Random().nextInt(100000)}';
    _remoteUserIdController = TextEditingController();
    requestPermissions();
    initRenderers();
    connectSocket();
    start();
  }

  Future<void> requestPermissions() async {
    await [Permission.camera, Permission.microphone].request();
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
    channel.sink.add(jsonEncode({
      'type': 'join',
      'id': _userId,
    }));

    channel.stream.listen((message) async {
      var data = jsonDecode(message);

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
    });
  }

  Future<void> start() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true,
    });

    _localRenderer.srcObject = _localStream;

    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _peerConnection!.onTrack = (event) {
      _remoteRenderer.srcObject = event.streams[0];
    };

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate != null && _remoteUserId != null) {
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
  }

  Future<void> createOffer() async {
    if (_remoteUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter remote user ID first')),
      );
      return;
    }

    var offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    channel.sink.add(jsonEncode({
      'type': 'offer',
      'from': _userId,
      'to': _remoteUserId,
      'sdp': offer.sdp
    }));
    
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

    channel.sink.add(jsonEncode({
      'type': 'answer',
      'from': _userId,
      'to': _remoteUserId,
      'sdp': answer.sdp,
    }));

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

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection?.dispose();
    channel.sink.close();
    _remoteUserIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Free Video Call")),
      body: Column(
        children: [
          // User ID Info
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Text("Your ID: $_userId", style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (!_inCall)
                  TextField(
                    controller: _remoteUserIdController,
                    decoration: InputDecoration(
                      hintText: 'Enter remote user ID',
                      border: OutlineInputBorder(),
                      suffix: IconButton(
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
              ],
            ),
          ),
          // Video Views
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
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
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
