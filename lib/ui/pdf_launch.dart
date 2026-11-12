import 'dart:io';

import 'package:flutter/material.dart';

import '../core/launch.dart';
import '../core/state.dart';

/// Avisa que PDF agora é no app dedicado e oferece abrir. Se a pessoa aceita,
/// o FiLume PDF abre com [files] e este app fecha para poupar recursos
/// (a não ser que ainda tenha trabalho: fila rodando ou [keepOpen]).
Future<void> offerPdfApp(BuildContext context, AppState state, List<String> files, {bool keepOpen = false}) async {
  final n = files.length;
  final stay = keepOpen || state.queue.busy;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.picture_as_pdf_outlined),
      title: const Text('PDF agora tem app próprio'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          'As ferramentas de PDF saíram daqui e foram para o FiLume PDF, um aplicativo dedicado.\n\n'
          '${n == 0 ? 'Quer abrir o FiLume PDF agora?' : 'Quer abrir ${n == 1 ? 'este arquivo' : 'estes $n arquivos'} no FiLume PDF?'}'
          '${stay ? '' : ' O FiLume fecha em seguida, para poupar recursos.'}',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Agora não')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Abrir o FiLume PDF')),
      ],
    ),
  );
  if (ok != true) return;
  final started = await launchPdfApp(files);
  if (!started) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não consegui abrir o FiLume PDF. Confira se "FiLume PDF.exe" está na pasta do FiLume.')),
      );
    }
    return;
  }
  if (stay) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('O FiLume PDF abriu. Este continua aberto porque ainda tem trabalho aqui.')),
      );
    }
    return;
  }
  state.cleanup();
  exit(0);
}
