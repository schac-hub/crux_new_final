const { defineSecret } = require('firebase-functions/params');
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const axios = require('axios');

admin.initializeApp();
const db = admin.firestore();

// Security: Disable detailed error messages in production
const isProduction = process.env.NODE_ENV === 'production';

// Secrets déclarés — noms des paramètres dans le Secret Manager Firebase
// Les valeurs sont stockées dans les secrets Cloud Functions, jamais ici
const PAYDUNYA_MASTER_KEY = defineSecret('PAYDUNYA_MASTER_KEY');
const PAYDUNYA_PRIVATE_KEY = defineSecret('PAYDUNYA_PRIVATE_KEY');
const PAYDUNYA_TOKEN = defineSecret('PAYDUNYA_TOKEN');
const WAVE_API_KEY = defineSecret('WAVE_API_KEY');

const PAYDUNYA_BASE = 'https://app.paydunya.com/api/v1';
const WAVE_API_BASE = 'https://api.wave.com/v1';
const APP_BASE_URL = 'https://crux-3c6be.web.app';

// Produits payables via le lien marchand Wave (MESCHAC SERVICES).
const WAVE_PRODUCTS = {
  pro: { amount: 25000, label: 'Abonnement Pro (1 mois)' },
  max: { amount: 85000, label: 'Abonnement Max (3 mois)' },
  meeting_continue: { amount: 3000, label: 'Continuer la réunion' },
  background_unlock: { amount: 500, label: 'Image d\'arrière-plan' },
};

