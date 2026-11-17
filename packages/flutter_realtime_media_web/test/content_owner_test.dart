import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_media_web/src/provider_web_profile.dart';
import 'package:flutter_realtime_media_web/src/provider_web_track.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

void main() {
  test(
    'Web content ownership normalizes Chime/IVS modality only and preserves other tracks',
    () {
      final profile = ProviderWebProfile.forProvider('chime');
      final owner = profile.contentOwner(
        'teacher#content',
        isScreenShare: true,
      );
      final MediaVideoTrack track = ProviderWebVideoTrack(
        providerId: 'chime',
        sessionId: 's',
        id: 't',
        participantId: 'teacher#content',
        contentOwnerParticipantId: owner,
        isLocal: false,
        isScreenShare: true,
      );
      expect(track.contentOwnerParticipantId, 'teacher');
      expect(track.participantId, 'teacher#content');
      expect(
        profile.contentOwner('teacher#content', isScreenShare: false),
        'teacher#content',
      );
      final ivsProfile = ProviderWebProfile.forProvider('ivs');
      expect(
        ivsProfile.contentOwner('host-1#content', isScreenShare: true),
        'host-1',
      );
      expect(ivsProfile.supportsAudioOutputSelection, isTrue);
      expect(
        ProviderWebProfile.forProvider(
          'agora',
        ).contentOwner('teacher#content', isScreenShare: true),
        'teacher#content',
      );
    },
  );
}
