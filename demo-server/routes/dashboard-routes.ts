import type { Express, Request, RequestHandler, Response } from 'express';
import type { ChatRoomEntry, RoomEntry, RoomSummary, ProviderMetadata } from '../types.ts';
import type { ProviderRegistry } from '../providers/provider-registry.ts';
import type { RoomDirectory } from '../providers/room-directory.ts';
import type { ChatProviderRegistry } from '../chat/chat-provider-registry.ts';
import type { ChatRoomDirectory } from '../chat/chat-room-directory.ts';
import { AWS_VENDOR_ID, isAwsEngine } from '../providers/aws.ts';
import crypto from 'node:crypto';

export interface DashboardSelectionState {
  activeProvider: string;
  activeChatProvider: string | null;
}

export interface DashboardRouteDependencies {
  state: DashboardSelectionState;
  providerRegistry: ProviderRegistry;
  chatProviderRegistry: ChatProviderRegistry;
  chatRoomDirectory: ChatRoomDirectory;
  roomDirectory: RoomDirectory;
  dashboardFilePath: string;
  mediaConnectionsEnabled: boolean;
  isVercel: boolean;
  contractVersion: number;
  controlRegion: string;
  mediaRegion: string;
  startedAt: number;
  adminPassword: string;
  adminSessionTtlSeconds: number;
  currentConfigured(): boolean;
  providerMetadataForDashboard(): ProviderMetadata[];
  persistActiveProviders(provider: string, chatProvider: string | null): void;
  setAdminCookie(res: Response, req: Request): void;
  clearAdminCookie(res: Response, req: Request): void;
  contractError(res: Response, status: number, code: string, message: string, details?: unknown): Response;
  sendProviderError(res: Response, error: unknown): Response | false;
  logEvent(type: string, message: string): void;
  summarizeRoom(entry: RoomEntry, req?: Request): RoomSummary;
  isRoomPartiallyClosed(entry: RoomEntry): boolean;
  events: Array<{ ts: string; type: string; message: string }>;
  requireSameOrigin: RequestHandler;
  requireAdmin: RequestHandler;
}

