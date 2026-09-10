import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/locale_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/colors.dart';
import '../l10n/app_translations.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final lang = context.watch<LocaleProvider>().locale.languageCode;
    final bgColor = isDark ? const Color(0xFF0F0F0F) : const Color(0xFFF5F3FF);
    final textColor = isDark ? Colors.white : AppColors.textPrimary;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;

    final title = AppTranslations.t('privacy_policy', lang);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : AppColors.textPrimary,
          ),
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios,
            color: isDark ? Colors.white : AppColors.textPrimary,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(isDark: isDark, icon: Icons.shield_outlined, title: title),
            const SizedBox(height: 20),
            _Section(
              cardColor: cardColor,
              textColor: textColor,
              title: _t(
                lang,
                'Collecte des données',
                'Data Collection',
                'Recopilación de datos',
                'Datenerhebung',
              ),
              body: _t(
                lang,
                'CRUX collecte uniquement les informations nécessaires au bon fonctionnement du service : adresse e-mail, nom d\'affichage, et identifiants de réunion. Aucune donnée personnelle supplémentaire n\'est collectée sans votre consentement explicite.',
                'CRUX collects only the information necessary for the proper functioning of the service: email address, display name, and meeting identifiers. No additional personal data is collected without your explicit consent.',
                'CRUX recopila únicamente la información necesaria para el correcto funcionamiento del servicio: dirección de correo electrónico, nombre para mostrar e identificadores de reuniones. No se recopilan datos personales adicionales sin su consentimiento explícito.',
                'CRUX erhebt nur die Informationen, die für den ordnungsgemäßen Betrieb des Dienstes erforderlich sind: E-Mail-Adresse, Anzeigename und Meeting-Kennungen. Ohne Ihre ausdrückliche Zustimmung werden keine weiteren personenbezogenen Daten erhoben.',
              ),
            ),
            _Section(
              cardColor: cardColor,
              textColor: textColor,
              title: _t(
                lang,
                'Utilisation des données',
                'Use of Data',
                'Uso de datos',
                'Verwendung der Daten',
              ),
              body: _t(
                lang,
                'Vos données sont utilisées exclusivement pour :\n• Créer et gérer votre compte\n• Permettre les visioconférences\n• Envoyer des notifications pertinentes\n• Améliorer l\'expérience utilisateur\n\nVos données ne sont jamais vendues à des tiers.',
                'Your data is used exclusively to:\n• Create and manage your account\n• Enable video conferencing\n• Send relevant notifications\n• Improve the user experience\n\nYour data is never sold to third parties.',
                'Sus datos se utilizan exclusivamente para:\n• Crear y gestionar su cuenta\n• Habilitar videoconferencias\n• Enviar notificaciones relevantes\n• Mejorar la experiencia del usuario\n\nSus datos nunca se venden a terceros.',
                'Ihre Daten werden ausschließlich verwendet, um:\n• Ihr Konto zu erstellen und zu verwalten\n• Videokonferenzen zu ermöglichen\n• Relevante Benachrichtigungen zu senden\n• Das Nutzererlebnis zu verbessern\n\nIhre Daten werden niemals an Dritte verkauft.',
              ),
            ),
            _Section(
              cardColor: cardColor,
              textColor: textColor,
              title: _t(
                lang,
                'Stockage & Sécurité',
                'Storage & Security',
                'Almacenamiento y seguridad',
                'Speicherung & Sicherheit',
              ),
              body: _t(
                lang,
                'Toutes vos données sont stockées de manière sécurisée via Firebase (Google Cloud), avec chiffrement en transit et au repos. L\'accès à vos données est strictement limité et protégé par authentification.',
                'All your data is stored securely via Firebase (Google Cloud), with encryption in transit and at rest. Access to your data is strictly limited and protected by authentication.',
                'Todos sus datos se almacenan de forma segura a través de Firebase (Google Cloud), con cifrado en tránsito y en reposo. El acceso a sus datos está estrictamente limitado y protegido por autenticación.',
                'Alle Ihre Daten werden sicher über Firebase (Google Cloud) gespeichert, mit Verschlüsselung bei der Übertragung und im Ruhezustand. Der Zugriff auf Ihre Daten ist streng begrenzt und durch Authentifizierung geschützt.',
              ),
            ),
            _Section(
              cardColor: cardColor,
              textColor: textColor,
              title: _t(
                lang,
                'Vos droits',
                'Your Rights',
                'Sus derechos',
                'Ihre Rechte',
              ),
              body: _t(
                lang,
                'Vous disposez des droits suivants concernant vos données personnelles :\n• Droit d\'accès\n• Droit de rectification\n• Droit à l\'effacement\n• Droit à la portabilité\n\nPour exercer ces droits, contactez-nous à : kouakouchristevann@gmail.com',
                'You have the following rights regarding your personal data:\n• Right of access\n• Right of rectification\n• Right to erasure\n• Right to portability\n\nTo exercise these rights, contact us at: kouakouchristevann@gmail.com',
                'Tiene los siguientes derechos sobre sus datos personales:\n• Derecho de acceso\n• Derecho de rectificación\n• Derecho de supresión\n• Derecho a la portabilidad\n\nPara ejercer estos derechos, contáctenos en: kouakouchristevann@gmail.com',
                'Sie haben folgende Rechte bezüglich Ihrer personenbezogenen Daten:\n• Recht auf Zugang\n• Recht auf Berichtigung\n• Recht auf Löschung\n• Recht auf Übertragbarkeit\n\nUm diese Rechte auszuüben, kontaktieren Sie uns unter: kouakouchristevann@gmail.com',
              ),
            ),
            _Section(
              cardColor: cardColor,
              textColor: textColor,
              title: _t(
                lang,
                'Cookies & Traceurs',
                'Cookies & Trackers',
                'Cookies y rastreadores',
                'Cookies & Tracker',
              ),
              body: _t(
                lang,
                'CRUX utilise Firebase Analytics pour analyser anonymement l\'utilisation de l\'application et améliorer nos services. Aucun cookie publicitaire n\'est utilisé.',
                'CRUX uses Firebase Analytics to anonymously analyze app usage and improve our services. No advertising cookies are used.',
                'CRUX utiliza Firebase Analytics para analizar de forma anónima el uso de la aplicación y mejorar nuestros servicios. No se utilizan cookies publicitarias.',
                'CRUX verwendet Firebase Analytics, um die App-Nutzung anonym zu analysieren und unsere Dienste zu verbessern. Es werden keine Werbe-Cookies verwendet.',
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _t(
                  lang,
                  'Dernière mise à jour : Juin 2026',
                  'Last updated: June 2026',
                  'Última actualización: Junio 2026',
                  'Zuletzt aktualisiert: Juni 2026',
                ),
                style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  String _t(String lang, String fr, String en, String es, String de) {
    switch (lang) {
      case 'en':
        return en;
      case 'es':
        return es;
      case 'de':
        return de;
      default:
        return fr;
    }
  }
}

class _Header extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final String title;
  const _Header({
    required this.isDark,
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    // Carte sobre, alignée sur le style des sections (pas de dégradé criard).
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.primary, size: 48),
          const SizedBox(height: 12),
          Text(
            title,
            style: GoogleFonts.poppins(
              color: isDark ? Colors.white : AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final Color cardColor;
  final Color textColor;
  final String title;
  final String body;
  const _Section({
    required this.cardColor,
    required this.textColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: textColor,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
