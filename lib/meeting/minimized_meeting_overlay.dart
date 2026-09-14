import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/colors.dart';

/// Données vivantes de la réunion réduite (closures évaluées à chaque tick :
/// l'écran de réunion reste monté en arrière-plan et garde LiveKit actif).
class _MinimizedData {
  final String meetingName;
  final int Function() participantCount;
  final int Function() elapsedSeconds;
  final VideoTrack? Function()? videoTrack;
  final VoidCallback onExpand;
  final VoidCallback onEnd;

  /// Route de l'écran de réunion : permet à [MinimizedMeetingOverlay.expand]
  /// de remonter la pile JUSQU'À la réunion (évite d'ouvrir une seconde
  /// connexion avec la même identité → « deux profils d'une même personne »).
  final Route<Object?>? meetingRoute;

  const _MinimizedData({
    required this.meetingName,
    required this.participantCount,
    required this.elapsedSeconds,
    required this.videoTrack,
    required this.onExpand,
    required this.onEnd,
    required this.meetingRoute,
  });
}

/// Mini-fenêtre flottante « réunion en arrière-plan » (type Meet/Zoom).
///
/// L'écran de réunion n'est PAS détruit : il reste monté dans la pile de
/// navigation (hors écran) pendant que la fenêtre flottante vit dans l'overlay
/// racine, au-dessus de toutes les routes. L'audio LiveKit continue donc de
/// fonctionner, aussi bien sur mobile que sur web (onglet en arrière-plan).
class MinimizedMeetingOverlay {
  MinimizedMeetingOverlay._();

  static final MinimizedMeetingOverlay instance = MinimizedMeetingOverlay._();

  OverlayEntry? _entry;

  _MinimizedData? _data;

  bool get isShown => _entry != null;

  /// Remonte la pile de navigation JUSQU'À la réunion réduite et la
  /// réaffiche. À utiliser au lieu de re-rejoindre la réunion (qui ouvrirait
  /// une seconde connexion avec la même identité LiveKit).
  void expand(BuildContext context) {
    final route = _data?.meetingRoute;

    hide();

    if (route != null && route.isActive) {
      Navigator.of(context).popUntil((r) => r == route);
    }
  }

  void show({
    required BuildContext context,
    required String meetingName,
    required int Function() participantCount,
    required int Function() elapsedSeconds,
    VideoTrack? Function()? videoTrack,
    required VoidCallback onExpand,
    required VoidCallback onEnd,
  }) {
    hide();

    final data = _MinimizedData(
      meetingName: meetingName,
      participantCount: participantCount,
      elapsedSeconds: elapsedSeconds,
      videoTrack: videoTrack,
      meetingRoute: ModalRoute.of(context),
      onExpand: () {
        hide();
        onExpand();
      },
      onEnd: () {
        hide();
        onEnd();
      },
    );

    final overlay = Overlay.of(context, rootOverlay: true);

    _entry = OverlayEntry(
      builder: (_) => _MinimizedWindow(data: data),
    );

    overlay.insert(_entry!);
  }

  void hide() {
    _entry?.remove();

    _entry = null;
  }
}

class _MinimizedWindow extends StatefulWidget {
  final _MinimizedData data;

  const _MinimizedWindow({required this.data});

  @override
  State<_MinimizedWindow> createState() => _MinimizedWindowState();
}

class _MinimizedWindowState extends State<_MinimizedWindow> {
  static const Size _windowSize = Size(210, 158);

  Offset _position = const Offset(16, 90);

  Timer? _tick;

  @override
  void initState() {
    super.initState();

    // La vidéo et le chronomètre sont réévalués chaque seconde.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();

    super.dispose();
  }

  String get _formattedDuration {
    final seconds = widget.data.elapsedSeconds();

    final minutes = (seconds % 3600) ~/ 60;

    final secs = seconds % 60;

    final hours = seconds ~/ 3600;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;

    final maxX = (screen.width - _windowSize.width - 8).clamp(8.0, 100000.0);

    final maxY = (screen.height - _windowSize.height - 8).clamp(8.0, 100000.0);

    final position = Offset(
      _position.dx.clamp(8.0, maxX),
      _position.dy.clamp(8.0, maxY),
    );

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _position += details.delta;
          });
        },
        onTap: widget.data.onExpand,
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(18),
          shadowColor: Colors.black54,
          child: Container(
            width: _windowSize.width,
            height: _windowSize.height,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Expanded(child: _buildVideo()),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  color: Colors.black87,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.videocam,
                        color: Colors.greenAccent,
                        size: 13,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '$_formattedDuration · ${widget.data.participantCount()} 👤',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _MiniButton(
                        icon: Icons.open_in_full,
                        tooltip: 'Revenir à la réunion',
                        onTap: widget.data.onExpand,
                      ),
                      _MiniButton(
                        icon: Icons.call_end,
                        tooltip: 'Quitter la réunion',
                        color: AppColors.error,
                        onTap: widget.data.onEnd,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final track = widget.data.videoTrack?.call();

    if (track == null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white24,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              widget.data.meetingName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _windowSize.width,
          height: _windowSize.height - 34,
          child: VideoTrackRenderer(track),
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final IconData icon;

  final String tooltip;

  final Color color;

  final VoidCallback onTap;

  const _MiniButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = Colors.white70,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}