/** Dashboard, administrator, health, and provider-selection HTTP control plane. */
export function registerDashboardRoutes(app: Express, deps: DashboardRouteDependencies): void {
  const {
    state, providerRegistry, chatProviderRegistry, chatRoomDirectory, roomDirectory,
    dashboardFilePath, mediaConnectionsEnabled: MEDIA_CONNECTIONS_ENABLED,
    isVercel: IS_VERCEL, contractVersion: CONTRACT_VERSION,
    controlRegion: CONTROL_REGION, mediaRegion: MEDIA_REGION,
    startedAt: STARTED_AT, adminPassword: MEDIA_ADMIN_PASSWORD,
    adminSessionTtlSeconds: ADMIN_SESSION_TTL_SECONDS, currentConfigured,
    providerMetadataForDashboard, persistActiveProviders, setAdminCookie, clearAdminCookie,
    contractError, sendProviderError, logEvent, summarizeRoom,
    isRoomPartiallyClosed, events, requireSameOrigin, requireAdmin,
  } = deps;

app.post('/api/chat-provider', requireSameOrigin, requireAdmin, (req, res) => {
  const requested = String(req.body?.provider ?? '').trim().toLowerCase();
  try {
    if (requested === 'none' || requested === '') {
      state.activeChatProvider = null;
    } else {
      state.activeChatProvider = chatProviderRegistry.requireConfigured(requested).id;
    }
    logEvent(
      'chat-provider-switch',
      state.activeChatProvider
        ? `new rooms will use chat provider ${state.activeChatProvider}`
        : 'new rooms will not attach a chat provider',
    );
    persistActiveProviders(state.activeProvider, state.activeChatProvider);
    res.json({ ok: true, activeChatProvider: state.activeChatProvider });
  } catch (error) {
    if (sendProviderError(res, error) !== false) return;
    throw error;
  }
});
app.post('/api/admin/login', requireSameOrigin, (req, res) => {
  res.set('Cache-Control', 'no-store');
  if (!MEDIA_ADMIN_PASSWORD) {
    return contractError(res, 503, 'admin-not-configured', 'Admin login is not configured.');
  }
  const password = typeof req.body?.password === 'string' ? req.body.password : '';
  const supplied = crypto.createHash('sha256').update(password).digest();
  const expected = crypto.createHash('sha256').update(MEDIA_ADMIN_PASSWORD).digest();
  if (!crypto.timingSafeEqual(supplied, expected)) {
    return contractError(res, 401, 'invalid-admin-password', 'The management password is incorrect.');
  }
  setAdminCookie(res, req);
  res.json({ ok: true, expiresInSeconds: ADMIN_SESSION_TTL_SECONDS });
});

app.post('/api/admin/logout', requireSameOrigin, (req, res) => {
  res.set('Cache-Control', 'no-store');
  clearAdminCookie(res, req);
  res.json({ ok: true });
});

app.get('/api/admin/session', requireAdmin, (_req, res) => {
  res.json({ authenticated: true, connectionsEnabled: MEDIA_CONNECTIONS_ENABLED });
});

app.get('/', (_req, res) => {
  res.sendFile(dashboardFilePath);
});

app.get('/health', (_req, res) => {
  const configured = currentConfigured();
  const providerList = providerMetadataForDashboard();
  const chatProviderList = chatProviderRegistry.metadata();
  res.json({
    ok: configured,
    connectionsEnabled: MEDIA_CONNECTIONS_ENABLED,
    contractVersion: CONTRACT_VERSION,
    activeProvider: state.activeProvider,
    activeChatProvider: state.activeChatProvider,
    controlRegion: CONTROL_REGION,
    mediaRegion: MEDIA_REGION,
    providers: Object.fromEntries(providerList.map((item) => [item.id, item])),
    providerList,
    chatProviders: Object.fromEntries(chatProviderList.map((item) => [item.id, item])),
    chatProviderList,
  });
});

app.post('/api/provider', requireSameOrigin, requireAdmin, (req, res) => {
  if (IS_VERCEL && req.body?.provider !== state.activeProvider) {
    return contractError(
      res,
      409,
      'provider-selection-is-deployment-config',
      'Set MEDIA_DEFAULT_PROVIDER in Vercel and redeploy to change the default provider.',
    );
  }
  try {
    const requested = String(req.body?.provider ?? '').trim().toLowerCase();
    const selected = isAwsEngine(requested) ? AWS_VENDOR_ID : requested;
    if (selected !== AWS_VENDOR_ID) providerRegistry.requireConfigured(selected);
    if (selected !== state.activeProvider) {
      state.activeProvider = selected;
      logEvent('provider-switch', `new rooms will use ${selected}`);
    }
    persistActiveProviders(selected, state.activeChatProvider);
    res.json({ ok: true, activeProvider: state.activeProvider });
  } catch (error) {
    if (sendProviderError(res, error) !== false) return;
    throw error;
  }
});

app.get('/api/overview', requireAdmin, (req, res) => {
  const allRooms = roomDirectory.entries();
  const standaloneChatRooms = chatRoomDirectory.list();
  const providerList = providerMetadataForDashboard();
  const chatProviderList = chatProviderRegistry.metadata();
  res.json({
    ok: true,
    connectionsEnabled: MEDIA_CONNECTIONS_ENABLED,
    providerSelectionEnabled: !IS_VERCEL,
    activeProvider: state.activeProvider,
    activeChatProvider: state.activeChatProvider,
    providers: Object.fromEntries(providerList.map((item) => [item.id, item])),
    providerList,
    chatProviders: Object.fromEntries(
      chatProviderList.map((item) => [item.id, item]),
    ),
    chatProviderList,
    controlRegion: CONTROL_REGION,
    mediaRegion: MEDIA_REGION,
    uptimeSec: Math.floor((Date.now() - STARTED_AT) / 1000),
    startedAt: new Date(STARTED_AT).toISOString(),
    roomCount: allRooms.length,
    attendeeCount: allRooms.reduce((count, entry) => count + entry.attendees.length, 0),
    standaloneChatRoomCount: standaloneChatRooms.length,
    standaloneChatAttendeeCount: standaloneChatRooms.reduce(
      (count, entry) => count + entry.attendees.length,
      0,
    ),
    standaloneChatRooms: standaloneChatRooms.map((entry) => ({
      roomCode: entry.roomCode,
      chatProvider: entry.chatProvider,
      context: 'standalone',
      createdAt: entry.createdAt,
      attendeeCount: entry.attendees.length,
      attendees: entry.attendees.map((attendee) => ({
        userId: attendee.userId ?? attendee.externalUserId,
        externalUserId: attendee.externalUserId,
        displayName: attendee.displayName ?? attendee.externalUserId,
        role: attendee.role ?? 'participant',
        joinedAt: attendee.joinedAt,
        lastHeartbeatMs: attendee.lastHeartbeatMs,
      })),
    })),
    rooms: allRooms.map((entry) => summarizeRoom(entry, req)),
    events: events.slice(0, 100),
  });
});

app.get('/rooms', requireAdmin, (req, res) => {
  res.json({
    contractVersion: CONTRACT_VERSION,
    rooms: roomDirectory.entries().map((entry) => summarizeRoom(entry, req)),
  });
});

app.get('/rooms/discover', (req, res) => {
  const rooms = roomDirectory
    .entries()
    .filter((entry) => !isRoomPartiallyClosed(entry))
    .map((entry) => {
    const summary = summarizeRoom(entry, req);
    return {
      provider: summary.provider,
      ...(summary.vendor ? { vendor: summary.vendor } : {}),
      ...(summary.engine ? { engine: summary.engine } : {}),
      ...(summary.chatProvider ? { chatProvider: summary.chatProvider } : {}),
      roomCode: summary.roomCode,
      roomMode: summary.roomMode ?? 'meeting',
      ...(entry.meetingMode ? { meetingMode: entry.meetingMode } : {}),
      createdAt: summary.createdAt,
      attendeeCount: summary.attendeeCount,
    };
    });
  res.set('Cache-Control', 'no-store');
  res.json({ contractVersion: CONTRACT_VERSION, rooms });
});


}
