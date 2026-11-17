import 'live_interaction_state.dart';

abstract interface class LiveInteractionRepository {
  Future<LiveInteractionState> snapshot();

  /// Caller-provided eventId enables safe retries of the same logical gift.
  Future<LiveInteractionState> sendGift(
    String giftId,
    int quantity, {
    required String eventId,
  });
  Future<LiveInteractionState> sendLike({required String eventId});
  void close();
}

/// Optional co-host request and host approval control-plane capability.
abstract interface class LiveCohostRepository {
  Future<LiveInteractionState> requestCohost();
  Future<LiveInteractionState> cancelCohost();
  Future<LiveInteractionState> respondCohost(String userId, String action);
}
