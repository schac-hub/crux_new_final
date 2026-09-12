import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:logger/logger.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/user_model.dart';

/// Produits payables via le lien marchand Wave MESCHAC SERVICES.
enum WaveProduct {
  /// Abonnement Pro : 25 000 F / mois, badge argent, 10 réunions/mois.
  pro('pro', 25000),

  /// Abonnement Max : 85 000 F / 3 mois, badge or, tout illimité.
  max('max', 85000),

  /// Prolongation de la réunion en cours : 3 000 F.
  meetingContinue('meeting_continue', 3000),

  /// Déblocage de la fonctionnalité « image d'arrière-plan » : 500 F.
  backgroundUnlock('background_unlock', 500);

  const WaveProduct(this.id, this.amountFcfa);

  final String id;
  final int amountFcfa;

  static WaveProduct fromId(String? id) {
    for (final product in WaveProduct.values) {
      if (product.id == id) return product;
    }
    return WaveProduct.pro;
  }
}

/// Résultat d'une vérification de paiement Wave.
class WaveVerification {
  const WaveVerification({
    required this.verified,
    required this.product,
    this.provisional = false,
    this.message,
  });

  final bool verified;
  final WaveProduct product;

  /// true = accordé sans confirmation Wave API (clé non configurée) :
  /// l'accès est ouvert immédiatement mais marqué à re-vérifier.
  final bool provisional;
  final String? message;
}

/// Système de paiement Wave de CRUX.
///
/// L'utilisateur ouvre le lien marchand Wave (montant pré-rempli), paie
/// depuis l'app Wave, puis l'app interroge la Cloud Function
/// `verifyWavePayment` en boucle : dès que la fonction confirme (ou accorde
/// un octroi provisoire), elle écrit le forfait dans Firestore et l'accès
/// aux fonctionnalités est immédiat via le stream du document utilisateur.
class PaymentService {
  final _logger = Logger();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Lien marchand Wave (MESCHAC SERVICES) — le montant est pré-rempli.
  static const String _waveBaseUrl =
      'https://pay.wave.com/m/M_ci_BvxgYGaX0ON9/c/ci/';

  // ---------------------------------------------------------------------------
  // LIENS WAVE
  // ---------------------------------------------------------------------------

  String waveLinkFor(WaveProduct product) {
    return '$_waveBaseUrl?amount=${product.amountFcfa}';
  }

