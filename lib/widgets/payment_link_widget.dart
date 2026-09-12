import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/user_model.dart';
import '../services/payment_service.dart';

class PaymentLinkWidget extends StatelessWidget {
  final String? paymentLink;
  final SubscriptionPlan plan;
  final String userName;
  final VoidCallback? onPayPressed;
  final VoidCallback? onVerifyPressed;

  const PaymentLinkWidget({
    super.key,
    required this.paymentLink,
    required this.plan,
    required this.userName,
    this.onPayPressed,
    this.onVerifyPressed,
  });

  /// Ouvre le lien de paiement Wave dans le navigateur
  Future<void> _openPaymentLink() async {
    if (paymentLink != null && paymentLink!.isNotEmpty) {
      final uri = Uri.tryParse(paymentLink!);

      if (uri == null) return;

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch $uri';
      }
    }
  }

  /// Affiche un toast de verification (simule la verification Wave)
  void _showVerificationToast(BuildContext context) {
    // En production, ceci déclencherait la verification via l'API Wave
    // Pour l'instant, on simule avec un message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Verification de paiement en cours...'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFree = plan == SubscriptionPlan.free;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: Theme.of(context).cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // En-tête avec icône Wave
            Row(
              children: [
                // Icône Wave
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.payment,
                    color: Colors.blue,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                // Texte du plan
                Expanded(
                  child: Text(
                    _getPlanLabel(plan),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // Montant
                if (!isFree) _buildAmount(),
              ],
            ),
            const SizedBox(height: 12),

            // Lien de paiement
            _buildPaymentLink(context),

            const SizedBox(height: 12),

            // Actions
            Row(
              children: [
                // Bouton Payer
                if (!isFree)
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onPayPressed ?? _openPaymentLink,
                      icon: const Icon(Icons.money),
                      label: Text(
                        isFree ? 'Gratuit' : 'Payer',
                        style: const TextStyle(color: Colors.white),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),

                // Bouton Vérifier
                if (onVerifyPressed != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _showVerificationToast(context);
                        onVerifyPressed!();
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Vérifier'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Lien de paiement Wave affiché (ou masqué si absent).
  Widget _buildPaymentLink(BuildContext context) {
    final link = paymentLink;

    if (link == null || link.isEmpty) {
      return const SizedBox.shrink();
    }

    return InkWell(
      onTap: _openPaymentLink,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link, color: Colors.blue, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Payer avec Wave — toucher pour ouvrir',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAmount() {
    // Forfait → produit Wave correspondant (montant officiel).
    final product = plan == SubscriptionPlan.max
        ? WaveProduct.max
        : WaveProduct.pro;

    final amount = product.amountFcfa;

    if (amount == 0) return const SizedBox.shrink();

    // Séparateur de milliers : 25000 -> « 25 000 ».
    final formatted = amount.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (match) => ' ',
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$formatted FCFA',
          style: const TextStyle(
            color: Colors.green,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          'XOF',
          style: TextStyle(
            color: Colors.green,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  String _getPlanLabel(SubscriptionPlan plan) {
    switch (plan) {
      case SubscriptionPlan.free:
        return 'Free';
      case SubscriptionPlan.pro:
        return 'Pro';
      case SubscriptionPlan.max:
        return 'Max';
    }
  }
}