import 'package:flutter/material.dart';

import '../utils/date_flex.dart';

/// Durée d'une réunion sur le forfait gratuit : 1 h 45 min.
const Duration freeTierDuration = Duration(minutes: 105);

/// Préavis avant la fin du temps gratuit : 10 minutes.
const Duration freeTierWarningDuration = Duration(minutes: 10);

enum SubscriptionPlan { free, pro, max }

extension SubscriptionPlanExtension on SubscriptionPlan {
  int get meetingLimit {
    switch (this) {
      case SubscriptionPlan.free:
        return 3;
      case SubscriptionPlan.pro:
        return 10;
      case SubscriptionPlan.max:
        return 999999; // illimité
    }
  }

  bool get isUnlimitedMeetings => this == SubscriptionPlan.max;

  static SubscriptionPlan fromName(String? name) {
    for (final plan in SubscriptionPlan.values) {
      if (plan.name == name) return plan;
    }
    return SubscriptionPlan.free;
  }
}

enum BadgeType { none, silver, gold }

extension BadgeTypeExtension on BadgeType {
  Color get color {
    switch (this) {
      case BadgeType.none:
        return Colors.transparent;
      case BadgeType.silver:
        return Colors.grey[300]!;
      case BadgeType.gold:
        return Colors.amber[300]!;
    }
  }

  static BadgeType fromName(String? name) {
    for (final badge in BadgeType.values) {
      if (badge.name == name) return badge;
    }
    return BadgeType.none;
  }
}

class UserModel {
  final String uid;
  final String email;
  final String name;
  final String? profileImageUrl;
  final DateTime? createdAt;
  final bool isOnline;
  final SubscriptionPlan plan;
  final int meetingCountThisMonth;
  final DateTime? subscriptionStartDate;
  final DateTime? subscriptionEndDate;
  final BadgeType badgeType;

  UserModel({
    required this.uid,
    required this.email,
    required this.name,
    this.profileImageUrl,
    this.createdAt,
    this.isOnline = false,
    this.plan = SubscriptionPlan.free,
    this.meetingCountThisMonth = 0,
    this.subscriptionStartDate,
    this.subscriptionEndDate,
    this.badgeType = BadgeType.none,
  });

  /// L'abonnement est-il encore actif ? Un forfait free l'est toujours.
  bool get isSubscriptionActive {
    if (plan == SubscriptionPlan.free) return true;
    final end = subscriptionEndDate;
    if (end == null) return false;
    return DateTime.now().isBefore(end);
  }

  /// Le plan réel tient compte de l'expiration : un abonnement expiré
  /// retombe sur le forfait gratuit partout dans l'app.
  SubscriptionPlan get effectivePlan =>
      isSubscriptionActive ? plan : SubscriptionPlan.free;

  BadgeType get effectiveBadgeType =>
      isSubscriptionActive ? badgeType : BadgeType.none;

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'email': email,
      'name': name,
      'profileImageUrl': profileImageUrl,
      'createdAt': createdAt?.toIso8601String(),
      'isOnline': isOnline,
      'plan': plan.name,
      'meetingCountThisMonth': meetingCountThisMonth,
      'subscriptionStartDate': subscriptionStartDate?.toIso8601String(),
      'subscriptionEndDate': subscriptionEndDate?.toIso8601String(),
      'badgeType': badgeType.name,
    };
  }

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      uid: json['uid']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      profileImageUrl: json['profileImageUrl']?.toString(),
      createdAt: flexDateOrNull(json['createdAt']),
      isOnline: json['isOnline'] == true,
      plan: SubscriptionPlanExtension.fromName(json['plan']?.toString()),
      meetingCountThisMonth:
          (json['meetingCountThisMonth'] as num?)?.toInt() ?? 0,
      subscriptionStartDate: flexDateOrNull(json['subscriptionStartDate']),
      subscriptionEndDate: flexDateOrNull(json['subscriptionEndDate']),
      badgeType: BadgeTypeExtension.fromName(json['badgeType']?.toString()),
    );
  }

  /// Construit un modèle depuis le compte Firebase Auth (photo incluse).
  factory UserModel.fromFirebaseUser(dynamic user) {
    final photo = user.photoURL?.toString();
    final displayName = user.displayName?.toString() ?? '';
    final email = user.email?.toString() ?? '';

    return UserModel(
      uid: user.uid as String,
      email: email,
      name: displayName.isNotEmpty ? displayName : email.split('@').first,
      profileImageUrl: (photo != null && photo.isNotEmpty) ? photo : null,
    );
  }

  UserModel copyWith({
    String? uid,
    String? email,
    String? name,
    String? profileImageUrl,
    DateTime? createdAt,
    bool? isOnline,
    SubscriptionPlan? plan,
    int? meetingCountThisMonth,
    DateTime? subscriptionStartDate,
    DateTime? subscriptionEndDate,
    BadgeType? badgeType,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      name: name ?? this.name,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      createdAt: createdAt ?? this.createdAt,
      isOnline: isOnline ?? this.isOnline,
      plan: plan ?? this.plan,
      meetingCountThisMonth:
          meetingCountThisMonth ?? this.meetingCountThisMonth,
      subscriptionStartDate:
          subscriptionStartDate ?? this.subscriptionStartDate,
      subscriptionEndDate: subscriptionEndDate ?? this.subscriptionEndDate,
      badgeType: badgeType ?? this.badgeType,
    );
  }

  @override
  String toString() =>
      'UserModel(uid: $uid, name: $name, email: $email, plan: $plan)';
}
