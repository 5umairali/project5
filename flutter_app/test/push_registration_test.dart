import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dahimail/core/api.dart';
import 'package:dahimail/core/session.dart';
import 'package:dahimail/core/push.dart';
import 'package:dahimail/core/notify.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  testWidgets('a stalled Firebase token request times out and retries registration', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await Firebase.initializeApp();
    PackageInfo.setMockInitialValues(appName: 'DahiMail', packageName: 'com.dahify.dahimail',
      version: '1.0.8', buildNumber: '9', buildSignature: '');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/firebase_messaging');
    final stalled = Completer<Map<String, dynamic>>();
    var tokenRequests = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'Messaging#getToken') {
        tokenRequests++;
        if (tokenRequests == 1) return stalled.future;
        return {'token': 'synthetic-recovered-token'};
      }
      return <String, dynamic>{};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final registrations = <Map<String, dynamic>>[];
    await http.runWithClient(() async {
      final api = Api(Session()..token = 'synthetic-session');
      var finished = false;
      final first = PushService.I.register(api).then((_) => finished = true);
      await tester.pump();
      expect(PushService.I.status.value.busy, isTrue);
      await tester.pump(const Duration(seconds: 16));
      await first;
      expect(finished, isTrue);
      expect(PushService.I.status.value.code, 'firebase_unavailable');
      expect(PushService.I.status.value.busy, isFalse);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(tokenRequests, 2);
      expect(registrations.single['token'], 'synthetic-recovered-token');
      expect(PushService.I.status.value.registered, isTrue);
      stalled.complete({'token': 'synthetic-stale-token'});
      await tester.pump();
      expect(registrations, hasLength(1));
      // Token rotation registers the supplied token without a second Firebase lookup.
      await messenger.handlePlatformMessage(channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('Messaging#onTokenRefresh', 'synthetic-rotated-token')),
        (_) {});
      await tester.pump();
      expect(tokenRequests, 2);
      expect(registrations.last['token'], 'synthetic-rotated-token');
      expect(registrations, hasLength(2));
      await PushService.I.unregister(api);
    }, () => MockClient((request) async {
      if (request.url.path.endsWith('/me/devices')) {
        registrations.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return http.Response(jsonEncode({'push_configured': true, 'push_status': 'registered'}), 200);
    }));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Check connection probes older registration responses and reports provider results', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await Firebase.initializeApp();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/firebase_messaging');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'Messaging#getToken') return {'token': 'synthetic-legacy-token'};
      return <String, dynamic>{};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final providerCode in ['accepted', 'SENDER_ID_MISMATCH', 'endpoint_missing']) {
      var probes = 0;
      await http.runWithClient(() async {
        final api = Api(Session()..token = 'synthetic-legacy-session');
        await PushService.I.checkConnection(api);
        expect(probes, 1);
        final status = PushService.I.status.value;
        expect(status.code, providerCode == 'endpoint_missing' ? 'check_unavailable' : providerCode);
        expect(status.registered, providerCode == 'accepted');
        expect(NotifyService.I.pushActive, providerCode == 'accepted');
        if (providerCode == 'accepted') {
          await tester.pump(const Duration(seconds: 31));
          expect(PushService.I.status.value.code, 'accepted');
          expect(probes, 1);
        }
        await PushService.I.unregister(api);
      }, () => MockClient((request) async {
        if (request.url.path.endsWith('/me/devices/check-push')) {
          probes++;
          expect(jsonDecode(request.body)['token'], 'synthetic-legacy-token');
          if (providerCode == 'endpoint_missing') return http.Response('{}', 404);
          return http.Response(jsonEncode({'accepted': providerCode == 'accepted', 'code': providerCode}), 200);
        }
        return http.Response(jsonEncode({'message': 'Device registered.'}), 200);
      }));
    }
    debugDefaultTargetPlatformOverride = null;
  });

}
