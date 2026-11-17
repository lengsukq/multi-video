import 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
import 'live_cohost.dart';
import 'live_gift.dart';
import 'live_gift_event.dart';
import 'live_like_event.dart';

class LiveInteractionState {
  LiveInteractionState({
    required this.roomCode,
    required this.revision,
    required this.selfUserId,
    required this.recipientId,
    required this.canSendGift,
    List<LiveGift> catalog = const [],
    List<LiveGiftEvent> events = const [],
    List<LiveLikeEvent> likeEvents = const [],
    this.totalLikes = 0,
    Map<String, int> totals = const {},
    this.cohostSupported = false,
    this.selfCohostStatus = LiveCohostStatus.none,
    List<LiveCohostRequest> cohostRequests = const [],
    List<LiveCohostMember> activeCohosts = const [],
  }) : catalog = List.unmodifiable(catalog),
       events = List.unmodifiable(events),
       likeEvents = List.unmodifiable(likeEvents),
       totals = Map.unmodifiable(totals),
       cohostRequests = List.unmodifiable(cohostRequests),
       activeCohosts = List.unmodifiable(activeCohosts);
  final String roomCode, selfUserId, recipientId;
  final int revision;
  final bool canSendGift;
  final List<LiveGift> catalog;
  final List<LiveGiftEvent> events;
  final List<LiveLikeEvent> likeEvents;
  final int totalLikes;
  final Map<String, int> totals;
  final bool cohostSupported;
  final LiveCohostStatus selfCohostStatus;
  final List<LiveCohostRequest> cohostRequests;
  final List<LiveCohostMember> activeCohosts;
  factory LiveInteractionState.fromJson(Map<String, dynamic> value) =>
      JsonReader(
        value,
      ).decode(() => LiveInteractionState._fromJsonUnchecked(value));
  factory LiveInteractionState._fromJsonUnchecked(Map<String, dynamic> value) =>
      LiveInteractionState(
        roomCode: JsonReader(value).required<String>('roomCode'),
        revision: JsonReader(value).required<int>('revision'),
        selfUserId: JsonReader(value).required<String>('selfUserId'),
        recipientId: JsonReader(value).required<String>('recipientId'),
        canSendGift: JsonReader(value).required<bool>('canSendGift'),
        catalog: JsonReader(
          value,
        ).objects('catalog', LiveGift.fromJson, optional: false),
        events: JsonReader(
          value,
        ).objects('events', LiveGiftEvent.fromJson, optional: false),
        likeEvents: JsonReader(
          value,
        ).objects('likeEvents', LiveLikeEvent.fromJson, optional: true),
        totalLikes: (value['totalLikes'] as int?) ?? 0,
        totals: Map.unmodifiable((value['totals'] as Map).cast<String, int>()),
        cohostSupported:
            JsonReader(value).optional<bool>('cohostSupported') ?? false,
        selfCohostStatus:
            LiveCohostStatus.values
                .where(
                  (item) =>
                      item.name ==
                      JsonReader(value).optional<String>('selfCohostStatus'),
                )
                .firstOrNull ??
            LiveCohostStatus.none,
        cohostRequests: JsonReader(
          value,
        ).objects('cohostRequests', LiveCohostRequest.fromJson, optional: true),
        activeCohosts: JsonReader(
          value,
        ).objects('activeCohosts', LiveCohostMember.fromJson, optional: true),
      );
}
