import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors the public docs rather than importing private runtime paths.
class ExamplePresenceController {
  bool disposed = false;
  void dispose() => disposed = true;
}

class ExamplePresenceFeature
    extends RealtimeFeaturePlugin<ExamplePresenceController> {
  const ExamplePresenceFeature();

  static const featureKey = RealtimeFeatureKey<ExamplePresenceController>(
    'myapp.presence',
  );

  @override
  RealtimeFeatureKey<ExamplePresenceController> get key => featureKey;

  @override
  ExamplePresenceController attach(RealtimeFeatureContext context) =>
      ExamplePresenceController();

  @override
  void detach(ExamplePresenceController feature) => feature.dispose();
}

void main() {
  test('custom third-party feature implements the public SDK API', () {
    const feature = ExamplePresenceFeature();
    expect(feature.key.id, 'myapp.presence');
    expect(feature.key.valueType, ExamplePresenceController);
    expect(feature.requiredFeatures, isEmpty);
    expect(feature.optionalFeatures, isEmpty);
  });
}
