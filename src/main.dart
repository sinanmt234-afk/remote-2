import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const ch = MethodChannel('aether/tv');
const tcpPort = 8765, udpPort = 8766;

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Aether Remote',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFF7C5CFF),
            useMaterial3: true),
        home: const Boot(),
      );
}

class Boot extends StatefulWidget {
  const Boot({super.key});
  @override
  State<Boot> createState() => _BootState();
}

class _BootState extends State<Boot> {
  String? mode;
  bool loaded = false, isTv = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try {
      isTv = await ch.invokeMethod<bool>('isTv') ?? false;
    } catch (_) {}
    mode = p.getString('mode') ?? (isTv ? 'tv' : null);
    setState(() => loaded = true);
  }

  Future<void> _set(String? m) async {
    final p = await SharedPreferences.getInstance();
    if (m == null) {
      await p.remove('mode');
    } else {
      await p.setString('mode', m);
    }
    setState(() => mode = m);
  }

  @override
  Widget build(BuildContext c) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (mode == 'tv') return TvScreen(onReset: () => _set(null));
    if (mode == 'phone') return PhoneScreen(onReset: () => _set(null));
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Aether Remote', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Ee device ethaanu?'),
          const SizedBox(height: 24),
          FilledButton.icon(
              autofocus: isTv,
              onPressed: () => _set('tv'),
              icon: const Icon(Icons.tv),
              label: const Padding(padding: EdgeInsets.all(12), child: Text('Ithu ente TV / Projector', style: TextStyle(fontSize: 18)))),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
              autofocus: !isTv,
              onPressed: () => _set('phone'),
              icon: const Icon(Icons.phone_android),
              label: const Padding(padding: EdgeInsets.all(12), child: Text('Ithu ente Phone (remote)', style: TextStyle(fontSize: 18)))),
        ]),
      ),
    );
  }
}

// ---------------- TV receiver screen ----------------
class TvScreen extends StatefulWidget {
  final VoidCallback onReset;
  const TvScreen({super.key, required this.onReset});
  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen> with WidgetsBindingObserver {
  String pin = '----', name = '';
  bool enabled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    pin = await ch.invokeMethod<String>('pin') ?? '----';
    name = await ch.invokeMethod<String>('name') ?? '';
    enabled = await ch.invokeMethod<bool>('enabled') ?? false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(name, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 8),
            const Text('Phone-il ee PIN adikkuka:'),
            Text(pin, style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold, letterSpacing: 12)),
            const SizedBox(height: 16),
            Icon(enabled ? Icons.check_circle : Icons.error, color: enabled ? Colors.green : Colors.orange, size: 40),
            Text(enabled ? 'Ready! Phone-il ninnu TV select cheyyam.' : 'Accessibility service on aakkanam:\nSettings > "Aether Remote" > ON',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(autofocus: true, onPressed: () => ch.invokeMethod('openSettings'), child: const Text('Open Accessibility settings')),
            const SizedBox(height: 8),
            TextButton(onPressed: widget.onReset, child: const Text('Mode maattuka')),
          ]),
        ),
      );
}

// ---------------- Networking (phone) ----------------
Future<String> sendKey(String ip, String pin, String key) async {
  try {
    final s = await Socket.connect(ip, tcpPort, timeout: const Duration(seconds: 2));
    s.write('$pin:$key\n');
    await s.flush();
    final r = await utf8.decoder.bind(s).first.timeout(const Duration(seconds: 3));
    s.destroy();
    return r.trim();
  } catch (_) {
    return 'ERR';
  }
}

Future<Map<String, String>> scan() async {
  final found = <String, String>{};
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sock.broadcastEnabled = true;
  sock.listen((e) {
    if (e == RawSocketEvent.read) {
      final d = sock.receive();
      if (d == null) return;
      final t = utf8.decode(d.data, allowMalformed: true);
      if (t.startsWith('AETHER!')) found[d.address.address] = t.substring(7);
    }
  });
  for (var i = 0; i < 3; i++) {
    sock.send(utf8.encode('AETHER?'), InternetAddress('255.255.255.255'), udpPort);
    await Future.delayed(const Duration(milliseconds: 900));
  }
  sock.close();
  return found;
}

