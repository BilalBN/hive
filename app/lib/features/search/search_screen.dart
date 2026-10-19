import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hive_api.g.dart';
import '../../core/api.dart';
import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/credits.dart';
import '../../ui/language_chips.dart';
import '../../ui/nav.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';

/// Recent searches, kept on this device only.
class RecentSearches extends Notifier<List<String>> {
  static const _key = 'search.recent';
  static const _max = 8;

  @override
  List<String> build() =>
      ref.watch(sharedPreferencesProvider).getStringList(_key) ?? const [];

  Future<void> add(String q) async {
    final text = q.trim();
    if (text.isEmpty) return;
    state = [
      text,
      ...state.where((s) => s.toLowerCase() != text.toLowerCase()),
    ].take(_max).toList();
    await ref.read(sharedPreferencesProvider).setStringList(_key, state);
  }

  Future<void> clear() async {
    state = const [];
    await ref.read(sharedPreferencesProvider).remove(_key);
  }
}

final recentSearchesProvider = NotifierProvider<RecentSearches, List<String>>(
  RecentSearches.new,
);

/// Lets a keyboard shortcut (⌘F / Ctrl+F) put the cursor in the search box.
final searchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'search');
  ref.onDispose(node.dispose);
  return node;
});

/// Search the family library: songs, albums, artists and playlists, in any
/// script (Malayalam, Hindi, English), with or without the right spelling.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  /// Suggestions show while typing, and step aside once one is picked or the
  /// search is sent.
  bool _suggesting = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _set(String q) {
    _controller.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    setState(() => _query = q.trim());
  }

  void _remember() => ref.read(recentSearchesProvider.notifier).add(_query);

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final focus = ref.watch(searchFocusProvider);

    final field = TextField(
      controller: _controller,
      focusNode: focus,
      textInputAction: TextInputAction.search,
      onChanged: (v) => setState(() {
        _query = v.trim();
        _suggesting = true;
      }),
      onSubmitted: (_) {
        _remember();
        setState(() => _suggesting = false);
      },
      style: HiveType.body.copyWith(color: p.textPrimary),
      decoration: InputDecoration(
        hintText: 'Songs, albums, artists, playlists',
        hintStyle: HiveType.body.copyWith(color: p.textTertiary),
        prefixIcon: Icon(HiveIcons.search, size: 20, color: p.textSecondary),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: Icon(HiveIcons.circleX, size: 18, color: p.textSecondary),
                onPressed: () => _set(''),
              ),
        filled: true,
        fillColor: p.raised,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HiveRadius.card),
          borderSide: BorderSide.none,
        ),
      ),
    );

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.sm,
            ),
            child: Semantics(
              header: true,
              child: Text(
                'Search',
                style: HiveType.title1.copyWith(color: p.textPrimary),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
            child: field,
          ),
          const Padding(
            padding: EdgeInsets.only(top: HiveSpace.xs),
            child: LanguageChips(),
          ),
          const SizedBox(height: HiveSpace.xs),
          if (_query.isNotEmpty && _suggesting)
            _Suggestions(
              query: _query,
              onPick: (s) {
                _set(s.text);
                _remember();
                setState(() => _suggesting = false);
                switch (s.kind) {
                  case 'album':
                    context.openAlbum(s.id);
                  case 'artist':
                    context.openArtist(s.id);
                  default:
                    FocusScope.of(context).unfocus();
                }
              },
            ),
          Expanded(
            child: _query.isEmpty
                ? _Recent(onPick: _set)
                : _Results(query: _query, onOpen: _remember),
          ),
        ],
      ),
    );
  }
}

