import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/user_model.dart';
import '../services/payment_service.dart';
import '../theme/colors.dart';
import '../utils/logger.dart';
import '../widgets/elegant_toast.dart';

/// Écran d'abonnement CRUX — paiement Wave (MESCHAC SERVICES).
///
/// Pro : 25 000 F / mois (badge argent, 10 réunions/mois).
/// Max : 85 000 F / 3 mois (badge or, tout illimité).
///
/// Flux « accès immédiat » : l'utilisateur ouvre le lien Wave, paie, et
/// l'app vérifie automatiquement en boucle (Cloud Function
/// `verifyWavePayment`) — dès confirmation, le forfait est actif.
class ProScreen extends StatefulWidget {
  const ProScreen({super.key});

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  final PaymentService _paymentService = PaymentService();

  bool _paying = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> _subscribe(WaveProduct product) async {
    if (_uid == null) {
      ElegantToast.show(
        context,
        title: 'Erreur',
        message: 'Session expirée, reconnecte-toi',
        type: ElegantToastType.error,
      );
      return;
    }

    setState(() => _paying = true);

    try {
      // Ouvre le lien Wave (montant pré-rempli) et trace la demande.
      await _paymentService.openWaveLink(product: product);
    } catch (e) {
      logger.e('ProScreen.openWaveLink error', error: e);
      if (mounted) {
        ElegantToast.show(
          context,
          title: 'Erreur',
          message: 'Impossible d\'ouvrir le lien de paiement Wave',
          type: ElegantToastType.error,
        );
      }
      if (mounted) setState(() => _paying = false);
      return;
    }

    if (!mounted) return;

    // Vérification automatique en boucle jusqu'à confirmation (ou ~5 min).
    final verified = await _pollUntilVerified(product);

    if (!mounted) return;

    setState(() => _paying = false);

    if (verified) {
      ElegantToast.show(
        context,
        title: 'Abonnement activé 🎉',
        message: 'Ton forfait ${product == WaveProduct.max ? 'Max' : 'Pro'} '
            'est actif — fonctionnalités et badge disponibles !',
        type: ElegantToastType.success,
      );
    } else {
      ElegantToast.show(
        context,
        title: 'Paiement non détecté',
        message: 'Termine le paiement Wave puis réessaie.',
        type: ElegantToastType.info,
      );
    }
  }

  /// Boîte de dialogue de vérification : affiche l'avancement, se ferme
  /// d'elle-même dès que le serveur confirme le paiement.
  Future<bool> _pollUntilVerified(WaveProduct product) async {
    var attempt = 1;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        // La boucle démarre avec la dialog ; chaque tentative rafraîchit
        // le compteur, la confirmation ferme la boîte avec `true`.
        unawaited(
          _paymentService
              .pollVerification(product, attempts: 20, onAttempt: (n) {
            attempt = n;
            if (dialogContext.mounted) {
              (dialogContext as Element).markNeedsBuild();
            }
          })
              .then((verified) {
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop(verified);
            }
          }),
        );

        return PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                backgroundColor: AppColors.surface,
                title: Text(
                  'Vérification du paiement…',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'Termine ton paiement Wave. Vérification automatique '
                      'en cours (tentative $attempt)…',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Forfaits CRUX',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<UserModel?>(
              stream: _paymentService.watchUser(uid),
              builder: (context, snapshot) {
                final user = snapshot.data;

                return SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choisis ton forfait',
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Paiement Wave en un clic — accès immédiat après '
                          'vérification automatique.',
                          style: GoogleFonts.poppins(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _PlanCard(
                          title: 'PRO',
                          badgeColor: Colors.grey[300]!,
                          price: '25 000 F',
                          period: '/ mois',
                          features: const [
                            '10 réunions par mois',
                            'Réunions sans limite de durée',
                            'Toutes les fonctionnalités pro',
                            'Badge argent sur ton profil',
                          ],
                          isCurrentPlan:
                              user?.effectivePlan == SubscriptionPlan.pro,
                          loading: _paying,
                          onPay: () => _subscribe(WaveProduct.pro),
                        ),
                        const SizedBox(height: 16),
                        _PlanCard(
                          title: 'MAX',
                          badgeColor: Colors.amber[300]!,
                          price: '85 000 F',
                          period: '/ 3 mois',
                          highlighted: true,
                          features: const [
                            'Réunions illimitées en tout point',
                            'Toutes les fonctionnalités de l\'app',
                            'Priorité absolue',
                            'Badge or sur ton profil',
                          ],
                          isCurrentPlan:
                              user?.effectivePlan == SubscriptionPlan.max,
                          loading: _paying,
                          onPay: () => _subscribe(WaveProduct.max),
                        ),
                        const SizedBox(height: 24),
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.verified_user_outlined,
                                color: Colors.white38,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Paiement sécurisé via Wave — MESCHAC SERVICES',
                                style: GoogleFonts.poppins(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String title;
  final Color badgeColor;
  final String price;
  final String period;
  final List<String> features;
  final bool highlighted;
  final bool isCurrentPlan;
  final bool loading;
  final VoidCallback onPay;

  const _PlanCard({
    required this.title,
    required this.badgeColor,
    required this.price,
    required this.period,
    required this.features,
    this.highlighted = false,
    this.isCurrentPlan = false,
    this.loading = false,
    required this.onPay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlighted ? AppColors.primary : AppColors.border,
          width: highlighted ? 1.6 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.star, color: badgeColor, size: 20),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: GoogleFonts.poppins(
                  color: badgeColor,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (isCurrentPlan)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Forfait actuel',
                    style: GoogleFonts.poppins(
                      color: Colors.greenAccent,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: price,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: ' $period',
                  style: GoogleFonts.poppins(
                    color: Colors.white38,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ...features.map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: AppColors.primary,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f,
                      style: GoogleFonts.poppins(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (loading || isCurrentPlan) ? null : onPay,
              icon: const Icon(Icons.payment, size: 18),
              label: Text(
                isCurrentPlan
                    ? 'Déjà actif'
                    : loading
                        ? 'Ouverture de Wave…'
                        : 'Payer avec Wave',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    AppColors.primary.withValues(alpha: 0.4),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
