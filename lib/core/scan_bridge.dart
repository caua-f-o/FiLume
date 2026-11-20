import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Aparelho local (WIA ou TWAIN) servido pelo FiPDF.Scan em 127.0.0.1.
class BridgeDevice {
  const BridgeDevice(this.name, this.driver, this.id, this.url);
  final String name;

  /// "wia", "twain" ou "demo".
  final String driver;

  /// Identificador estável (ex.: "wia:{...}"): é por ele que o FiPDF lembra o aparelho.
  final String id;

  /// Endereço eSCL do servidor local (muda a cada vez que o auxiliar sobe), ou null se não subiu.
  final String? url;
}

class BridgeError implements Exception {
  BridgeError(this.message, [this.details = '']);
  final String message;
  final String details;
  @override
  String toString() => details.isEmpty ? message : '$message\n$details';
}

/// Ponte com o FiPDF.Scan, o auxiliar em C# que dá acesso aos scanners WIA e TWAIN.
///
/// O auxiliar sobe um servidor eSCL em 127.0.0.1 para cada aparelho; o FiPDF digitaliza por ele
/// com o mesmo cliente eSCL dos aparelhos de rede. Pela ponte (stdin/stdout, uma linha JSON por
/// mensagem) só passam comandos: "listar", "atualizar", "ping" e "sair".
class ScanBridge {
  ScanBridge({String? exe, this.demo = false, this.pingEvery = const Duration(seconds: 5)}) : _exe = exe;

  /// Versão do protocolo que este lado entende.
  static const protocol = 1;

  final String? _exe;

  /// Acrescenta o aparelho de demonstração (para testes).
  final bool demo;
  final Duration pingEvery;

  Process? _proc;
  StreamSubscription<String>? _out;
  Completer<void>? _ready;
  final _waiting = <Completer<Map<String, dynamic>>>[];
  Timer? _pinger;
  bool _pinging = false;
  bool _stopped = false;
  final _restarts = <DateTime>[];

  List<BridgeDevice> _devices = const [];
  List<String> _driverErrors = const [];

  /// Avisos para a interface (ex.: "o auxiliar parou e foi reiniciado"). Null = tudo normal.
  String? notice;

  /// Por que a ponte não está disponível (ex.: auxiliar ausente). Null = disponível ou ainda não tentou.
  String? unavailable;

  /// Chamado quando a lista de aparelhos ou os avisos mudam.
  void Function()? onChange;

  List<BridgeDevice> get devices => _devices;

  /// Erros de driver da última procura (ex.: o TWAIN não respondeu).
  List<String> get driverErrors => _driverErrors;

  bool get running => _proc != null;

  /// Caminho do auxiliar: a pasta fipdf-scan ao lado do FiPDF (ou FILUME_SCAN_EXE, para testes).
  static String? locate() {
    final env = Platform.environment['FILUME_SCAN_EXE'];
    if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
    if (!Platform.isWindows) return null;
    final exe = p.join(File(Platform.resolvedExecutable).parent.path, 'fipdf-scan', 'FiPDF.Scan.exe');
    return File(exe).existsSync() ? exe : null;
  }

  /// Sobe o auxiliar (se ainda não estiver de pé) e espera o anúncio de pronto.
  Future<void> ensure({Duration timeout = const Duration(seconds: 120)}) async {
    if (_stopped) throw BridgeError('A ponte de digitalização foi encerrada.');
    if (_proc == null) await _start();
    final ready = _ready;
    if (ready == null) throw BridgeError(unavailable ?? 'O auxiliar de digitalização não subiu.');
    await ready.future.timeout(timeout, onTimeout: () {
      throw BridgeError('O auxiliar de digitalização demorou demais para ficar pronto.');
    });
  }

  /// Inicia em segundo plano, sem esperar (para os aparelhos já estarem prontos quando a pessoa abrir a digitalização).
  void warmUp() {
    if (_proc != null || _stopped) return;
    unawaited(_start().catchError((_) {}));
  }

