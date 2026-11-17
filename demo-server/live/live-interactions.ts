import crypto from 'node:crypto';
import type { RoomEntry, RoomAttendee } from '../types.ts';
import { ProviderOperationError } from '../providers/provider-registry.ts';

export const demoGiftCatalog = Object.freeze([
  { id: 'applause', name: 'Applause', icon: 'applause' },
  { id: 'flower', name: 'Flower', icon: 'flower' },
  { id: 'star', name: 'Star', icon: 'star' },
]);
// Lightweight protection for a payment-free demo, not a virtual-currency
// spending limit. Allow short gift combos without overwhelming polling clients.
const maxGiftEventsPerTenSeconds = 20;
type GiftEvent = { id: string; sequence: number; userId: string; displayName: string;
  recipientId: string; giftId: string; quantity: number; timestamp: string };
type LikeEvent = { id: string; sequence: number; userId: string; quantity: number; timestamp: string };
type CohostEntry = {
  userId: string;
  participantId: string;
  displayName: string;
  status: 'requested' | 'approved' | 'declined';
  requestedAt: string;
  updatedAt: string;
};
type State = { revision: number; events: GiftEvent[]; totals: Map<string, number>;
  likeEvents: LikeEvent[]; totalLikes: number; handled: Map<string, string>;
  recent: Map<string, number[]>; recentLikes: Map<string, number[]>;
  cohosts: Map<string, CohostEntry> };
const fail = (message: string, code = 'invalid-argument', status = 400): never => {
  throw new ProviderOperationError(status, code, message);
};

