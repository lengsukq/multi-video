import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'shared_content_controller.dart';
import 'room_annotation_coordinator.dart';
import 'shared_content_repository.dart';
import 'classroom_shared_content_repository.dart';

class SharedContentRoomFeature {
  SharedContentRoomFeature(
    RealtimeFeatureContext context, {
    SharedContentRepository? repository,
  }) {
    final classroom = context.feature(ClassroomPreset.featureKey);
    sharedContent = SharedContentController(
      media: context.media.session,
      classroom: repository == null ? classroom : null,
      repository: repository,
    );
    annotations = repository != null || classroom == null
        ? null
        : RoomAnnotationCoordinator(
            context.media.session,
            classroom,
            (error) => context.reportError?.call(error, StackTrace.current),
          );
  }
  late final SharedContentController sharedContent;
  late final RoomAnnotationCoordinator? annotations;
  Future<void> dispose() async {
    final cleanup = Cleanup();
    await cleanup.run('annotation', () async {
      await annotations?.dispose();
    });
    await cleanup.run('sharedContent', sharedContent.dispose);
    cleanup.finish(domain: 'sharedContent');
  }
}

class SharedContentPreset
    extends RealtimeFeaturePlugin<SharedContentRoomFeature> {
  const SharedContentPreset({this.repositoryFactory});
  final SharedContentRepository Function(RealtimeFeatureContext context)?
  repositoryFactory;
  static const featureKey = RealtimeFeatureKey<SharedContentRoomFeature>(
    'shared-content',
  );
  @override
  RealtimeFeatureKey<SharedContentRoomFeature> get key => featureKey;
  @override
  List<RealtimeFeatureKey<Object>> get optionalFeatures => const [
    ClassroomPreset.featureKey,
  ];
  @override
  SharedContentRoomFeature? attach(RealtimeFeatureContext context) {
    final factory = repositoryFactory;
    if (factory != null) {
      return SharedContentRoomFeature(context, repository: factory(context));
    }
    if (context.feature(ClassroomPreset.featureKey) != null) {
      return SharedContentRoomFeature(context);
    }
    final media = context.media;
    final url = context.backendUrl;
    final credential = media.participantCredential;
    if (media.backendMetadata['roomMode'] != 'meeting' ||
        url == null ||
        credential == null) {
      return null;
    }
    return SharedContentRoomFeature(
      context,
      repository: ClassroomSharedContentRepository(
        HttpClassroomRepository(
          backendUrl: url,
          roomCode: media.roomCode,
          participantId: media.participantId,
          participantCredential: credential,
          roomOwnerCredential: media.roomOwnerCredential,
          tokenProvider: context.tokenProvider,
          requestTimeout: context.requestTimeout ?? const Duration(seconds: 10),
        ),
      ),
    );
  }

  @override
  Future<void> detach(SharedContentRoomFeature feature) => feature.dispose();
}

extension RealtimeRoomSharedContentExtension on RealtimeRoom {
  SharedContentController? get sharedContent =>
      features.get(SharedContentPreset.featureKey)?.sharedContent;
}
