import 'package:flutter/foundation.dart';

import '../api/hive_api.g.dart';
import 'output_route.dart';
import 'quality.dart';

/// The quality badge on Now playing: what reaches your ears, honestly.
///
/// Rules (Design review 2):
/// - Bluetooth can't carry lossless, so anything over Bluetooth reads
///   "High · Bluetooth" (or "Data saver · Bluetooth"), with the source named
///   beside it ("AirPods Pro · from Lossless").
/// - A lossy stream reads as its mode ("High", "Data saver"), or the file's own
///   format when the original is lossy ("MP3 320").
/// - Lossless reads "Lossless 16/44.1"; "Hi-Res 24/96" only when the output can
///   carry it (wired, USB, or a computer's own output).
@immutable
class QualityBadge {
  const QualityBadge({
    required this.label,
    required this.lossless,
    required this.detail,
    this.bluetooth = false,
  });

  /// Upper-cased on screen, e.g. "HIGH · BLUETOOTH".
  final String label;

  /// Teal (lossless colour) when the sound reaching you is lossless.
  final bool lossless;

  /// The line beside the badge, e.g. "AirPods Pro · from Lossless".
  final String detail;
  final bool bluetooth;
}

String tierName(AudioFormat f) => switch (f.tier) {
  'hires' => 'Hi-Res',
  'lossless' => 'Lossless',
  _ => f.label,
};

QualityBadge qualityBadge({
  required StreamTicket ticket,
  required QualityMode mode,
  required OutputRoute output,
}) {
  final sent = ticket.format;
  final source = ticket.source ?? ticket.format;
  final sentName = !sent.lossless
      ? (ticket.transcoded
            ? (mode == QualityMode.dataSaver ? 'Data saver' : 'High')
            : sent.label)
      : null;

  if (output.kind == OutputKind.bluetooth) {
    final name = sentName == 'Data saver' ? 'Data saver' : 'High';
    return QualityBadge(
      label: '$name · Bluetooth',
      lossless: false,
      bluetooth: true,
      detail: '${output.name} · from ${tierName(source)}',
    );
  }
  if (sentName != null) {
    return QualityBadge(
      label: sentName,
      lossless: false,
      detail: ticket.transcoded
          ? '${output.name} · from ${tierName(source)}'
          : output.name,
    );
  }
  final hiresOk =
      sent.tier == 'hires' &&
      (output.kind == OutputKind.wired ||
          output.kind == OutputKind.usb ||
          output.kind == OutputKind.unknown);
  return QualityBadge(
    // A phone's own speaker or AirPlay resamples hi-res, so it reads Lossless.
    label: sent.tier == 'hires' && !hiresOk ? 'Lossless' : sent.label,
    lossless: true,
    detail: output.name,
  );
}

/// One hop of the signal path sheet.
@immutable
class PathHop {
  const PathHop(this.title, this.quality, this.detail, {this.weakest = false});
  final String title;
  final String quality;
  final String detail;
  final bool weakest;
}

/// "How this song reaches you": file → stream → player → output, with the
/// weakest link named and what to do about it.
({List<PathHop> hops, String verdict, String? fix}) signalPath({
  required StreamTicket ticket,
  required QualityMode mode,
  required OutputRoute output,
  required String playerName,
  required bool levelling,
}) {
  final source = ticket.source ?? ticket.format;
  final sent = ticket.format;
  final badge = qualityBadge(ticket: ticket, mode: mode, output: output);
  final streamLossy = !sent.lossless && source.lossless;
  final hops = <PathHop>[
    PathHop('File at home', source.label, _codecName(source)),
    PathHop(
      'Sent to this device',
      ticket.transcoded
          ? (sent.lossless ? 'Lossless' : sent.label)
          : 'Original file',
      ticket.transcoded
          ? (sent.lossless
                ? 'Repackaged as FLAC for this player, same samples'
                : '${mode.label}: ${mode.detail}')
          : 'Byte for byte, nothing changed',
      weakest: streamLossy && !output.lossyLink,
    ),
    PathHop(
      'Player',
      levelling ? 'Volume levelling on' : 'Bit-perfect',
      playerName,
    ),
    PathHop(
      'Output',
      output.lossyLink
          ? 'Bluetooth'
          : (sent.lossless ? 'Lossless' : sent.label),
      output.lossyLink
          ? '${output.name}: Bluetooth re-encodes the sound'
          : output.name,
      weakest: output.lossyLink,
    ),
  ];
  String? fix;
  if (output.lossyLink && source.lossless) {
    fix = "Bluetooth can't carry lossless audio. For the full file, use wired headphones or plug into a speaker.";
  } else if (streamLossy) {
    fix =
        'This song is sent as ${mode.label} to save data. Choose Lossless in Settings to hear the original file.';
  } else if (!source.lossless) {
    fix =
        'The file at home is ${source.label}, so this is the best it can sound.';
  }
  final verdict = badge.lossless
      ? "You're hearing the original file."
      : "You're hearing ${badge.bluetooth ? 'High' : badge.label} quality.";
  return (hops: hops, verdict: verdict, fix: fix);
}

String _codecName(AudioFormat f) => switch (f.codec) {
  'flac' => 'FLAC',
  'alac' => 'Apple Lossless',
  'wav' => 'WAV',
  'aiff' => 'AIFF',
  'mp3' => 'MP3',
  'aac' => 'AAC',
  'opus' => 'Opus',
  'vorbis' => 'Ogg Vorbis',
  _ => f.codec.toUpperCase(),
};