/// Up to five names that finish what's typed: a song fills in the search, an
/// album or artist opens.
class _Suggestions extends ConsumerWidget {
  const _Suggestions({required this.query, required this.onPick});
  final String query;
  final ValueChanged<Suggestion> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final items = ref.watch(suggestionsProvider(query)).value ?? const [];
    // Nothing to add when the only suggestion is exactly what's typed.
    final shown = items
        .where((s) => s.text.toLowerCase() != query.toLowerCase())
        .take(5)
        .toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.md,
        0,
        HiveSpace.md,
        HiveSpace.xs,
      ),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(HiveRadius.card),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final s in shown)
              Semantics(
                button: true,
                label:
                    'Suggestion: ${s.text}${s.detail == null ? '' : ', ${s.detail}'}',
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => onPick(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HiveSpace.md,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          switch (s.kind) {
                            'album' => HiveIcons.discAlbum,
                            'artist' => HiveIcons.userRound,
                            _ => HiveIcons.music,
                          },
                          size: 16,
                          color: p.textSecondary,
                        ),
                        const SizedBox(width: HiveSpace.sm),
                        Flexible(
                          child: Text(
                            s.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HiveType.body.copyWith(
                              color: p.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (s.detail != null) ...[
                          const SizedBox(width: HiveSpace.xs),
                          Expanded(
                            child: Text(
                              s.detail!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HiveType.callout.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ] else
                          const Spacer(),
                        Icon(
                          s.kind == 'song'
                              ? HiveIcons.arrowUpLeft
                              : HiveIcons.chevronRight,
                          size: 16,
                          color: p.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Recent extends ConsumerWidget {
  const _Recent({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final recent = ref.watch(recentSearchesProvider);
    if (recent.isEmpty) {
      return const EmptyState(
        icon: HiveIcons.search,
        title: 'Find anything at home',
        text: 'Type a song, album, artist or playlist. Malayalam, Hindi and English all work, and spelling doesn\'t have to be exact.',
      );
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HiveSpace.md,
            HiveSpace.sm,
            HiveSpace.xs,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'RECENT',
                  style: HiveType.overline.copyWith(color: p.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(recentSearchesProvider.notifier).clear(),
                child: Text(
                  'Clear',
                  style: HiveType.callout.copyWith(color: p.accentText),
                ),
              ),
            ],
          ),
        ),
        for (final q in recent)
          ListTile(
            leading: Icon(HiveIcons.history, size: 18, color: p.textSecondary),
            title: Text(q, style: HiveType.body.copyWith(color: p.textPrimary)),
            onTap: () => onPick(q),
          ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.query, required this.onOpen});
  final String query;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final results = ref.watch(searchProvider(query));
    return results.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const LoadingState(),
      error: (e, _) => e is StateError
          ? const LoadingState()
          : ErrorState(
              message: describeError(e),
              onRetry: () => ref.invalidate(searchProvider(query)),
            ),
      data: (r) {
        final empty =
            r.tracks.isEmpty &&
            r.albums.isEmpty &&
            r.artists.isEmpty &&
            r.playlists.isEmpty;
        if (empty) {
          final lang = ref.watch(activeLanguageProvider);
          return EmptyState(
            icon: HiveIcons.searchX,
            title: 'Nothing found for "$query"',
            text: lang != null
                ? 'Only ${languageName(ref, lang) ?? 'one language'} is shown. Choose All to search everything.'
                : 'Try fewer words, or another spelling. Not at home yet? Ask whoever runs your home to add it.',
          );
        }
        final player = ref.read(playerProvider.notifier);
        void open(VoidCallback go) {
          onOpen();
          go();
        }

        return ListView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + HiveSpace.md,
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (r.tracks.isNotEmpty) ...[
              const _Heading('Songs'),
              for (var i = 0; i < r.tracks.length; i++)
                TrackRow(
                  track: r.tracks[i],
                  showAlbum: true,
                  onTap: () => open(
                    () => player.playTracks(
                      [r.tracks[i]],
                      source: PlaySource(
                        kind: 'search',
                        id: query,
                        name: 'Search: $query',
                      ),
                    ),
                  ),
                ),
            ],
            if (r.artists.isNotEmpty) ...[
              const _Heading('Artists'),
              for (final a in r.artists)
                ListRow(
                  leading: Artwork(
                    artworkId: a.artworkId,
                    title: a.name,
                    size: 48,
                    round: true,
                    pixels: 96,
                  ),
                  title: a.name,
                  subtitle:
                      '${plural(a.albumCount, 'album')} · ${plural(a.trackCount, 'song')}',
                  onTap: () => open(() => context.openArtist(a.id)),
                ),
            ],
            if (r.albums.isNotEmpty) ...[
              const _Heading('Albums'),
              for (final a in r.albums)
                _AlbumRow(
                  album: a,
                  onTap: () => open(() => context.openAlbum(a.id)),
                ),
            ],
            if (r.playlists.isNotEmpty) ...[
              const _Heading('Playlists'),
              for (final pl in r.playlists)
                ListRow(
                  leading: Mosaic(
                    artworkIds: pl.artworkIds,
                    title: pl.name,
                    size: 48,
                    pixels: 96,
                  ),
                  title: pl.name,
                  subtitle:
                      '${pl.mine ? 'Yours' : pl.ownerName} · ${plural(pl.trackCount, 'song')}',
                  onTap: () => open(() => context.openPlaylist(pl.id)),
                ),
            ],
            Padding(
              padding: const EdgeInsets.all(HiveSpace.md),
              child: Text(
                'Searching the family library at home.',
                style: HiveType.caption.copyWith(color: p.textTertiary),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AlbumRow extends StatelessWidget {
  const _AlbumRow({required this.album, required this.onTap});
  final AlbumSummary album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListRow(
      leading: Artwork(
        artworkId: album.artworkId,
        title: album.title,
        size: 48,
        pixels: 96,
      ),
      title: album.title,
      subtitle: [
        album.artistName,
        if (album.year != null) '${album.year}',
      ].join(' · '),
      onTap: onTap,
      trailing: album.tier == 'lossy'
          ? null
          : QualityChip(label: tierLabel(album.tier), lossless: true),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.md,
        HiveSpace.md,
        HiveSpace.md,
        HiveSpace.xxs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: HiveType.headline.copyWith(color: p.textPrimary),
        ),
      ),
    );
  }
}
