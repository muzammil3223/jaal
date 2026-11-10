import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nearby_connections/nearby_connections.dart' as nc;
import 'package:nsd/nsd.dart' as nsd;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const svc = 'com.jaal.mesh';
const cs = 16384; // file chunk size (bytes)
final _rnd = Random();
String _rid() => _rnd.nextInt(1 << 32).toRadixString(36) + _rnd.nextInt(1 << 32).toRadixString(36);
late String myId;
late Settings settings;
String get myName => settings.name;

// ---------------- zubaan (English / Urdu) ----------------
const _t = <String, Map<String, String>>{
  'en': {
    'title': 'Jaal', 'jure': 'connected', 'hint': 'Type a message', 'settings': 'Settings',
    'theme': 'Theme', 'light': 'Light', 'dark': 'Dark', 'auto': 'Auto', 'color': 'Colour',
    'textsize': 'Text size', 'bubble': 'Message style', 'round': 'Round', 'square': 'Square',
    'flat': 'Flat', 'compact': 'Compact layout', 'lang': 'Language', 'awake': 'Keep screen on',
    'name': 'Your name', 'range': 'Range test', 'inVoice': 'Voice call incoming',
    'inVideo': 'Video call incoming', 'hops': 'hops away', 'direct': 'direct',
    'searching': 'Looking for people nearby...', 'joined': 'joined', 'left': 'left',
    'voice': 'Voice message', 'strong': 'Strong', 'medium': 'Medium', 'weak': 'Weak',
    'refresh': 'Refresh', 'close': 'Close', 'wifi': 'WiFi/hotspot', 'bt': 'Bluetooth',
    'tip': 'Best range: stay within about 20 m (calls) or 50 m (chat). More phones in between extend the range.',
    'noPeers': 'Nobody connected yet',
  },
  'ur': {
    'title': 'جال', 'jure': 'جڑے ہوئے', 'hint': 'پیغام لکھیں', 'settings': 'ترتیبات',
    'theme': 'تھیم', 'light': 'روشن', 'dark': 'تاریک', 'auto': 'خودکار', 'color': 'رنگ',
    'textsize': 'تحریر کا سائز', 'bubble': 'پیغام کا انداز', 'round': 'گول', 'square': 'چوکور',
    'flat': 'سادہ', 'compact': 'مختصر ترتیب', 'lang': 'زبان', 'awake': 'اسکرین آن رکھیں',
    'name': 'آپ کا نام', 'range': 'رینج ٹیسٹ', 'inVoice': 'وائس کال آ رہی ہے',
    'inVideo': 'ویڈیو کال آ رہی ہے', 'hops': 'ہاپ دور', 'direct': 'براہِ راست',
    'searching': 'آس پاس کے لوگ ڈھونڈ رہا ہے...', 'joined': 'جُڑ گیا', 'left': 'الگ ہو گیا',
    'voice': 'وائس میسج', 'strong': 'مضبوط', 'medium': 'درمیانی', 'weak': 'کمزور',
    'refresh': 'تازہ کریں', 'close': 'بند کریں', 'wifi': 'وائی فائی/ہاٹ اسپاٹ', 'bt': 'بلوٹوتھ',
    'tip': 'بہترین رینج: کال کے لیے تقریباً 20 میٹر اور چیٹ کے لیے 50 میٹر کے اندر رہیں۔ درمیان میں مزید فون ہوں تو رینج بڑھ جاتی ہے۔',
    'noPeers': 'ابھی کوئی جڑا نہیں',
  },
};
String tr(String k) => _t[settings.lang]?[k] ?? _t['en']![k] ?? k;

// ---------------- settings (yaad rakhi jati hain) ----------------
const seeds = [0xFF0B7A66, 0xFF1565C0, 0xFF8E24AA, 0xFFEF6C00, 0xFFC62828, 0xFF37474F];

