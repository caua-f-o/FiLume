import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/ffmpeg.dart';
import '../core/format.dart';

/// Fica verdadeiro no main() se a biblioteca de reprodução carregou.
bool playerAvailable = false;

/// Player compacto para as prévias (cortar e recortar). Só existe enquanto a
/// ferramenta está aberta: ao sair, o player é destruído e a memória liberada.
class PreviewPlayer extends StatefulWidget {
  const PreviewPlayer({super.key, required this.info, this.overlay, this.footer});
  final MediaInfo info;

  /// Desenhado por cima do vídeo (ex.: a área de recorte).
  final Widget? overlay;

  /// Controles extras abaixo da barra, recebendo a posição atual em segundos.
  final Widget Function(BuildContext context, double Function() position)? footer;

  @override
  State<PreviewPlayer> createState() => _PreviewPlayerState();
}

class _PreviewPlayerState extends State<PreviewPlayer> {
  Player? _player;
  VideoController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    try {
      // Buffer pequeno: é só uma prévia.
      final player = Player(
        configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024, title: 'FiLume'),
      );
      _controller = VideoController(player);
      _player = player;
      player.open(Media(widget.info.path), play: false);
    } catch (_) {
      _failed = true;
    }
  }

  @override
  void didUpdateWidget(PreviewPlayer old) {
    super.didUpdateWidget(old);
    if (old.info.path != widget.info.path) {
      _player?.open(Media(widget.info.path), play: false);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  double _position() => (_player?.state.position.inMilliseconds ?? 0) / 1000;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final player = _player, controller = _controller;
    if (_failed || player == null || controller == null) {
      return Text('Prévia indisponível neste computador.', style: t.textTheme.bodySmall);
    }
    final info = widget.info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 230),
            child: AspectRatio(
              aspectRatio: info.width > 0 && info.height > 0 ? info.width / info.height : 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(
                      controller: controller,
                      controls: NoVideoControls,
                      fit: BoxFit.fill,
                      wakelock: false,
                      pauseUponEnteringBackgroundMode: false,
                    ),
                    if (widget.overlay != null) IgnorePointer(child: widget.overlay!),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, snap) {
            final total = player.state.duration.inMilliseconds > 0
                ? player.state.duration.inMilliseconds.toDouble()
                : info.duration * 1000;
            final pos = (snap.data ?? Duration.zero).inMilliseconds.toDouble().clamp(0.0, total);
            return Row(
              children: [
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (context, playing) => IconButton.filledTonal(
                    tooltip: playing.data == true ? 'Pausar' : 'Reproduzir',
                    visualDensity: VisualDensity.compact,
                    onPressed: player.playOrPause,
                    icon: Icon(playing.data == true ? Icons.pause : Icons.play_arrow),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: total <= 0 ? 0 : pos,
                    max: total <= 0 ? 1 : total,
                    onChanged: total <= 0
                        ? null
                        : (v) => player.seek(Duration(milliseconds: v.round())),
                  ),
                ),
                Text(
                  '${fmtDurationPrecise(pos / 1000)} / ${fmtDuration(total / 1000)}',
                  style: t.textTheme.labelSmall,
                ),
              ],
            );
          },
        ),
        if (widget.footer != null) widget.footer!(context, _position),
      ],
    );
  }
}
