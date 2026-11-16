import 'package:flutter/widgets.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeVideoTrack extends MediaVideoTrack {
  const _FakeVideoTrack(this.id);

  @override
  final String id;

  @override
  String get participantId => 'user-1';

  @override
  bool get isLocal => true;

  @override
  bool get isScreenShare => false;

  @override
  int get width => 640;

  @override
  int get height => 360;
}

class _TrackingRenderer extends MediaTrackRenderer {
  const _TrackingRenderer(this.events);
  final List<String> events;

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      _StatefulView(events: events, trackId: track.id);
}

class _StatefulView extends StatefulWidget {
  const _StatefulView({required this.events, required this.trackId});
  final List<String> events;
  final String trackId;

  @override
  State<_StatefulView> createState() => _StatefulViewState();
}

class _StatefulViewState extends State<_StatefulView> {
  @override
  void initState() {
    super.initState();
    widget.events.add('init:${widget.trackId}');
  }

  @override
  void dispose() {
    widget.events.add('dispose:${widget.trackId}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('video:${widget.trackId}');
}

void main() {
  testWidgets(
    'MediaPlatformViewOcclusion hides iOS track offstage without unmounting',
    (tester) async {
      final events = <String>[];
      const track = _FakeVideoTrack('tile-1');

      Widget harness(bool occluded) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaPlatformViewOcclusion(
          occluded: occluded,
          child: MediaTrackView(
            renderer: _TrackingRenderer(events),
            track: track,
            placeholder: const Text('paused-placeholder'),
          ),
        ),
      );

      await tester.pumpWidget(harness(false));
      expect(events, ['init:tile-1']);
      expect(find.text('video:tile-1'), findsOneWidget);
      expect(find.text('paused-placeholder'), findsNothing);

      await tester.pumpWidget(harness(true));
      expect(events, ['init:tile-1']);
      expect(find.text('video:tile-1'), findsNothing);
      expect(find.text('paused-placeholder'), findsOneWidget);

      await tester.pumpWidget(harness(false));
      expect(events, ['init:tile-1']);
      expect(find.text('video:tile-1'), findsOneWidget);
      expect(find.text('paused-placeholder'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