class Settings extends ChangeNotifier {
  final SharedPreferences p;
  int themeMode, colorIdx, bubble;
  double textScale;
  bool compact, keepAwake;
  String lang, name;
  Settings(this.p)
      : themeMode = p.getInt('theme') ?? 0,
        colorIdx = p.getInt('color') ?? 0,
        bubble = p.getInt('bubble') ?? 0,
        textScale = p.getDouble('scale') ?? 1.0,
        compact = p.getBool('compact') ?? false,
        keepAwake = p.getBool('awake') ?? false,
        lang = p.getString('lang') ?? 'en',
        name = p.getString('name') ?? 'User-${myId.substring(0, 3)}' {
    _awake();
  }
  void _awake() {
    if (keepAwake) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  void save() {
    p.setInt('theme', themeMode);
    p.setInt('color', colorIdx);
    p.setInt('bubble', bubble);
    p.setDouble('scale', textScale);
    p.setBool('compact', compact);
    p.setBool('awake', keepAwake);
    p.setString('lang', lang);
    p.setString('name', name);
    _awake();
    notifyListeners();
  }
}

// ---------------- mesh engine ----------------
class Link {
  String? id;
  String name = '?';
  final String kind; // 'wifi' ya 'bt'
  int? rtt; // ms
  final void Function(String) send;
  final void Function() close;
  Link(this.send, this.close, this.kind);
}

class PeerInfo {
  String name;
  int hops;
  DateTime seen;
  PeerInfo(this.name, this.hops, this.seen);
}

class Msg {
  final String from, text;
  final String? path;
  final bool mine, voice, sys;
  Msg(this.from, this.text, {this.path, this.mine = false, this.voice = false, this.sys = false});
}

class Incoming {
  final String from, name, path;
  final int n;
  final bool voice;
  final RandomAccessFile raf;
  int got = 0;
  Future<void> chain = Future.value();
  Incoming(this.from, this.name, this.n, this.voice, this.raf, this.path);
}

class Mesh extends ChangeNotifier {
  final links = <Link>[];
  final msgs = <Msg>[];
  final seen = <String>{};
  final inc = <String, Incoming>{};
  final stash = <String, List<Map>>{};
  final dialing = <String>{};
  final nl = <String, Link>{};
  final peers = <String, PeerInfo>{};
  final store = <String>[]; // store-and-forward: purane chat paigham
  int _seq = 0;
  // call state
  final localR = RTCVideoRenderer();
  final remoteR = RTCVideoRenderer();
  RTCPeerConnection? pc;
  MediaStream? stream;
  String? peer;
  Map? offer;
  bool inCall = false;
  final early = <Map>[];

  void _sys(String t) {
    msgs.add(Msg('', t, sys: true));
    notifyListeners();
  }

  void _loadStore() {
    for (final s in settings.p.getStringList('store') ?? <String>[]) {
      try {
        final m = jsonDecode(s) as Map;
        store.add(s);
        seen.add(m['id']);
        msgs.add(Msg(m['from'], m['text'], mine: m['from'] == myName));
      } catch (_) {}
    }
  }

  void _remember(String s) {
    store.add(s);
    if (store.length > 300) store.removeAt(0);
    settings.p.setStringList('store', store);
  }

  Future<void> start() async {
    _loadStore();
    if (Platform.isAndroid) {
      await [
        Permission.location,
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.nearbyWifiDevices,
        Permission.microphone,
        Permission.camera,
        Permission.ignoreBatteryOptimizations, // background mein app ko band hone se bachata hai
      ].request();
    }
    await localR.initialize();
    await remoteR.initialize();
    try {
      await _startLan();
    } catch (e) {
      _sys('WiFi/hotspot error: $e');
    }
    if (Platform.isAndroid) {
      try {
        await _startNearby();
      } catch (e) {
        _sys('Bluetooth error: $e');
      }
    }
    _sys(tr('searching'));
    Timer.periodic(const Duration(seconds: 10), (_) {
      _announce();
      pingAll();
      final now = DateTime.now();
      peers.removeWhere((k, v) => now.difference(v.seen).inSeconds > 40);
      notifyListeners();
    });
    _announce();
  }

  // ---------- hop count + range test ----------
  void _announce() {
    final q = _seq++;
    seen.add('a:$myId:$q');
    _flood(jsonEncode({'t': 'ann', 'id': myId, 'name': myName, 'h': 0, 'q': q}), null);
  }