  Future<void> _start() async {
    final exe = _exe ?? locate();
    if (exe == null) {
      unavailable = 'O auxiliar de digitalização (fipdf-scan) não está na pasta do FiPDF.';
      throw BridgeError(unavailable!);
    }
    unavailable = null;
    final ready = _ready = Completer<void>();
    final Process proc;
    try {
      proc = await Process.start(exe, ['servir', '--pai', '$pid', if (demo) '--demo'], workingDirectory: File(exe).parent.path);
    } on ProcessException catch (e) {
      _ready = null;
      unavailable = 'Não foi possível abrir o auxiliar de digitalização.';
      throw BridgeError(unavailable!, e.message);
    }
    _proc = proc;
    final err = StringBuffer();
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      if (err.length < 4000) err.write(s);
    });
    _out = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => _onLine(line, ready));
    unawaited(proc.exitCode.then((code) => _onExit(proc, code, err.toString())));
    _pinger?.cancel();
    _pinger = Timer.periodic(pingEvery, (_) => _ping());
  }

  void _onLine(String line, Completer<void> ready) {
    Map<String, dynamic> msg;
    try {
      final j = jsonDecode(line.trim());
      if (j is! Map) return;
      msg = j.cast<String, dynamic>();
    } catch (_) {
      return; // linha que não é JSON: ignora
    }
    final tipo = msg['tipo'];
    if (tipo == 'pronto') {
      final v = msg['versao'];
      if (v is int && v != protocol) {
        unavailable = 'O auxiliar de digitalização é de outra versão (protocolo $v; este FiPDF usa o $protocol). '
            'Reinstale ou atualize o FiPDF.';
        if (!ready.isCompleted) ready.completeError(BridgeError(unavailable!));
        _kill();
        return;
      }
      _take(msg);
      if (!ready.isCompleted) ready.complete();
      onChange?.call();
      return;
    }
    if (tipo == 'dispositivos') _take(msg);
    if (_waiting.isNotEmpty) _waiting.removeAt(0).complete(msg);
  }

  void _take(Map<String, dynamic> msg) {
    final list = msg['dispositivos'];
    _devices = [
      if (list is List)
        for (final d in list)
          if (d is Map && d['id'] is String)
            BridgeDevice('${d['nome'] ?? d['id']}', '${d['driver'] ?? ''}', d['id'] as String, d['url'] as String?),
    ];
    final errs = msg['erros'];
    _driverErrors = [
      if (errs is List)
        for (final e in errs)
          if (e is Map) '${'${e['driver']}'.toUpperCase()}: ${e['mensagem']}',
    ];
  }

  void _onExit(Process proc, int code, String stderr) {
    if (_proc != proc) return; // já foi substituído
    _proc = null;
    _out?.cancel();
    _pinger?.cancel();
    final ready = _ready;
    _ready = null;
    final error = BridgeError('O auxiliar de digitalização fechou (código $code).', stderr.trim());
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    for (final w in _waiting) {
      if (!w.isCompleted) w.completeError(error);
    }
    _waiting.clear();
    _devices = const [];
    if (_stopped) return;
    _restart('O auxiliar de digitalização parou e foi reiniciado.');
  }

  /// Reinicia o auxiliar, no máximo 3 vezes por minuto (para não ficar em laço se ele não consegue subir).
  void _restart(String why) {
    final now = DateTime.now();
    _restarts.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_restarts.length >= 3) {
      notice = 'O auxiliar de digitalização parou várias vezes seguidas. Os scanners USB ficam indisponíveis até reabrir o FiPDF.';
      unavailable = notice;
      onChange?.call();
      return;
    }
    _restarts.add(now);
    notice = why;
    onChange?.call();
    _kill();
    unawaited(Future<void>.delayed(const Duration(seconds: 1), () async {
      if (_stopped) return;
      try {
        await _start();
      } catch (_) {}
    }));
  }

  Future<void> _ping() async {
    if (_pinging || _proc == null || _ready?.isCompleted != true) return;
    _pinging = true;
    try {
      final r = await _send('ping', const Duration(seconds: 10));
      if (r['tipo'] != 'pong') throw BridgeError('resposta inesperada ao ping');
    } catch (_) {
      // Sem resposta: o auxiliar travou. Derruba e sobe de novo.
      if (_proc != null && !_stopped) _restart('O auxiliar de digitalização parou de responder e foi reiniciado.');
    } finally {
      _pinging = false;
    }
  }

  Future<Map<String, dynamic>> _send(String command, Duration timeout) {
    final proc = _proc;
    if (proc == null) return Future.error(BridgeError('O auxiliar de digitalização não está aberto.'));
    final c = Completer<Map<String, dynamic>>();
    _waiting.add(c);
    try {
      proc.stdin.writeln(jsonEncode({'comando': command}));
    } catch (e) {
      _waiting.remove(c);
      return Future.error(BridgeError('Não foi possível falar com o auxiliar de digitalização.', '$e'));
    }
    return c.future.timeout(timeout, onTimeout: () {
      _waiting.remove(c);
      throw BridgeError('O auxiliar de digitalização não respondeu a "$command".');
    });
  }

  /// Procura os aparelhos de novo (o auxiliar refaz os servidores; as URLs mudam).
  Future<List<BridgeDevice>> refresh() async {
    await ensure();
    final r = await _send('atualizar', const Duration(seconds: 150));
    if (r['tipo'] == 'erro') throw BridgeError('Não foi possível procurar os scanners deste computador.', '${r['mensagem']}');
    notice = null;
    onChange?.call();
    return _devices;
  }

  /// Endereço eSCL atual do aparelho [id], ou null se ele não está (mais) na lista.
  String? urlFor(String id) {
    for (final d in _devices) {
      if (d.id == id) return d.url;
    }
    return null;
  }

  void _kill() {
    final proc = _proc;
    _proc = null;
    _out?.cancel();
    _pinger?.cancel();
    _ready = null;
    _devices = const [];
    if (proc != null) {
      try {
        proc.stdin.writeln(jsonEncode({'comando': 'sair'}));
      } catch (_) {}
      Future<void>.delayed(const Duration(seconds: 2), () => proc.kill());
    }
  }

  /// Encerra a ponte (o auxiliar fecha).
  void stop() {
    _stopped = true;
    _kill();
  }

  /// Só para testes: o processo do auxiliar.
  int? get processId => _proc?.pid;
}
