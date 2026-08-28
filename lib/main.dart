import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image/image.dart' as img;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'package:geolocator/geolocator.dart';
import 'services/booking_notification_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'widgets/editable_app_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/search_app_bar.dart';
import 'widgets/section_card.dart';
import 'widgets/toggle_filter_button.dart';

part 'core/shared_models.dart';
part 'core/shared_utils.dart';
part 'widgets/shared_helpers.dart';
part 'navigation/main_navigation_screen.dart';
part 'screens/dropbox_estimate_tab_screen.dart';
part 'screens/venue_list_screen.dart';
part 'screens/shift_split_screen.dart';
part 'screens/booking_list_screen.dart';
part 'screens/booking_detail_sheet.dart';
part 'screens/venue_detail_sheet.dart';
part 'screens/add_venue_screen.dart';
part 'screens/add_booking_screen.dart';
part 'screens/photo_annotation_page.dart';
part 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BookingNotificationService.registerBackgroundHandler();
  runApp(const VenueAppBootstrap());
}

class VenueAppBootstrap extends StatefulWidget {
  const VenueAppBootstrap({super.key});

  @override
  State<VenueAppBootstrap> createState() => _VenueAppBootstrapState();
}

class _VenueAppBootstrapState extends State<VenueAppBootstrap> {
  late final Future<FirebaseApp> _firebaseInit = Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  Future<void> _initializeNotificationsAfterFirebase() async {
    await _firebaseInit;
    await BookingNotificationService.instance.initialize();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeNotificationsAfterFirebase());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FirebaseApp>(
      future: _firebaseInit,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('初期化に失敗しました: ${snapshot.error}'),
                ),
              ),
            ),
          );
        }

        return const VenueApp();
      },
    );
  }
}

class VenueApp extends StatelessWidget {
  const VenueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ZAIKIapp',
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      scrollBehavior: MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      theme: AppTheme.light(),
      home: const MainNavigationScreen(),
    );
  }
}