  void pingAll() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final l in List.of(links)) {
      l.send(jsonEncode({'t': 'ping', 'n': now}));
    }
  }

  // ---------- links ----------
  void _addLink(Link l) {
    links.add(l);
    l.send(jsonEncode({'t': 'hi', 'id': myId, 'name': myName}));
    _announce();
  }

  void _dropLink(Link l) {
    if (!links.remove(l)) return;
    if (l.id != null) {
      dialing.remove(l.id);
      _sys('${l.name} ${tr('left')}');
    }
    notifyListeners();
  }

  void _flood(String s, Link? except) {
    for (final l in List.of(links)) {
      if (l != except) l.send(s);
    }
  }

  void _recv(Link l, String s) {
    Map m;
    try {
      m = jsonDecode(s) as Map;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'hi':
        l.id = m['id'];
        l.name = m['name'];
        _sys('${l.name} ${tr('joined')}');
        for (final x in List.of(store)) {
          l.send(x); // store-and-forward: naye bande ko purane paigham do
        }
        break;
      case 'ping':
        l.send(jsonEncode({'t': 'pong', 'n': m['n']}));
        break;
      case 'pong':
        l.rtt = DateTime.now().millisecondsSinceEpoch - (m['n'] as int);
        break;
      case 'ann':
        if (m['id'] != myId && seen.add('a:${m['id']}:${m['q']}')) {
          final h = (m['h'] as int) + 1;
          peers[m['id']] = PeerInfo(m['name'], h, DateTime.now());
          m['h'] = h;
          _flood(jsonEncode(m), l);
        }
        break;
      case 'c':
        if (seen.add(m['id'])) {
          msgs.add(Msg(m['from'], m['text']));
          _remember(s);
          _flood(s, l);
        }
        break;
      case 'fm':
        if (seen.add(m['id'])) {
          _flood(s, l);
          _openIncoming(m);
        }
        break;
      case 'fc':
        if (seen.add('${m['f']}:${m['i']}')) {
          _flood(s, l);
          _chunk(m);
        }
        break;
      case 'sig':
        if (seen.add(m['id'])) {
          if (m['to'] == myId) {
            _onSig(m);
          } else {
            _flood(s, l);
          }
        }
        break;
    }
    notifyListeners();
  }

  // ---------- LAN (WiFi / hotspot) : iOS, Android, desktop ----------
  Future<void> _startLan() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        _addWs(await WebSocketTransformer.upgrade(req));
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
    await nsd.register(nsd.Service(name: 'jaal-$myId', type: '_jaal._tcp', port: server.port));
    final d = await nsd.startDiscovery('_jaal._tcp', ipLookupType: nsd.IpLookupType.v4);
    d.addServiceListener((s, status) async {
      if (status != nsd.ServiceStatus.found) return;
      final pid = (s.name ?? '').replaceFirst('jaal-', '');
      if (pid.isEmpty || myId.compareTo(pid) >= 0 || dialing.contains(pid)) return;
      final host = (s.addresses?.isNotEmpty ?? false) ? s.addresses!.first.address : s.host;
      if (host == null || s.port == null) return;
      dialing.add(pid);
      try {
        final ws = await WebSocket.connect('ws://$host:${s.port}').timeout(const Duration(seconds: 6));
        _addWs(ws);
      } catch (_) {
        dialing.remove(pid);
      }
    });
  }

  void _addWs(WebSocket ws) {
    final l = Link((s) => ws.add(s), () => ws.close(), 'wifi');
    _addLink(l);
    ws.listen((d) {
      if (d is String) _recv(l, d);
    }, onDone: () => _dropLink(l), onError: (_) => _dropLink(l));
  }

  // ---------- Nearby (Bluetooth + WiFi Direct) : Android ----------
  Future<void> _startNearby() async {
    final n = nc.Nearby();
    const st = nc.Strategy.P2P_CLUSTER;
    final nm = '$myName|$myId';
    await n.startAdvertising(nm, st,
        onConnectionInitiated: _nInit, onConnectionResult: _nRes, onDisconnected: _nGone, serviceId: svc);
    await n.startDiscovery(nm, st, onEndpointFound: (id, name, s) {
      if (myId.compareTo(name.split('|').last) < 0) {
        n.requestConnection(nm, id,
            onConnectionInitiated: _nInit, onConnectionResult: _nRes, onDisconnected: _nGone);
      }
    }, onEndpointLost: (id) {}, serviceId: svc);
  }

  void _nInit(String id, nc.ConnectionInfo info) {
    nl[id] = Link((s) => nc.Nearby().sendBytesPayload(id, Uint8List.fromList(utf8.encode(s))),
        () => nc.Nearby().disconnectFromEndpoint(id), 'bt');
    nc.Nearby().acceptConnection(id, onPayLoadRecieved: (eid, p) {
      final l = nl[eid];
      if (l != null && p.type == nc.PayloadType.BYTES && p.bytes != null) {
        _recv(l, utf8.decode(p.bytes!));
      }
    }, onPayloadTransferUpdate: (a, b) {});
  }

  void _nRes(String id, nc.Status s) {
    final l = nl[id];
    if (s == nc.Status.CONNECTED && l != null) {
      _addLink(l);
      notifyListeners();
    } else {
      nl.remove(id);
    }
  }

  void _nGone(String id) {
    final l = nl.remove(id);
    if (l != null) _dropLink(l);
  }

  // ---------- chat ----------
  void sendText(String t) {
    final m = {'t': 'c', 'id': _rid(), 'from': myName, 'text': t};
    final s = jsonEncode(m);
    seen.add(m['id']!);
    msgs.add(Msg('Aap', t, mine: true));
    _remember(s);
    _flood(s, null);
    notifyListeners();
  }

  // ---------- files / voice messages ----------
  Future<void> sendFile(String path, String name, {bool voice = false}) async {
    final f = File(path);
    final len = await f.length();
    if (len == 0) return;
    final n = (len / cs).ceil();
    final id = _rid();
    seen.add(id);
    msgs.add(Msg('Aap', name, path: path, mine: true, voice: voice));
    notifyListeners();
    _flood(jsonEncode({'t': 'fm', 'id': id, 'from': myName, 'name': name, 'n': n, 'voice': voice}), null);
    final raf = await f.open();
    for (var i = 0; i < n; i++) {
      final b = await raf.read(cs);
      seen.add('$id:$i');
      _flood(jsonEncode({'t': 'fc', 'f': id, 'i': i, 'd': base64Encode(b)}), null);
      if (i % 8 == 7) await Future.delayed(const Duration(milliseconds: 10));
    }
    await raf.close();
  }

  Future<void> _openIncoming(Map m) async {
    final dir = await getApplicationDocumentsDirectory();
    final safe = (m['name'] as String).replaceAll(RegExp(r'[^\w.\- ]'), '_');
    final path = '${dir.path}/${m['id']}_$safe';
    final raf = await File(path).open(mode: FileMode.write);
    inc[m['id']] = Incoming(m['from'], m['name'], m['n'], m['voice'] == true, raf, path);
    for (final c in stash.remove(m['id']) ?? <Map>[]) {
      _chunk(c);
    }
  }

  void _chunk(Map m) {
    final x = inc[m['f']];
    if (x == null) {
      stash.putIfAbsent(m['f'], () => <Map>[]).add(m);
      return;
    }
    x.chain = x.chain.then((_) async {
      await x.raf.setPosition((m['i'] as int) * cs);
      await x.raf.writeFrom(base64Decode(m['d']));
      if (++x.got == x.n) {
        await x.raf.close();
        inc.remove(m['f']);
        msgs.add(Msg(x.from, x.name, path: x.path, voice: x.voice));
        notifyListeners();
      }
    });
  }

  // ---------- live voice / video call (WebRTC) ----------
  void _sig(String to, Map<String, dynamic> d) {
    final m = {'t': 'sig', 'id': _rid(), 'to': to, 'from': myId, ...d};
    seen.add(m['id'] as String);
    _flood(jsonEncode(m), null);
  }

  RTCIceCandidate _cand(Map c) => RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']);

  Future<void> _prepare(String to, bool video) async {
    peer = to;
    stream = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': video ? {'facingMode': 'user'} : false});
    pc = await createPeerConnection({'iceServers': <Map<String, dynamic>>[], 'sdpSemantics': 'unified-plan'});
    for (final t in stream!.getTracks()) {
      await pc!.addTrack(t, stream!);
    }
    pc!.onTrack = (e) {
      if (e.streams.isNotEmpty) {
        remoteR.srcObject = e.streams[0];
        notifyListeners();
      }
    };
    pc!.onIceCandidate = (c) => _sig(to, {'k': 'ice', 'c': c.toMap()});
    localR.srcObject = stream;
    inCall = true;
    notifyListeners();
  }

  Future<void> call(String to, bool video) async {
    if (inCall) return;
    try {
      await _prepare(to, video);
      final o = await pc!.createOffer();
      await pc!.setLocalDescription(o);
      _sig(to, {'k': 'offer', 'sdp': o.sdp, 'ty': o.type, 'video': video});
    } catch (e) {
      _sys('Call error: $e');
      await _end();
    }
  }

  Future<void> accept() async {
    final o = offer;
    if (o == null) return;
    offer = null;
    try {
      await _prepare(o['from'], o['video'] == true);
      await pc!.setRemoteDescription(RTCSessionDescription(o['sdp'], o['ty']));
      await _flushIce();
      final a = await pc!.createAnswer();
      await pc!.setLocalDescription(a);
      _sig(o['from'], {'k': 'answer', 'sdp': a.sdp, 'ty': a.type});
    } catch (e) {
      _sys('Call error: $e');
      await _end();
    }
  }

  void reject() {
    if (offer != null) _sig(offer!['from'], {'k': 'bye'});
    offer = null;
    notifyListeners();
  }

  Future<void> hangup() async {
    if (peer != null) _sig(peer!, {'k': 'bye'});
    await _end();
  }

  Future<void> _flushIce() async {
    for (final c in List.of(early)) {
      await pc!.addCandidate(_cand(c));
    }
    early.clear();
  }

  Future<void> _end() async {
    await pc?.close();
    pc = null;
    for (final t in stream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await stream?.dispose();
    stream = null;
    localR.srcObject = null;
    remoteR.srcObject = null;
    peer = null;
    inCall = false;
    early.clear();
    notifyListeners();
  }

  Future<void> _onSig(Map m) async {
    switch (m['k']) {
      case 'offer':
        if (inCall || offer != null) {
          _sig(m['from'], {'k': 'bye'});
        } else {
          offer = m;
        }
        break;
      case 'answer':
        await pc?.setRemoteDescription(RTCSessionDescription(m['sdp'], m['ty']));
        await _flushIce();
        break;
      case 'ice':
        if (pc != null && await pc!.getRemoteDescription() != null) {
          await pc!.addCandidate(_cand(m['c']));
        } else {
          early.add(m['c']);
        }
        break;
      case 'bye':
        if (offer?['from'] == m['from']) offer = null;
        if (peer == m['from']) await _end();
        break;
    }
    notifyListeners();
  }
}

