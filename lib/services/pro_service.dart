import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:url_launcher/url_launcher.dart';

class ProService {
  static final ProService _instance = ProService._internal();
  factory ProService() => _instance;
  ProService._internal();

  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instance;

  static const _priceXof = 25000;

  /// Pro si l'ancien système (isPro + proExpiresAt) OU le nouveau système de
  /// forfaits (plan pro/max + subscriptionEndDate valide) est actif.
  /// Lecture directe de la doc : l'accès aux fonctionnalités est donc
  /// immédiat dès que le paiement est activé.
  static bool _isProData(Map<String, dynamic> data) {
    // ── Ancien système ──
    if (data['isPro'] == true) {
      final expiresAt = data['proExpiresAt'];
      DateTime? expiry;
      if (expiresAt is Timestamp) {
        expiry = expiresAt.toDate();
      } else if (expiresAt is String) {
        expiry = DateTime.tryParse(expiresAt);
      } else if (expiresAt is int) {
        expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt);
      }
      if (expiry != null && expiry.isAfter(DateTime.now())) return true;
    }

    // ── Nouveau système de forfaits (Wave / PaymentService) ──
    final plan = data['plan']?.toString();
    if (plan == 'pro' || plan == 'max') {
      final endDate = data['subscriptionEndDate'];
      DateTime? expiry;
      if (endDate is Timestamp) {
        expiry = endDate.toDate();
      } else if (endDate is String) {
        expiry = DateTime.tryParse(endDate);
      }
      // Pas de date de fin = abonnement considéré actif (free plan exclu).
      if (expiry == null || expiry.isAfter(DateTime.now())) return true;
    }

    return false;
  }

  Future<bool> checkProStatus(String userId) async {
    try {
      final doc = await _db.collection('users').doc(userId).get();
      if (!doc.exists) return false;
      return _isProData(doc.data()!);
    } catch (_) {
      return false;
    }
  }

  Stream<bool> proStream(String userId) {
    return _db.collection('users').doc(userId).snapshots().map((snap) {
      if (!snap.exists) return false;
      return _isProData(snap.data()!);
    });
  }

  Future<Map<String, dynamic>?> startPayment({
    required String userId,
    required String userName,
    String? userEmail,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Vous devez être connecté pour souscrire.');
    }
    if (user.uid != userId) {
      throw Exception('Action non autorisée.');
    }

    try {
      final result = await _functions.httpsCallable('createPayment').call({
        'userId': userId,
        'userName': userName,
        'userEmail': userEmail,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final invoiceUrl = data['invoice_url'] as String?;

      if (invoiceUrl != null && invoiceUrl.isNotEmpty) {
        final uri = Uri.parse(invoiceUrl);
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        }
      }

      return data;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Erreur de paiement');
    } catch (e) {
      rethrow;
    }
  }

  int get priceXof => _priceXof;
}
