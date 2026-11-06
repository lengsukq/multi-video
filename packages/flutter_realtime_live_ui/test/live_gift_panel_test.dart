import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_realtime_live_core/flutter_realtime_live_core.dart';
import 'package:flutter_realtime_live_ui/flutter_realtime_live_ui.dart';
import 'package:flutter_test/flutter_test.dart';

class Repository implements LiveInteractionRepository {
  @override
  Future<LiveInteractionState> sendLike({required String eventId}) =>
      snapshot();
  final ids = <String>[];
  bool fail = true;
  @override
  Future<LiveInteractionState> snapshot() async => LiveInteractionState(
    roomCode: 'live1',
    revision: 0,
    selfUserId: 'alice',
    recipientId: 'host',
    canSendGift: true,
    catalog: [LiveGift(id: 'star', name: 'Star', icon: 'star')],
  );
  @override
  Future<LiveInteractionState> sendGift(
    String giftId,
    int quantity, {
    required String eventId,
  }) {
    ids.add(eventId);
    if (fail) throw StateError('Try again');
    return snapshot();
  }

  @override
  void close() {}
}

class _RateLimitedRepository extends Repository {
  int sends = 0;

  @override
  Future<LiveInteractionState> sendGift(
    String giftId,
    int quantity, {
    required String eventId,
  }) {
    sends++;
    throw const RealtimeException(
      code: RealtimeErrorCode.serverError,
      statusCode: 429,
      message: 'Gift combo paused',
    );
  }
}

class _GiftFeedRepository extends Repository {
  int revision = 0;
  final events = <LiveGiftEvent>[];

  @override
  Future<LiveInteractionState> snapshot() async => LiveInteractionState(
    roomCode: 'live1',
    revision: revision,
    selfUserId: 'alice',
    recipientId: 'host',
    canSendGift: true,
    catalog: [
      LiveGift(id: 'star', name: 'Star', icon: 'star'),
      LiveGift(id: 'flower', name: 'Flower', icon: 'flower'),
    ],
    events: events,
  );

  @override
  Future<LiveInteractionState> sendGift(
    String giftId,
    int quantity, {
    required String eventId,
  }) {
    revision++;
    events.add(
      LiveGiftEvent(
        id: eventId,
        sequence: revision,
        userId: 'alice',
        displayName: 'Alice',
        recipientId: 'host',
        giftId: giftId,
        quantity: quantity,
        timestamp: DateTime.now(),
      ),
    );
    return snapshot();
  }
}

void main() {
  testWidgets('gifts notify the live stage without opening the gift sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _GiftFeedRepository();
    final session = LiveInteractionSession(
      repository,
      pollInterval: const Duration(hours: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: LiveGiftBanner(session: session)),
      ),
    );
    await session.start();
    await session.sendGift('flower', quantity: 5);
    await tester.pump();
    expect(find.text('Alice 送出 鲜花 ×5'), findsOneWidget);
    // Polling the same snapshot should not show the event twice.
    await session.refresh();
    await tester.pump();
    expect(find.byKey(const ValueKey('live-gift-notices')), findsOneWidget);
    expect(find.byKey(ValueKey('gift-notice-${repository.events.single.id}')),
        findsOneWidget);

    await session.sendGift('star', quantity: 2);
    await tester.pump();
    expect(find.text('Alice 送出 星星 ×2'), findsOneWidget);
    expect(find.text('Alice 送出 鲜花 ×5'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('送出'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.dispose();
  });

  testWidgets('recent gifts are visible when the banner mounts late', (
    tester,
  ) async {
    final repository = _GiftFeedRepository();
    final session = LiveInteractionSession(
      repository,
      pollInterval: const Duration(hours: 1),
    );
    await session.start();
    await session.sendGift('star');
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LiveGiftBanner(session: session))),
    );
    await tester.pump();
    expect(find.text('Alice sent Star ×1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.dispose();
  });

  testWidgets(
    '429 shows a temporary readable cooldown rather than raw API error',
    (tester) async {
      final repository = _RateLimitedRepository();
      final session = LiveInteractionSession(
        repository,
        pollInterval: const Duration(hours: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LiveGiftPanel(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Star × 1'));
      await tester.pump();
      expect(find.textContaining('cooling down'), findsOneWidget);
      expect(find.textContaining('429'), findsNothing);
      await tester.tap(find.text('Star × 1'));
      await tester.pump();
      expect(repository.sends, 1);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.textContaining('cooling down'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await session.dispose();
    },
  );
  testWidgets('gift panel retries the same event id and fits a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = Repository();
    final session = LiveInteractionSession(
      repository,
      pollInterval: const Duration(hours: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveGiftPanel(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Star × 1'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(repository.ids[0], repository.ids[1]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.dispose();
  });

  testWidgets(
    'gift panel switches quantity multiplier and triggers close callback',
    (tester) async {
      final repository = Repository();
      repository.fail = false;
      final session = LiveInteractionSession(
        repository,
        pollInterval: const Duration(hours: 1),
      );
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveGiftPanel(
              session: session,
              showHeader: true,
              onClose: () => closed = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Send a gift'), findsOneWidget);
      expect(find.text('Star × 1'), findsOneWidget);

      await tester.tap(find.text('×5'));
      await tester.pumpAndSettle();
      expect(find.text('Star × 5'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(closed, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await session.dispose();
    },
  );
}