// ---------------- UI ----------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  var id = p.getString('id');
  if (id == null) {
    id = _rid().substring(0, 6);
    await p.setString('id', id);
  }
  myId = id;
  settings = Settings(p);
  runApp(const JaalApp());
}

class JaalApp extends StatelessWidget {
  const JaalApp({super.key});
  @override
  Widget build(BuildContext c) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final seed = Color(seeds[settings.colorIdx]);
        return MaterialApp(
          title: 'Jaal',
          debugShowCheckedModeBanner: false,
          themeMode: [ThemeMode.system, ThemeMode.light, ThemeMode.dark][settings.themeMode],
          theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
          darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
          builder: (ctx, child) => Directionality(
            textDirection: settings.lang == 'ur' ? TextDirection.rtl : TextDirection.ltr,
            child: MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(settings.textScale)),
              child: child!,
            ),
          ),
          home: const ChatPage(),
        );
      },
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final mesh = Mesh();
  final input = TextEditingController();
  final rec = AudioRecorder();
  final player = AudioPlayer();
  final scroll = ScrollController();
  bool recording = false;

  @override
  void initState() {
    super.initState();
    mesh.start();
    mesh.addListener(() {
      if (scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
        });
      }
    });
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      nc.Nearby().stopAdvertising();
      nc.Nearby().stopDiscovery();
      nc.Nearby().stopAllEndpoints();
    }
    rec.dispose();
    player.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null) return;
    for (final f in r.files) {
      if (f.path != null) await mesh.sendFile(f.path!, f.name);
    }
  }

  Future<void> _toggleRec() async {
    if (!recording) {
      if (!await rec.hasPermission()) return;
      final dir = await getTemporaryDirectory();
      await rec.start(const RecordConfig(), path: '${dir.path}/v_${DateTime.now().millisecondsSinceEpoch}.m4a');
      setState(() => recording = true);
    } else {
      final p = await rec.stop();
      setState(() => recording = false);
      if (p != null) await mesh.sendFile(p, 'voice.m4a', voice: true);
    }
  }

  void _send() {
    final t = input.text.trim();
    if (t.isEmpty) return;
    input.clear();
    mesh.sendText(t);
  }

  bool _isImage(String p) => RegExp(r'\.(jpe?g|png|gif|webp)$', caseSensitive: false).hasMatch(p);

  Widget _bubble(Msg m) {
    final c = Theme.of(context);
    if (m.sys) return Center(child: Text(m.text, style: c.textTheme.bodySmall));
    Widget body;
    if (m.voice && m.path != null) {
      body = TextButton.icon(
          onPressed: () => player.play(DeviceFileSource(m.path!)),
          icon: const Icon(Icons.play_arrow),
          label: Text(tr('voice')));
    } else if (m.path != null && _isImage(m.path!)) {
      body = ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: Image.file(File(m.path!)));
    } else if (m.path != null) {
      body = Text('${m.text}\n(${m.path})');
    } else {
      body = Text(m.text);
    }
    final radius = [16.0, 2.0, 8.0][settings.bubble];
    final pad = settings.compact ? 6.0 : 10.0;
    final fill = m.mine ? c.colorScheme.primaryContainer : c.colorScheme.surfaceContainerHighest;
    return Align(
      alignment: m.mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: settings.compact ? 2 : 4),
        padding: EdgeInsets.all(pad),
        decoration: BoxDecoration(
          color: settings.bubble == 2 ? null : fill,
          border: settings.bubble == 2 ? Border.all(color: c.colorScheme.outlineVariant) : null,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.from, style: c.textTheme.labelSmall),
          body,
        ]),
      ),
    );
  }

  IconData _signal(int? rtt) =>
      rtt == null ? Icons.signal_cellular_null : (rtt < 60 ? Icons.signal_cellular_alt : (rtt < 250 ? Icons.signal_cellular_alt_2_bar : Icons.signal_cellular_alt_1_bar));

  String _quality(int? rtt) => rtt == null ? '-' : (rtt < 60 ? tr('strong') : (rtt < 250 ? tr('medium') : tr('weak')));

  void _rangeDialog() {
    mesh.pingAll();
    showDialog(
      context: context,
      builder: (_) => ListenableBuilder(
        listenable: mesh,
        builder: (ctx, _) => AlertDialog(
          title: Text(tr('range')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (mesh.links.isEmpty) Text(tr('noPeers')),
              for (final l in mesh.links)
                ListTile(
                  dense: true,
                  leading: Icon(_signal(l.rtt)),
                  title: Text(l.name),
                  subtitle: Text('${tr(l.kind)} · ${l.rtt ?? '-'} ms · ${_quality(l.rtt)}'),
                ),
              const Divider(),
              Text(tr('tip'), style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: mesh.pingAll, child: Text(tr('refresh'))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('close'))),
          ],
        ),
      ),
    );
  }

  Widget _peerBar() {
    final entries = <Widget>[];
    final direct = <String, Link>{for (final l in mesh.links) if (l.id != null) l.id!: l};
    final all = <String, PeerInfo>{
      for (final e in mesh.peers.entries) e.key: e.value,
      for (final e in direct.entries) e.key: PeerInfo(e.value.name, 1, DateTime.now()),
    };
    final ids = all.keys.toList()..sort((a, b) => all[a]!.hops.compareTo(all[b]!.hops));
    for (final id in ids) {
      final info = all[id]!;
      final dl = direct[id];
      entries.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          if (dl != null) Icon(_signal(dl.rtt), size: 18),
          const SizedBox(width: 4),
          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(info.name),
            Text(dl != null ? tr('direct') : '${info.hops} ${tr('hops')}',
                style: Theme.of(context).textTheme.labelSmall),
          ]),
          if (dl != null) ...[
            IconButton(onPressed: () => mesh.call(id, false), icon: const Icon(Icons.call)),
            IconButton(onPressed: () => mesh.call(id, true), icon: const Icon(Icons.videocam)),
          ],
        ]),
      ));
    }
    return entries.isEmpty
        ? const SizedBox.shrink()
        : SizedBox(height: 56, child: ListView(scrollDirection: Axis.horizontal, children: entries));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([mesh, settings]),
      builder: (context, _) {
        final count = mesh.peers.length > mesh.links.length ? mesh.peers.length : mesh.links.length;
        return Scaffold(
          appBar: AppBar(
            title: Text('${tr('title')}  ($count ${tr('jure')})'),
            actions: [
              IconButton(tooltip: tr('range'), onPressed: _rangeDialog, icon: const Icon(Icons.network_check)),
              IconButton(
                  tooltip: tr('settings'),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
                  icon: const Icon(Icons.settings)),
            ],
          ),
          body: Stack(children: [
            Column(children: [
              _peerBar(),
              if (mesh.offer != null)
                Card(
                  child: ListTile(
                    title: Text(tr(mesh.offer!['video'] == true ? 'inVideo' : 'inVoice')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(onPressed: mesh.reject, icon: const Icon(Icons.call_end, color: Colors.red)),
                      IconButton(onPressed: mesh.accept, icon: const Icon(Icons.call, color: Colors.green)),
                    ]),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: mesh.msgs.length,
                  itemBuilder: (_, i) => _bubble(mesh.msgs[i]),
                ),
              ),
              SafeArea(
                child: Row(children: [
                  IconButton(onPressed: _pickFile, icon: const Icon(Icons.attach_file)),
                  Expanded(
                      child: TextField(
                          controller: input,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(hintText: tr('hint')))),
                  IconButton(
                      onPressed: _toggleRec,
                      icon: Icon(recording ? Icons.stop_circle : Icons.mic, color: recording ? Colors.red : null)),
                  IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                ]),
              ),
            ]),
            if (mesh.inCall)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: Stack(children: [
                    Positioned.fill(
                        child: RTCVideoView(mesh.remoteR, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)),
                    Positioned(right: 12, top: 12, width: 110, height: 150, child: RTCVideoView(mesh.localR, mirror: true)),
                    Positioned(
                      bottom: 36,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: FloatingActionButton(
                            backgroundColor: Colors.red,
                            onPressed: mesh.hangup,
                            child: const Icon(Icons.call_end, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Widget _row(String label, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          child,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('settings'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          _row(tr('name'), TextFormField(
              initialValue: settings.name,
              onFieldSubmitted: (v) {
                if (v.trim().isNotEmpty) {
                  settings.name = v.trim();
                  settings.save();
                }
              })),
          _row(tr('theme'), SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(tr('auto'))),
              ButtonSegment(value: 1, label: Text(tr('light'))),
              ButtonSegment(value: 2, label: Text(tr('dark'))),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (s) {
              settings.themeMode = s.first;
              settings.save();
            },
          )),
          _row(tr('color'), Wrap(spacing: 10, children: [
            for (var i = 0; i < seeds.length; i++)
              GestureDetector(
                onTap: () {
                  settings.colorIdx = i;
                  settings.save();
                },
                child: CircleAvatar(
                  backgroundColor: Color(seeds[i]),
                  radius: 18,
                  child: settings.colorIdx == i ? const Icon(Icons.check, color: Colors.white) : null,
                ),
              ),
          ])),
          _row(tr('textsize'), Slider(
            min: 0.85,
            max: 1.5,
            divisions: 13,
            value: settings.textScale,
            onChanged: (v) {
              settings.textScale = v;
              settings.save();
            },
          )),
          _row(tr('bubble'), SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(tr('round'))),
              ButtonSegment(value: 1, label: Text(tr('square'))),
              ButtonSegment(value: 2, label: Text(tr('flat'))),
            ],
            selected: {settings.bubble},
            onSelectionChanged: (s) {
              settings.bubble = s.first;
              settings.save();
            },
          )),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('compact')),
            value: settings.compact,
            onChanged: (v) {
              settings.compact = v;
              settings.save();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('awake')),
            value: settings.keepAwake,
            onChanged: (v) {
              settings.keepAwake = v;
              settings.save();
            },
          ),
          _row(tr('lang'), SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'en', label: Text('English')),
              ButtonSegment(value: 'ur', label: Text('اردو')),
            ],
            selected: {settings.lang},
            onSelectionChanged: (s) {
              settings.lang = s.first;
              settings.save();
            },
          )),
        ]),
      ),
    );
  }
}