  /// Ouvre le lien Wave dans le navigateur / l'app Wave et enregistre une
  /// demande de paiement « pending » (base de la vérification automatique).
  Future<void> openWaveLink({required WaveProduct product}) async {
    final uid = _auth.currentUser?.uid;

    if (uid != null) {
      try {
        await _db.collection('wave_payment_requests').add({
          'userId': uid,
          'product': product.id,
          'amount': product.amountFcfa,
          'currency': 'XOF',
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        _logger.w('Could not record wave payment request: $e');
      }
    }

    final uri = Uri.parse(waveLinkFor(product));

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Certains navigateurs/webviews exigent le mode par défaut.
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  // ---------------------------------------------------------------------------
  // VÉRIFICATION AUTOMATIQUE
  // ---------------------------------------------------------------------------

  /// Interroge la Cloud Function `verifyWavePayment`.
  ///
  /// La fonction (serveur) vérifie la transaction Wave quand la clé API
  /// `WAVE_API_KEY` est configurée ; sinon elle accorde un octroi
  /// provisoire pour ne pas bloquer l'accès. Dans les deux cas le forfait
  /// est écrit dans Firestore par le serveur.
  Future<WaveVerification> verifyProduct(
    WaveProduct product, {
    String? meetingId,
  }) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'verifyWavePayment',
      );

      final result = await callable.call({
        'product': product.id,
        if (meetingId != null) 'meetingId': meetingId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      final verified = data['verified'] == true;
      final provisional = data['provisional'] == true;

      _logger.i(
        'verifyWavePayment(${product.id}) → verified=$verified, '
        'provisional=$provisional',
      );

      return WaveVerification(
        verified: verified,
        provisional: provisional,
        product: product,
        message: data['message']?.toString(),
      );
    } on FirebaseFunctionsException catch (e) {
      _logger.w('verifyWavePayment failed: ${e.code} ${e.message}');

      return WaveVerification(
        verified: false,
        product: product,
        message: e.message ?? e.code,
      );
    } catch (e) {
      _logger.w('verifyWavePayment error: $e');

      return WaveVerification(
        verified: false,
        product: product,
        message: e.toString(),
      );
    }
  }

  /// Boucle de vérification automatique : interroge le serveur toutes les
  /// [interval] secondes jusqu'à confirmation ou épuisement des [attempts].
  Future<bool> pollVerification(
    WaveProduct product, {
    Duration interval = const Duration(seconds: 15),
    int attempts = 20,
    String? meetingId,
    void Function(int attempt)? onAttempt,
  }) async {
    for (var i = 1; i <= attempts; i++) {
      onAttempt?.call(i);

      final result = await verifyProduct(product, meetingId: meetingId);

      if (result.verified) return true;

      await Future<void>.delayed(interval);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // PROFIL UTILISATEUR
  // ---------------------------------------------------------------------------

  /// Stream du profil (forfait, badge, déblocages) — l'UI réagit en direct
  /// dès que le serveur active un paiement.
  Stream<UserModel?> watchUser(String userId) {
    return _db.collection('users').doc(userId).snapshots().map(
          (snap) => snap.exists
              ? UserModel.fromJson(snap.data() ?? <String, dynamic>{})
              : null,
        );
  }

  Future<UserModel?> fetchUser(String userId) async {
    final snap = await _db.collection('users').doc(userId).get();

    if (!snap.exists) return null;

    return UserModel.fromJson(snap.data() ?? <String, dynamic>{});
  }

  /// L'utilisateur a-t-il débloqué l'image d'arrière-plan (500 F) ?
  Future<bool> isBackgroundUnlocked(String userId) async {
    final snap = await _db.collection('users').doc(userId).get();

    return snap.data()?['backgroundUnlocked'] == true;
  }

  // ---------------------------------------------------------------------------
  // RÈGLES DE FORFAIT
  // ---------------------------------------------------------------------------

  /// L'abonnement est-il actif ? (free toujours actif)
  bool isSubscriptionActive(UserModel user) => user.isSubscriptionActive;

  /// Le quota de réunions du mois est-il dépassé ?
  bool hasExceededLimit(UserModel user, {int additionalMeetings = 1}) {
    final plan = user.effectivePlan;

    if (plan.isUnlimitedMeetings) return false;

    return user.meetingCountThisMonth + additionalMeetings > plan.meetingLimit;
  }

  /// Incrémente le compteur de réunions du mois.
  Future<void> incrementMeetingCount({
    required String userId,
    int count = 1,
  }) async {
    final userRef = _db.collection('users').doc(userId);

    await userRef.set({
      'meetingCountThisMonth': FieldValue.increment(count),
      'meetingCountMonth': _monthKey(DateTime.now()),
      'uid': userId,
    }, SetOptions(merge: true));
  }

  /// Remet le compteur à zéro quand le mois change.
  Future<void> resetMonthlyCounterIfNeeded(String userId) async {
    final userRef = _db.collection('users').doc(userId);
    final snap = await userRef.get();
    final data = snap.data();

    if (data == null) return;

    final storedMonth = data['meetingCountMonth']?.toString();
    final currentMonth = _monthKey(DateTime.now());

    if (storedMonth == currentMonth) return;

    await userRef.set({
      'meetingCountThisMonth': 0,
      'meetingCountMonth': currentMonth,
    }, SetOptions(merge: true));
  }

  String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';
}
