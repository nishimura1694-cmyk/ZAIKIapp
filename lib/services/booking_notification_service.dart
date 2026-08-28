import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
Future<void> bookingFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp();
}

class BookingNotificationService {
  BookingNotificationService._();

  static final BookingNotificationService instance =
      BookingNotificationService._();

  static const String topicName = 'booking_updates';
  static const String _tokenCollection = 'notificationTokens';
  static const String _androidChannelId = 'booking_updates_channel';
  static const String _androidChannelName = '予約履歴通知';
  static const String _androidChannelDescription = '予約履歴の新規登録通知';
  static const String _enabledPrefsKey = 'booking_notifications_enabled';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  StreamSubscription<String>? _tokenRefreshSubscription;

  static void registerBackgroundHandler() {
    FirebaseMessaging.onBackgroundMessage(
      bookingFirebaseMessagingBackgroundHandler,
    );
  }

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;
    await messaging.setAutoInitEnabled(true);
    await _initializeLocalNotifications();

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.requestNotificationsPermission();
    }

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    debugPrint(
      'BookingNotificationService permission=${settings.authorizationStatus.name}',
    );

    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    if (settings.authorizationStatus == AuthorizationStatus.denied &&
        !isAndroid) {
      return;
    }
    if (settings.authorizationStatus == AuthorizationStatus.denied &&
        isAndroid) {
      debugPrint(
        'BookingNotificationService permission denied on Android; continue topic subscription',
      );
    }

    final wantsNotifications = await isEnabled();
    if (wantsNotifications) {
      try {
        await messaging.subscribeToTopic(topicName);
        debugPrint('BookingNotificationService subscribed topic=$topicName');
      } catch (e) {
        debugPrint('BookingNotificationService subscribe failed: $e');
      }
    }

    String? token;
    try {
      token = await messaging.getToken();
      debugPrint('BookingNotificationService token=$token');
    } catch (e) {
      debugPrint('BookingNotificationService getToken failed: $e');
    }
    unawaited(_upsertToken(token));

    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = messaging.onTokenRefresh.listen((token) async {
      if (await isEnabled()) {
        try {
          await messaging.subscribeToTopic(topicName);
          debugPrint(
            'BookingNotificationService re-subscribed on token refresh',
          );
        } catch (e) {
          debugPrint('BookingNotificationService re-subscribe failed: $e');
        }
      }
      unawaited(_upsertToken(token));
    });

    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
  }

  /// アプリ内の「予約の更新通知」設定(デフォルトON)。
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledPrefsKey) ?? true;
  }

  /// 設定画面のスイッチから呼ばれ、トピックの購読/解除を切り替える。
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledPrefsKey, enabled);

    if (kIsWeb) return;
    final messaging = FirebaseMessaging.instance;
    try {
      if (enabled) {
        await messaging.subscribeToTopic(topicName);
      } else {
        await messaging.unsubscribeFromTopic(topicName);
      }
    } catch (e) {
      debugPrint('BookingNotificationService setEnabled($enabled) failed: $e');
    }
  }

  /// OS側の通知許可状態(端末の設定でブロックされていないか)を確認する。
  Future<AuthorizationStatus> osPermissionStatus() async {
    final settings = await FirebaseMessaging.instance
        .getNotificationSettings();
    return settings.authorizationStatus;
  }

  Future<void> _upsertToken(String? token) async {
    if (token == null || token.isEmpty) return;

    try {
      final docId = token.replaceAll('/', '_');
      await FirebaseFirestore.instance
          .collection(_tokenCollection)
          .doc(docId)
          .set({
            'token': token,
            'platform': defaultTargetPlatform.name,
            'updatedAt': FieldValue.serverTimestamp(),
            'enabled': true,
          }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('BookingNotificationService token upsert failed: $e');
    }
  }

  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const darwinSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );

    await _localNotifications.initialize(initSettings);

    const channel = AndroidNotificationChannel(
      _androidChannelId,
      _androidChannelName,
      description: _androidChannelDescription,
      importance: Importance.high,
    );

    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(channel);
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final remoteNotification = message.notification;
    final title =
        remoteNotification?.title ??
        (message.data['title']?.toString() ?? '予約履歴が追加されました');
    final body =
        remoteNotification?.body ??
        (message.data['body']?.toString() ?? '最新の予約情報を確認してください。');

    const androidDetails = AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      channelDescription: _androidChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const iOSDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: message.data['bookingId']?.toString(),
    );
  }
}
