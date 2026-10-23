import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/glass.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../sync/continuity.dart';
import '../../ui/artwork.dart';

const continuityBarHeight = 60.0;

String _clock(int ms) {
  final d = Duration(milliseconds: ms);
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// "Continue from Bilal's MacBook": what another of your devices was
/// playing, ready to carry on here from the same place.
class ContinuityBar extends ConsumerWidget {
  const ContinuityBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.watch(continuityOfferProvider);
    if (offer == null) return const SizedBox.shrink();
    final p = HiveTheme.of(context);
    final c = ref.read(continuityProvider.notifier);
    final where = offer.positionMs > 2000
        ? ' · ${_clock(offer.positionMs)}'
        : '';
    return Semantics(
      container: true,
      label: 'Continue ${offer.track.title} from ${offer.deviceName}',
      child: Glass(
        borderRadius: BorderRadius.circular(HiveRadius.card),
        shadow: true,
        child: SizedBox(
          height: continuityBarHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: Row(
              children: [
                Artwork(
                  artworkId: offer.track.artworkId,
                  title: offer.track.albumTitle,
                  size: 44,
                  pixels: 96,
                  radius: 8,
                ),
                const SizedBox(width: HiveSpace.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        offer.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HiveType.callout.copyWith(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: [
                          Icon(
                            HiveIcons.monitorSmartphone,
                            size: 12,
                            color: p.accentText,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${offer.playing ? 'Playing on' : 'From'} ${offer.deviceName}$where',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HiveType.caption.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: c.carryOn,
                  style: TextButton.styleFrom(
                    foregroundColor: p.accentText,
                    textStyle: HiveType.callout.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Continue'),
                ),
                IconButton(
                  tooltip: 'Not now',
                  icon: Icon(HiveIcons.x, size: 18, color: p.textSecondary),
                  onPressed: c.dismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