// ---------------- Phone: TV list ----------------
class PhoneScreen extends StatefulWidget {
  final VoidCallback onReset;
  const PhoneScreen({super.key, required this.onReset});
  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  Map<String, String> tvs = {};
  bool scanning = false;
  final ipCtl = TextEditingController();
  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => scanning = true);
    try {
      tvs = await scan();
    } catch (_) {}
    if (mounted) setState(() => scanning = false);
  }

  Future<void> _open(String ip, String name) async {
    final p = await SharedPreferences.getInstance();
    var pin = p.getString('pin_$ip');
    if (pin != null && await sendKey(ip, pin, 'PING') == 'OK') {
      _go(ip, name, pin);
      return;
    }
    final ctl = TextEditingController();
    if (!mounted) return;
    final entered = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text('$name - PIN'),
              content: TextField(controller: ctl, keyboardType: TextInputType.number, maxLength: 4, autofocus: true, decoration: const InputDecoration(hintText: 'TV-yil kaanunna 4 digit PIN')),
              actions: [TextButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Connect'))],
            ));
    if (entered == null || entered.isEmpty) return;
    final r = await sendKey(ip, entered, 'PING');
    if (!mounted) return;
    if (r == 'OK') {
      await p.setString('pin_$ip', entered);
      _go(ip, name, entered);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r == 'BAD' ? 'PIN thettanu' : 'TV-yil connect aayilla (app open aano? accessibility on aano?)')));
    }
  }

  void _go(String ip, String name, String pin) => Navigator.push(context, MaterialPageRoute(builder: (_) => RemoteScreen(ip: ip, name: name, pin: pin)));

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Ente TV-kal'), actions: [
          IconButton(onPressed: scanning ? null : _scan, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: widget.onReset, icon: const Icon(Icons.swap_horiz)),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (scanning) const LinearProgressIndicator(),
          if (!scanning && tvs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('TV kandilla. Randum same Wi-Fi-yil aano? TV-yil app open aakki accessibility on aakiyo? Allenkil thazhe IP adikkuka.')),
          for (final e in tvs.entries)
            Card(child: ListTile(leading: const Icon(Icons.tv), title: Text(e.value), subtitle: Text(e.key), onTap: () => _open(e.key, e.value))),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: TextField(controller: ipCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'TV IP (manual)'))),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => ipCtl.text.trim().isEmpty ? null : _open(ipCtl.text.trim(), ipCtl.text.trim()), child: const Text('Connect')),
          ]),
        ]),
      );
}

// ---------------- Phone: remote ----------------
class RemoteScreen extends StatelessWidget {
  final String ip, name, pin;
  const RemoteScreen({super.key, required this.ip, required this.name, required this.pin});

  void _send(String k) {
    HapticFeedback.selectionClick();
    sendKey(ip, pin, k);
  }

  Widget b(IconData i, String k, {double size = 64, bool repeat = false, bool big = false}) =>
      RepeatBtn(icon: i, size: size, repeat: repeat, big: big, onFire: () => _send(k));

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text(name)),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [b(Icons.power_settings_new, 'POWER'), b(Icons.volume_off, 'MUTE'), b(Icons.apps, 'RECENTS')]),
              const SizedBox(height: 24),
              b(Icons.keyboard_arrow_up, 'UP', size: 84, repeat: true),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                b(Icons.keyboard_arrow_left, 'LEFT', size: 84, repeat: true),
                const SizedBox(width: 8),
                b(Icons.circle, 'OK', size: 96, big: true),
                const SizedBox(width: 8),
                b(Icons.keyboard_arrow_right, 'RIGHT', size: 84, repeat: true),
              ]),
              b(Icons.keyboard_arrow_down, 'DOWN', size: 84, repeat: true),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [b(Icons.arrow_back, 'BACK'), b(Icons.home, 'HOME'), Column(children: [b(Icons.volume_up, 'VOL_UP', repeat: true), const SizedBox(height: 8), b(Icons.volume_down, 'VOL_DOWN', repeat: true)])]),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [b(Icons.skip_previous, 'PREV'), b(Icons.fast_rewind, 'RW'), b(Icons.play_arrow, 'PLAY'), b(Icons.fast_forward, 'FF'), b(Icons.skip_next, 'NEXT')].map((w) => Flexible(child: w)).toList()),
            ]),
          ),
        ),
      );
}

class RepeatBtn extends StatefulWidget {
  final IconData icon;
  final double size;
  final bool repeat, big;
  final VoidCallback onFire;
  const RepeatBtn({super.key, required this.icon, required this.size, required this.repeat, required this.big, required this.onFire});
  @override
  State<RepeatBtn> createState() => _RepeatBtnState();
}

class _RepeatBtnState extends State<RepeatBtn> {
  Timer? t;
  bool down = false;
  void _start() {
    setState(() => down = true);
    widget.onFire();
    if (widget.repeat) {
      t = Timer(const Duration(milliseconds: 450), () {
        t = Timer.periodic(const Duration(milliseconds: 150), (_) => widget.onFire());
      });
    }
  }

  void _stop() {
    t?.cancel();
    if (mounted) setState(() => down = false);
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Listener(
      onPointerDown: (_) => _start(),
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: down ? cs.primary : (widget.big ? cs.primaryContainer : cs.surfaceContainerHighest)),
        child: Icon(widget.icon, size: widget.size * 0.5, color: down ? cs.onPrimary : cs.onSurface),
      ),
    );
  }
}