/** Transient reference control plane, not a payment or wallet service. */
export class LiveInteractionDirectory {
  private readonly rooms = new WeakMap<RoomEntry, State>();
  private get(entry: RoomEntry): State {
    if (entry.roomMode !== 'broadcast') fail('Live interactions require a broadcast room', 'unsupported-feature');
    let state = this.rooms.get(entry);
    if (!state) { state = { revision: 0, events: [], totals: new Map(), likeEvents: [], totalLikes: 0,
      handled: new Map(), recent: new Map(), recentLikes: new Map(), cohosts: new Map() }; this.rooms.set(entry, state); }
    return state;
  }
  snapshot(entry: RoomEntry, requester: RoomAttendee) {
    const state = this.get(entry);
    const host = entry.attendees.find(person => person.role === 'host');
    const onlineIds = new Set(entry.attendees.map(person => person.userId ?? person.externalUserId));
    for (const [id] of state.cohosts) {
      if (!onlineIds.has(id)) state.cohosts.delete(id);
    }
    const selfUserId = requester.userId ?? requester.externalUserId;
    const selfCohost = state.cohosts.get(selfUserId);
    const selfCohostStatus = requester.role === 'host'
      ? 'none'
      : requester.role === 'participant'
        ? 'active'
        : selfCohost?.status ?? 'none';
    const activeCohosts = entry.attendees
      .filter(person => person.role === 'participant')
      .map(person => ({
        userId: person.userId ?? person.externalUserId,
        participantId: person.attendeeId,
        displayName: person.displayName ?? person.externalUserId,
      }));
    const cohostRequests = [...state.cohosts.values()]
      .filter(item => item.status === 'requested' || item.status === 'approved')
      .map(item => ({ ...item }));
    return { contractVersion: 1, roomCode: entry.roomCode, revision: state.revision,
      selfUserId,
      recipientId: host?.userId ?? host?.externalUserId ?? '', canSendGift: Boolean(host),
      catalog: demoGiftCatalog.map(item => ({ ...item })),
      events: state.events.map(event => ({ ...event })), totals: Object.fromEntries(state.totals),
      likeEvents: state.likeEvents.map(event => ({ ...event })), totalLikes: state.totalLikes,
      cohostSupported: true,
      selfCohostStatus,
      activeCohosts,
      cohostRequests,
    };
  }
  send(entry: RoomEntry, requester: RoomAttendee, raw: Record<string, unknown>) {
    const state = this.get(entry);
    const userId = requester.userId ?? requester.externalUserId;
    const giftId = String(raw.giftId ?? '');
    const quantity = raw.quantity;
    const eventId = String(raw.eventId ?? '');
    if (!/^[a-zA-Z0-9_-]{8,128}$/.test(eventId)) fail('eventId is required');
    if (!demoGiftCatalog.some(gift => gift.id === giftId)) fail('Unknown gift');
    if (!Number.isSafeInteger(quantity) || (quantity as number) < 1 || (quantity as number) > 99) fail('Gift quantity must be 1-99');
    const fingerprint = JSON.stringify(['gift', userId, giftId, quantity]);
    const previous = state.handled.get(eventId);
    if (previous && previous !== fingerprint) fail('Reused eventId with different payload', 'idempotency-conflict', 409);
    if (previous) return this.snapshot(entry, requester);
    const host = entry.attendees.find(person => person.role === 'host');
    if (!host) fail('The host is offline', 'invalid-state', 409);
    const now = Date.now();
    const recent = (state.recent.get(userId) ?? []).filter(time => now - time < 10000);
    if (recent.length >= maxGiftEventsPerTenSeconds) {
      fail('Gift combo paused. Try again in a few seconds.', 'rate-limited', 429);
    }
    recent.push(now); state.recent.set(userId, recent);
    state.revision++;
    state.events.push({ id: crypto.randomUUID(), sequence: state.revision,
      userId, displayName: requester.displayName ?? userId,
      recipientId: host!.userId ?? host!.externalUserId, giftId, quantity: quantity as number, timestamp: new Date(now).toISOString() });
    if (state.events.length > 100) state.events.shift();
    state.totals.set(giftId, (state.totals.get(giftId) ?? 0) + (quantity as number));
    state.handled.set(eventId, fingerprint);
    if (state.handled.size > 1000) state.handled.delete(state.handled.keys().next().value!);
    return this.snapshot(entry, requester);
  }
  sendLike(entry: RoomEntry, requester: RoomAttendee, raw: Record<string, unknown>) {
    const state = this.get(entry);
    const userId = requester.userId ?? requester.externalUserId;
    const eventId = String(raw.eventId ?? '');
    if (!/^[a-zA-Z0-9_-]{8,128}$/.test(eventId)) fail('eventId is required');
    const fingerprint = JSON.stringify(['like', userId]);
    const previous = state.handled.get(eventId);
    if (previous && previous !== fingerprint) fail('Reused eventId with different payload', 'idempotency-conflict', 409);
    if (previous) return this.snapshot(entry, requester);
    const host = entry.attendees.find(person => person.role === 'host');
    if (!host) fail('The host is offline', 'invalid-state', 409);
    const now = Date.now();
    const recent = (state.recentLikes.get(userId) ?? []).filter(time => now - time < 10000);
    if (recent.length >= 30) fail('Please wait before sending more likes', 'rate-limited', 429);
    recent.push(now);
    state.recentLikes.set(userId, recent);
    state.revision++;
    state.totalLikes++;
    state.likeEvents.push({ id: crypto.randomUUID(), sequence: state.revision,
      userId, quantity: 1, timestamp: new Date(now).toISOString() });
    if (state.likeEvents.length > 100) state.likeEvents.shift();
    state.handled.set(eventId, fingerprint);
    if (state.handled.size > 1000) state.handled.delete(state.handled.keys().next().value!);
    return this.snapshot(entry, requester);
  }
  requestCohost(entry: RoomEntry, requester: RoomAttendee) {
    const state = this.get(entry);
    if (requester.role === 'host') fail('Host cannot request co-host', 'forbidden', 403);
    if (requester.role === 'participant') return this.snapshot(entry, requester);
    const userId = requester.userId ?? requester.externalUserId;
    const now = new Date().toISOString();
    const existing = state.cohosts.get(userId);
    if (existing && (existing.status === 'requested' || existing.status === 'approved')) {
      return this.snapshot(entry, requester);
    }
    state.cohosts.set(userId, {
      userId,
      participantId: requester.attendeeId,
      displayName: requester.displayName ?? userId,
      status: 'requested',
      requestedAt: now,
      updatedAt: now,
    });
    state.revision++;
    return this.snapshot(entry, requester);
  }
  cancelCohost(entry: RoomEntry, requester: RoomAttendee) {
    const state = this.get(entry);
    const userId = requester.userId ?? requester.externalUserId;
    let changed = state.cohosts.delete(userId);
    if (requester.role === 'participant') {
      requester.role = 'viewer';
      changed = true;
    }
    if (changed) state.revision++;
    return this.snapshot(entry, requester);
  }
  respondCohost(
    entry: RoomEntry,
    requester: RoomAttendee,
    targetUserId: string,
    action: string,
  ) {
    const state = this.get(entry);
    if (requester.role !== 'host') fail('Host permission required', 'forbidden', 403);
    if (!['approve', 'decline', 'end'].includes(action)) fail('Invalid cohost response action');
    const cleanTarget = targetUserId.trim();
    const target = entry.attendees.find(
      person => (person.userId ?? person.externalUserId) === cleanTarget || person.attendeeId === cleanTarget,
    );
    if (!target) fail('Target participant is offline', 'participant-not-found', 404);
    if (target.role === 'host') fail('Cannot change host role', 'forbidden', 403);
    const canonicalUserId = target.userId ?? target.externalUserId;
    const now = new Date().toISOString();
    if (action === 'approve') {
      target.role = 'participant';
      const existing = state.cohosts.get(canonicalUserId);
      state.cohosts.set(canonicalUserId, {
        userId: canonicalUserId,
        participantId: target.attendeeId,
        displayName: target.displayName ?? canonicalUserId,
        status: 'approved',
        requestedAt: existing?.requestedAt ?? now,
        updatedAt: now,
      });
    } else if (action === 'decline') {
      const existing = state.cohosts.get(canonicalUserId);
      if (existing) {
        state.cohosts.set(canonicalUserId, { ...existing, status: 'declined', updatedAt: now });
      }
    } else {
      target.role = 'viewer';
      state.cohosts.delete(canonicalUserId);
    }
    state.revision++;
    return this.snapshot(entry, requester);
  }
  forget(entry: RoomEntry): void { this.rooms.delete(entry); }
}
