import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../theme/colors.dart';
import '../models/meeting_model.dart';
import 'app_logo.dart';

class MeetingCard extends StatelessWidget {
  final MeetingModel meeting;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const MeetingCard({
    super.key,
    required this.meeting,
    required this.onTap,
    this.onDelete,
  });

  Color _getStatusColor(MeetingStatus status) {
    switch (status) {
      case MeetingStatus.ongoing:
        return AppColors.success;
      case MeetingStatus.ended:
        return AppColors.error;
      default:
        return AppColors.info;
    }
  }

  String _getStatusText(MeetingStatus status) {
    switch (status) {
      case MeetingStatus.ongoing:
        return 'EN COURS';
      case MeetingStatus.ended:
        return 'TERMINÉE';
      default:
        return 'PROGRAMMÉE';
    }
  }

  String _formatTime(DateTime time) {
    return DateFormat('HH:mm').format(time);
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor(meeting.status);
    final statusText = _getStatusText(meeting.status);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onDelete,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // VRAI logo CRUX (plus d'icône caméra en placeholder)
              const AppLogoBadge(size: 60, borderRadius: 14),
              const SizedBox(width: 16),

              // Infos réunion
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meeting.title,
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          Icons.person,
                          size: 12,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            meeting.organizer,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: AppColors.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.access_time,
                          size: 12,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatTime(meeting.startTime),
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // Status badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusText,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
