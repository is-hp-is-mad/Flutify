import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/md3e_shapes.dart';
import '../../../../models/track.dart';
import '../../../../providers/connect_provider.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/canvas/canvas_service.dart';
import '../../../../services/spotify_api_service.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/motion_video.dart';

/// Shares the existing artwork bounds and swipe gestures. The muted native
/// texture video is only mounted while playback and application visibility
/// permit motion.
class CanvasArtwork extends StatefulWidget {
  final SpotifyTrack track;
  final double size;
  final bool remote;
  final BorderRadius borderRadius;
  const CanvasArtwork({
    super.key,
    required this.track,
    required this.size,
    this.remote = false,
    this.borderRadius = MD3EShapes.roundedExtraLarge,
  });
  @override
  State<CanvasArtwork> createState() => _CanvasArtworkState();
}

class _CanvasArtworkState extends State<CanvasArtwork>
    with WidgetsBindingObserver {
  CanvasMedia? _media;
  String? _requested;
  bool _foreground = true;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _foreground = state == AppLifecycleState.resumed);
    }
  }

  @override
  void didUpdateWidget(covariant CanvasArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.track.uri != oldWidget.track.uri) {
      _revision++;
      _requested = null;
      _media = null;
    }
  }

  void _request(SpotifyApiService api) {
    final uri = widget.track.uri;
    _requested = uri;
    final revision = ++_revision;
    api.canvas.get(uri).then((media) {
      if (mounted && revision == _revision) {
        setState(() {
          _media = media;
        });
      }
    });
  }

  @override
  void dispose() {
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<PreferencesProvider?, bool>(
      (p) => p?.prefs.canvasEnabled ?? true,
    );
    final playing = widget.remote
        ? context.select<ConnectProvider?, bool>(
            (p) => p?.player.isAudible ?? false,
          )
        : context.select<PlaybackProvider?, bool>((p) => p?.isPlaying ?? false);
    final active =
        enabled &&
        playing &&
        _foreground &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    final api = context.read<SpotifyApiService?>();
    if (active && api != null && api.isConfigured && _requested == null) {
      _request(api);
    }
    final media = _media;
    final cover = CoverImage(
      url: widget.track.coverUrl,
      size: widget.size,
      cacheSize: 400,
      borderRadius: widget.borderRadius,
    );
    if (!active || media == null) {
      return cover;
    }
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox.square(
        dimension: widget.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            cover,
            if (!media.canvas.isVideo)
              Image.memory(
                media.bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => cover,
              )
            else
              MotionVideo(
                bytes: media.bytes,
                placeholder: cover,
              ),
          ],
        ),
      ),
    );
  }
}