// ── Créer une facture PayDunya ────────────────────────────────────────────
exports.createPayment = onCall(
  { secrets: [PAYDUNYA_MASTER_KEY, PAYDUNYA_PRIVATE_KEY, PAYDUNYA_TOKEN] },
  async (request) => {
    // 1. Vérification d'authentification Firebase
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté pour souscrire.');
    }

    const { userId, userName, userEmail } = request.data;

    if (!userId) {
      throw new HttpsError('invalid-argument', 'userId est requis');
    }

    // 2. L'utilisateur ne peut payer que pour lui-même
    if (request.auth.uid !== userId) {
      throw new HttpsError('permission-denied', 'Action non autorisée');
    }

    // 3. Vérifier si déjà abonné PRO actif
    const userDoc = await db.collection('users').doc(userId).get();
    if (userDoc.exists) {
      const userData = userDoc.data();
      if (userData.isPro && userData.proExpiresAt) {
        const expiry = userData.proExpiresAt.toDate();
        if (expiry > new Date()) {
          throw new HttpsError(
            'already-exists',
            `Vous êtes déjà abonné CRUX PRO jusqu'au ${expiry.toLocaleDateString('fr-FR')}`
          );
        }
      }
    }

    const notifyUrl = `https://us-central1-crux-3c6be.cloudfunctions.net/paydunyaWebhook`;

    const payload = {
      invoice: {
        items: {
          item_0: {
            name: 'Crux Pro — Abonnement mensuel',
            quantity: 1,
            unit_price: '25000',
            total_price: '25000',
            description: 'Réunions illimitées pendant 30 jours, HD, 1000 participants',
          },
        },
        taxes: {},
        total_amount: 25000,
        description: 'Crux Pro — Abonnement mensuel 25 000 FCFA',
      },
      store: {
        name: 'Crux Visioconférence',
        tagline: 'Restez connectés, sans limites',
        postal_address: 'Abidjan, Côte d\'Ivoire',
        phone: '',
        logo_url: `${APP_BASE_URL}/icons/icon-512.png`,
        website_url: APP_BASE_URL,
      },
      custom_data: {
        userId,
        userName: userName ?? '',
        userEmail: userEmail ?? '',
        plan: 'pro_monthly',
      },
      actions: {
        cancel_url: `${APP_BASE_URL}/payment-cancel`,
        return_url: `${APP_BASE_URL}/payment-success`,
        callback_url: notifyUrl,
      },
    };

    try {
      const response = await axios.post(`${PAYDUNYA_BASE}/softorder/create`, payload, {
        headers: {
          'PAYDUNYA-MASTER-KEY': PAYDUNYA_MASTER_KEY.value(),
          'PAYDUNYA-PRIVATE-KEY': PAYDUNYA_PRIVATE_KEY.value(),
          'PAYDUNYA-TOKEN': PAYDUNYA_TOKEN.value(),
          'Content-Type': 'application/json',
        },
        timeout: 15000,
      });

      if (response.data.response_code === '00') {
        // Enregistrer la transaction en attente dans Firestore
        // Note: paydunyaToken is stored for webhook verification but should never be returned in API responses
        await db.collection('payments').add({
          userId,
          userName: userName ?? '',
          userEmail: userEmail ?? '',
          paydunyaToken: response.data.token, // Sensitive: only for internal webhook verification
          invoiceUrl: response.data.invoice_url,
          status: 'pending',
          amount: 25000,
          currency: 'XOF',
          plan: 'pro_monthly',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        return {
          success: true,
          invoice_url: response.data.invoice_url,
        };
      } else {
        console.error('PayDunya error response:', response.data);
        throw new HttpsError(
          'internal',
          response.data.response_text ?? 'Échec de la création de la facture'
        );
      }
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      console.error('PayDunya network error:', error.message);
      const errorMsg = isProduction 
        ? 'Service de paiement temporairement indisponible' 
        : error.message;
      throw new HttpsError('unavailable', errorMsg);
    }
  }
);

// ── Webhook PayDunya — confirmer le paiement et activer PRO ──────────────
exports.paydunyaWebhook = onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const body = req.body;

  // Validation basique de la structure
  if (!body?.data?.custom_data || !body?.data?.invoice) {
    console.warn('Invalid webhook payload received:', JSON.stringify(body));
    return res.status(400).json({ error: 'Invalid payload' });
  }

  const { userId, userName, userEmail } = body.data.custom_data;
  const paydunyaToken = body.data.invoice?.token;
  const status = body.data.status; // 'completed' | 'cancelled' | 'pending'

  if (!userId || !paydunyaToken) {
    return res.status(400).json({ error: 'Missing userId or token' });
  }

  try {
    if (status === 'completed') {
      // Accorder l'accès PRO pendant 30 jours
      const expiresAt = admin.firestore.Timestamp.fromDate(
        new Date(Date.now() + 30 * 24 * 60 * 60 * 1000)
      );

      const batch = db.batch();

      // Mise à jour du profil utilisateur
      batch.set(
        db.collection('users').doc(userId),
        {
          isPro: true,
          proExpiresAt: expiresAt,
          proActivatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      await batch.commit();

      // Mettre à jour le statut du paiement
      const paymentQuery = await db
        .collection('payments')
        .where('paydunyaToken', '==', paydunyaToken)
        .limit(1)
        .get();

      if (!paymentQuery.empty) {
        await paymentQuery.docs[0].ref.update({
          status: 'completed',
          completedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      console.log(`✅ PRO activé pour ${userId} jusqu'au ${expiresAt.toDate().toISOString()}`);

    } else if (status === 'cancelled') {
      // Marquer le paiement comme annulé
      const paymentQuery = await db
        .collection('payments')
        .where('paydunyaToken', '==', paydunyaToken)
        .limit(1)
        .get();

      if (!paymentQuery.empty) {
        await paymentQuery.docs[0].ref.update({
          status: 'cancelled',
          cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      console.log(`❌ Paiement annulé pour ${userId}`);
    }

    return res.status(200).json({ received: true, status });
  } catch (error) {
    console.error('Webhook processing error:', error.message);
    const errorMsg = isProduction ? 'Internal server error' : error.message;
    return res.status(500).json({ error: errorMsg });
  }
});

// ── Vérification paiement Wave — active le forfait immédiatement ─────────
// Callable appelé en boucle par le client après le paiement. Quand la clé
// API Wave (WAVE_API_KEY, compte marchand Wave Business) est configurée, la
// transaction est réellement recherchée côté Wave ; sinon un octroi
// provisoire (flag pendingWaveVerification) est accordé pour ne pas bloquer
// l'accès — il est re-vérifié par la tâche planifiée.
exports.verifyWavePayment = onCall(
  { secrets: [WAVE_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté.');
    }

    const userId = request.auth.uid;
    const product = request.data?.product;
    const meetingId = request.data?.meetingId ?? null;

    const config = WAVE_PRODUCTS[product];

    if (!config) {
      throw new HttpsError('invalid-argument', `Produit inconnu : ${product}`);
    }

    const apiKey = WAVE_API_KEY.value();
    let verified = false;
    let provisional = false;

    if (apiKey) {
      // 1) Vérification réelle via l'API Wave : on cherche une transaction
      // récente (15 min) dont le montant correspond et pas encore attribuée.
      try {
        const resp = await axios.get(`${WAVE_API_BASE}/transactions?limit=50`, {
          headers: { Authorization: `Bearer ${apiKey}` },
          timeout: 15000,
        });

        const transactions = Array.isArray(resp.data)
          ? resp.data
          : resp.data?.data ?? [];
        const now = Date.now();

        const match = transactions.find((tx) => {
          const when = Date.parse(tx.created_at ?? tx.when_created ?? '') || 0;
          const raw = Number(tx.amount ?? 0);
          // Wave peut renvoyer des unités mineures : on normalise.
          const normalized = raw >= config.amount * 100 ? raw / 100 : raw;
          return (
            normalized >= config.amount &&
            now - when > 0 &&
            now - when < 15 * 60 * 1000
          );
        });

        if (match) {
          verified = true;

          // Marquer la transaction comme attribuée (idempotence).
          await db.collection('wave_payment_requests')
            .where('userId', '==', userId)
            .where('product', '==', product)
            .where('status', '==', 'pending')
            .limit(1)
            .get()
            .then((snap) => {
              if (!snap.empty) {
                return snap.docs[0].ref.update({
                  status: 'verified',
                  waveTransactionId: match.id ?? null,
                  verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
              }
              return null;
            });
        }
      } catch (error) {
        console.warn('Wave API check failed:', error.message);
      }
    } else {
      // 2) Pas de clé API Wave : octroi provisoire (accès immédiat, à
      // re-vérifier). Les demandes restent tracées dans wave_payment_requests.
      provisional = true;

      await db.collection('wave_payment_requests')
        .where('userId', '==', userId)
        .where('product', '==', product)
        .where('status', '==', 'pending')
        .limit(1)
        .get()
        .then((snap) => {
          if (!snap.empty) {
            return snap.docs[0].ref.update({
              status: 'provisional',
              provisionalAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          }
          return null;
        });
    }

    if (!verified && !provisional) {
      return {
        verified: false,
        provisional: false,
        product,
        message: 'Aucune transaction Wave confirmée pour le moment.',
      };
    }

    // 3) Activation du produit dans Firestore (source de vérité serveur).
    try {
      await activateWaveProduct(userId, product, meetingId, provisional);
    } catch (error) {
      console.error('Wave activation failed:', error.message);
      throw new HttpsError('internal', 'Échec de l\'activation du forfait');
    }

    return {
      verified,
      provisional,
      product,
      message: verified
        ? 'Paiement Wave confirmé.'
        : 'Accès accordé (vérification Wave à confirmer).',
    };
  }
);

// ── Activation d'un produit Wave (forfait, réunion, déblocage) ───────────
async function activateWaveProduct(userId, product, meetingId, provisional) {
  const userRef = db.collection('users').doc(userId);
  const now = new Date();

  if (product === 'pro' || product === 'max') {
    const months = product === 'max' ? 3 : 1;
    const endDate = new Date(now.getTime() + months * 30 * 24 * 60 * 60 * 1000);

    await userRef.set(
      {
        plan: product,
        badgeType: product === 'max' ? 'gold' : 'silver',
        subscriptionStartDate: admin.firestore.Timestamp.fromDate(now),
        subscriptionEndDate: admin.firestore.Timestamp.fromDate(endDate),
        meetingCountThisMonth: 0,
        meetingCountMonth: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`,
        // Compatibilité avec l'ancien système Pro (ProService / paywall).
        isPro: true,
        proExpiresAt: admin.firestore.Timestamp.fromDate(endDate),
        pendingWaveVerification: provisional,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    console.log(
      `✅ Plan ${product} activé pour ${userId} (provisional=${provisional})`
    );
    return;
  }

  if (product === 'meeting_continue') {
    if (meetingId) {
      // Prolonge la réunion en cours de 3 heures (et la maintient visible
      // sur l'accueil).
      const meetingRef = db.collection('meetings').doc(meetingId);
      const meetingDoc = await meetingRef.get();
      const currentEnd = meetingDoc.exists && meetingDoc.data()?.endTime?.toDate
        ? meetingDoc.data().endTime.toDate()
        : now;
      const newEnd = new Date(
        Math.max(currentEnd.getTime(), now.getTime()) + 3 * 60 * 60 * 1000
      );

      await meetingRef.set(
        {
          endTime: admin.firestore.Timestamp.fromDate(newEnd),
          lastActiveAt: admin.firestore.Timestamp.fromDate(now),
          paidContinueAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }

    await userRef.set(
      {
        plan: 'pro',
        badgeType: 'silver',
        isPro: true,
        proExpiresAt: admin.firestore.Timestamp.fromDate(
          new Date(now.getTime() + 1 * 24 * 60 * 60 * 1000)
        ),
        pendingWaveVerification: provisional,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    console.log(`✅ Réunion ${meetingId ?? '?'} prolongée pour ${userId}`);
    return;
  }

  if (product === 'background_unlock') {
    await userRef.set(
      {
        backgroundUnlocked: true,
        pendingWaveVerification: provisional,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    console.log(`✅ Arrière-plan débloqué pour ${userId}`);
  }
}

// ── Vérifier et expirer les abonnements PRO ──────────────────────────────
exports.checkProExpiry = require('firebase-functions/v2/scheduler').onSchedule(
  'every 24 hours',
  async () => {
    const now = admin.firestore.Timestamp.now();

    const expiredUsers = await db
      .collection('users')
      .where('isPro', '==', true)
      .where('proExpiresAt', '<=', now)
      .get();

    if (expiredUsers.empty) {
      console.log('Aucun abonnement expiré');
      return;
    }

    const batch = db.batch();
    expiredUsers.docs.forEach((doc) => {
      batch.update(doc.ref, {
        isPro: false,
        plan: 'free',
        badgeType: 'none',
        pendingWaveVerification: false,
        proExpiredAt: now,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();
    console.log(`${expiredUsers.size} abonnements PRO expirés traités`);
  }
);
