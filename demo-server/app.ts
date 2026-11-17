import { readDemoConfiguration } from './services/demo-configuration.ts';
import { createIdleRoomSweeper } from './services/idle-room-sweeper.ts';
// Multi-provider demo backend — provider credentials stay server-side.
//
// `npm start` is the single backend entry point. Flutter sends room/user intent;
// this server selects a provider for new rooms and preserves that binding for
// the room lifetime. Provider SDK/token details live under demo-server/providers.

import crypto from 'node:crypto';
import express, {
  type NextFunction,
  type Request,
  type Response,
} from 'express';
import cors from 'cors';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createAgoraProvider } from './providers/agora.ts';
import { createArtcProvider } from './providers/artc.ts';
import { createChimeProvider } from './providers/chime.ts';
import { createLiveKitProvider } from './providers/livekit.ts';
import { createIvsProvider } from './providers/ivs.ts';
import {
  AWS_VENDOR_ID,
  awsEngineForRoomMode,
  awsVendorMetadata,
  isAwsEngine,
  publicVendorForEngine,
} from './providers/aws.ts';
import { ChatProviderRegistry } from './chat/chat-provider-registry.ts';
import { ChatRoomDirectory } from './chat/chat-room-directory.ts';
import { LiveInteractionDirectory } from './live/live-interactions.ts';
import { registerInteractionRoutes } from './routes/interaction-routes.ts';
import { registerRoomRoutes } from './routes/room-routes.ts';
import { registerRecordingRoutes } from './routes/recording-routes.ts';
import { LiveKitCloudRecording } from './recording/livekit-cloud-recording.ts';
import { AgoraCloudRecording } from './recording/agora-cloud-recording.ts';
import { ArtcCloudRecording } from './recording/artc-cloud-recording.ts';
import { ArtcVodRecording } from './recording/artc-vod-recording.ts';
import { ChimeCloudRecording } from './recording/chime-cloud-recording.ts';
import { IvsCloudRecording } from './recording/ivs-cloud-recording.ts';
import { TrtcCloudRecording } from './recording/trtc-cloud-recording.ts';
import type { CloudRecordingExecutor } from './recording/cloud-recording-executor.ts';
import { registerChatRoutes } from './routes/chat-routes.ts';
import { registerDashboardRoutes, type DashboardSelectionState } from './routes/dashboard-routes.ts';
import { requireRoomManager } from './room-access.ts';
import { RoomOperationQueue } from './classroom/room-operation-queue.ts';
import { ClassroomStateDirectory } from './classroom/classroom-state.ts';
import { SharedContentDirectory } from './classroom/shared-content-directory.ts';
import { FileClassroomStore } from './classroom/classroom-store.ts';
import {
  createIvsChatProvider,
  resolveIvsChatRegion,
} from './chat/ivs-chat.ts';
import { createTencentChatProvider } from './chat/tencent-chat.ts';
import { createAgoraChatProvider } from './chat/agora-chat.ts';
import {
  issueParticipantCredential,
  requireParticipantCredential,
} from './participant-credential.ts';
import {
  issueRoomOwnerCredential,
  matchesRoomOwnerCredential,
} from './room-owner-credential.ts';
import { ProviderOperationError, ProviderRegistry } from './providers/provider-registry.ts';
import { RoomDirectory } from './providers/room-directory.ts';
import { createRoomClosure } from './services/room-closure.ts';
import { createRoomRegistryService } from './services/room-registry-service.ts';
import { createAdminAuth } from './services/admin-auth.ts';
import { createProviderSelection } from './services/provider-selection.ts';
import { createRoomOperations } from './services/room-operations.ts';
import { normalizeRoomCode, normalizeUserId, normalizeDisplayName, normalizeDeviceId, bindDevicePresence, parseRole, parseRoomMode, creatorRoleForMode, joinRoleForRoom } from './services/room-input.ts';
import { createTrtcProvider } from './providers/trtc.ts';
import { localizeDemoMessage, resolveDemoLanguage } from './i18n.ts';
import type {
  ChatProviderAdapter,
  ChatRoomEntry,
  MediaRole,
  ProviderAdapter,
  RoomAttendee,
  RoomMode,
  RoomEntry,
  NamedRoomEntry,
  RoomSummary,
} from './types.ts';

export async function createDemoApplication(env: NodeJS.ProcessEnv = process.env) {
const {CONTROL_REGION, MEDIA_REGION, CONTRACT_VERSION, MEDIA_CONTRACT_HEADER, CHAT_CONTRACT_HEADER, DEMO_BEARER_TOKEN, MEDIA_ADMIN_PASSWORD, ADMIN_SESSION_COOKIE, ADMIN_SESSION_TTL_SECONDS, IS_VERCEL, MEDIA_CONNECTIONS_ENABLED, INITIAL_PROVIDER, INITIAL_CHAT_PROVIDER, STARTED_AT, EMPTY_CLOSE_AFTER_MS, PARTICIPANT_STALE_AFTER_MS, SWEEP_INTERVAL_MS} = readDemoConfiguration(env);
const roomOperations = new RoomOperationQueue();
const liveInteractionDirectory = new LiveInteractionDirectory();
const classroomStateDir = env.CLASSROOM_STATE_DIR?.trim();
const classroomDirectory = new ClassroomStateDirectory(
  classroomStateDir ? new FileClassroomStore(classroomStateDir) : undefined,
);
const sharedContentDirectory = new SharedContentDirectory(classroomDirectory);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROVIDER_STATE_PATH = env.MEDIA_PROVIDER_STATE_PATH ?? path.join(__dirname, '.provider-state.json');

const app = express();
const trtcCloudRecorder = new TrtcCloudRecording(env);
app.set('trust proxy', 1);
app.use('/dashboard', express.static(path.join(__dirname, 'public', 'dashboard')));
app.use(cors({
  origin: true,
  methods: ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: [
    'Authorization',
    'Accept-Language',
    'Content-Type',
    'X-Media-Backend-Contract',
    'X-Realtime-Chat-Contract',
    'X-Chime-Backend-Contract',
  ],
  exposedHeaders: [MEDIA_CONTRACT_HEADER, CHAT_CONTRACT_HEADER],
  maxAge: 600,
}));
app.use(express.json({
  limit: '64kb',
  verify(req, _res, raw) {
    // Verify Tencent HMAC using the original bytes, not parsed JSON.
    if (req.url === '/webhooks/recording/trtc') {
      (req as Request & {rawBody?: Buffer}).rawBody = Buffer.from(raw);
    }
  },
}));
app.post('/webhooks/recording/trtc', (req, res) => {
  const bytes = (req as Request & {rawBody?: Buffer}).rawBody;
  if (!bytes || !trtcCloudRecorder.receiveCallback(
    bytes, req.get('Sign') ?? '', req.get('SdkAppId') ?? '',
  )) return res.sendStatus(403);
  return res.sendStatus(200);
});
app.use((req, res, next) => {
  res.vary('Accept-Language');
  res.locals.language = resolveDemoLanguage(req.get('Accept-Language'));
  next();
});


function bindLogicalIdentity(
  entry: RoomEntry,
  participantId: string,
  userId: string,
  displayName: string,
  deviceId: string | null,
  role: MediaRole,
): void {
  const current = entry.attendees.find(
    (attendee) => attendee.attendeeId === participantId,
  );
  if (!current) return;
  current.userId = userId;
  current.displayName = displayName;
  current.externalUserId = displayName;
  current.role = role;
  current.lastHeartbeatMs = Date.now();
  if (deviceId) current.deviceId = deviceId;
  entry.attendees = entry.attendees.filter((attendee) => {
    if (attendee.attendeeId === participantId) return true;
    if (attendee.role === 'host') {
      if (role === 'host') return false;
      // A normal join must not evict the logical owner merely by reusing its
      // public user id. The same device may replace its stale logical entry
      // without gaining host authority.
      return !(deviceId && attendee.deviceId === deviceId);
    }
    return (
      attendee.userId !== userId &&
      (!deviceId || attendee.deviceId !== deviceId)
    );
  });
}


const { hasAdminSession, setAdminCookie, clearAdminCookie, requireSameOrigin, requireAdmin } =
  createAdminAuth({
    password: MEDIA_ADMIN_PASSWORD,
    cookieName: ADMIN_SESSION_COOKIE,
    sessionTtlSeconds: ADMIN_SESSION_TTL_SECONDS,
    isVercel: IS_VERCEL, nodeEnv: env.NODE_ENV,
    contractError,
  });

function requireConnectionsEnabled(_req: Request, res: Response, next: NextFunction): Response | void {
  if (MEDIA_CONNECTIONS_ENABLED) return next();
  return contractError(res, 503, 'service-paused', 'The media connection service is paused.');
}

const chimeProvider = createChimeProvider({
  env: env,
  contractVersion: CONTRACT_VERSION,
  normalizeUserId,
});

function chatManagementCapabilities(
  provider: ChatProviderAdapter,
  canManage: boolean,
) {
  if (!canManage) {
    return {
      listMembers: false,
      removeMember: false,
      closeRoom: false,
      muteMember: false,
      banMember: false,
      recallMessage: false,
      manageRoles: false,
    };
  }
  return {
    listMembers: true,
    removeMember: typeof provider.removeMember === 'function',
    closeRoom: true,
    muteMember: false,
    banMember: false,
    recallMessage: false,
    manageRoles: false,
  };
}

function mediaManagementCapabilities(provider: ProviderAdapter) {
  return {
    listParticipants: true,
    removeParticipant:
      typeof provider.moderateRemoveParticipant === 'function',
    closeRoom: true,
    muteParticipant: false,
    stopParticipantVideo: false,
    changeParticipantRole: false,
  };
}

const ivsProvider = createIvsProvider({
  env: env,
  contractVersion: CONTRACT_VERSION,
  normalizeDisplayName,
});

const providerRegistry = new ProviderRegistry([
  chimeProvider,
  createLiveKitProvider({ env: env, contractVersion: CONTRACT_VERSION, normalizeDisplayName }),
  createAgoraProvider({ env: env, contractVersion: CONTRACT_VERSION, normalizeDisplayName }),
  createTrtcProvider({ env: env, contractVersion: CONTRACT_VERSION, normalizeDisplayName }),
  createArtcProvider({ env: env, contractVersion: CONTRACT_VERSION, normalizeDisplayName }),
  ivsProvider,
]);
const ivsChatRegion = await resolveIvsChatRegion(env);
const chatProviderRegistry = new ChatProviderRegistry([
  createIvsChatProvider({
    env: env,
    contractVersion: CONTRACT_VERSION,
    resolvedRegion: ivsChatRegion,
  }),
  createTencentChatProvider({
    env: env,
    contractVersion: CONTRACT_VERSION,
  }),
  createAgoraChatProvider({
    env: env,
    contractVersion: CONTRACT_VERSION,
  }),
]);
const roomDirectory = new RoomDirectory(env.DEMO_ROOM_STATE_PATH?.trim());
const chatRoomDirectory = new ChatRoomDirectory();
// Shared between the authenticated recording routes and room closure:
// a separate executor instance would lose all in-memory Agora resource IDs.
const agoraCloudRecorder = new AgoraCloudRecording(env);

const {
  generateRoomCode, registerRoom, assertRole, resolveRoom,
} = createRoomRegistryService({ roomDirectory, providerRegistry });

const closeRoomUnlocked = createRoomClosure({
  providerRegistry, chatProviderRegistry, roomDirectory,
  classroomDirectory, sharedContentDirectory, liveInteractionDirectory, logEvent,
  stopActiveRecording: async (entry) => {
    if (entry.provider === 'agora') {
      await agoraCloudRecorder.stopIfActive(entry as NamedRoomEntry);
    }
  },
});
const {
  pruneStaleAttendees, withRoomOperation, assertRoomOpen, closeRoom,
  summarizeRoom, isRoomPartiallyClosed,
} = createRoomOperations({
  roomDirectory, providerRegistry, roomOperations,
  participantStaleAfterMs: PARTICIPANT_STALE_AFTER_MS, closeRoomUnlocked,
});

registerChatRoutes(app, {
  chatRoomDirectory, chatProviderRegistry,
  currentChatProvider: () => activeChatProvider,
  contractVersion: CONTRACT_VERSION,
  resolveRoom, contractError, sendProviderError, chatManagementCapabilities,
  closeRoom, normalizeUserId, normalizeDisplayName, generateRoomCode, logEvent,
  requireSameOrigin, requireAdmin,
});


const events: Array<{ ts: string; type: string; message: string }> = [];

if (INITIAL_PROVIDER !== AWS_VENDOR_ID) providerRegistry.require(INITIAL_PROVIDER);

function engineProviderForSelection(providerId: string, roomMode: RoomMode): ProviderAdapter {
  const engineId = providerId === AWS_VENDOR_ID
    ? awsEngineForRoomMode(roomMode)
    : providerId;
  return providerRegistry.requireConfigured(engineId);
}

function publicProviderId(engineId: string): string {
  return publicVendorForEngine(engineId);
}

function exposeVendorResponse<T extends { provider: string; [key: string]: unknown }>(
  response: T,
): T {
  if (!isAwsEngine(response.provider)) return response;
  const engine = response.provider;
  return { ...response, provider: AWS_VENDOR_ID, vendor: AWS_VENDOR_ID, engine };
}

function providerMetadataForDashboard() {
  return [
    awsVendorMetadata(chimeProvider, ivsProvider),
    ...providerRegistry.metadata().filter((item) => !isAwsEngine(item.id)),
  ];
}

function logEvent(type: string, message: string): void {
  events.unshift({ ts: new Date().toISOString(), type, message });
  if (events.length > 200) events.pop();
  console.log(`[${type}] ${message}`);
}

function contractError(
  res: Response,
  status: number,
  code: string,
  message: string,
  details: unknown = undefined,
): Response {
  return res.status(status).json({
    contractVersion: CONTRACT_VERSION,
    error: {
      code,
      message: localizeDemoMessage(message, res.locals.language ?? 'en'),
      ...(details === undefined ? {} : { details }),
    },
  });
}

function sendProviderError(res: Response, error: unknown): Response | false {
  if (error instanceof ProviderOperationError) {
    return contractError(res, error.status, error.code, error.message, error.details);
  }
  return false;
}

function requireRoomContract(req: Request, res: Response, next: NextFunction): Response | void {
  res.set(MEDIA_CONTRACT_HEADER, String(CONTRACT_VERSION));
  res.set(CHAT_CONTRACT_HEADER, String(CONTRACT_VERSION));
  const requestedVersion =
    req.get(MEDIA_CONTRACT_HEADER) ??
    req.get(CHAT_CONTRACT_HEADER) ??
    req.get('X-Chime-Backend-Contract');
  if (requestedVersion && requestedVersion !== String(CONTRACT_VERSION)) {
    return contractError(
      res,
      400,
      'unsupported-contract-version',
      `This demo server supports backend contract v${CONTRACT_VERSION}.`,
    );
  }
  if (
    DEMO_BEARER_TOKEN &&
    req.get('Authorization') !== `Bearer ${DEMO_BEARER_TOKEN}` &&
    !hasAdminSession(req)
  ) {
    return contractError(res, 401, 'unauthorized', 'A valid demo bearer token is required.');
  }
  next();
}

app.use('/rooms', (req, res, next) => {
  const isRoomList = req.method === 'GET' && req.path === '/';
  const isRoomDiscovery = req.method === 'GET' && req.path === '/discover';
  const isRoomCleanup = req.method === 'DELETE' && /^\/[^/]+$/.test(req.path);
  // Export URLs contain a cryptographically random, single-use 60s ticket.
  // Unlike POST actions, no bearer credential can be attached by url_launcher.
  const isRecordingExport = req.method === 'GET' &&
    /^\/[^/]+\/recording\/export\/[^/]+$/.test(req.path);
  if (isRecordingExport) return requireConnectionsEnabled(req, res, next);
  if (isRoomList || isRoomDiscovery || isRoomCleanup) {
    return requireRoomContract(req, res, next);
  }
  return requireConnectionsEnabled(req, res, () => requireRoomContract(req, res, next));
});
const { loadPersistedProvider, loadPersistedChatProvider, persistActiveProviders } =
  createProviderSelection({
    providerRegistry, chatProviderRegistry,
    initialProvider: INITIAL_PROVIDER,
    initialChatProvider: INITIAL_CHAT_PROVIDER,
    statePath: PROVIDER_STATE_PATH,
    isVercel: IS_VERCEL,
  });

let activeProvider = loadPersistedProvider();
let activeChatProvider = loadPersistedChatProvider();


const sweeper = createIdleRoomSweeper({
  intervalMs: SWEEP_INTERVAL_MS,
  rooms: () => roomDirectory.entries(),
  sweep: (entry) => withRoomOperation(entry, async () => {
    const now = Date.now();
    pruneStaleAttendees(entry, now, true);
    if (entry.roomMode === 'meeting') classroomDirectory.snapshot(entry, false);
    if (now - (entry.lastHeartbeatMs ?? 0) <= EMPTY_CLOSE_AFTER_MS) return;
    const idleSec = Math.round((now - entry.lastHeartbeatMs) / 1000);
    await closeRoomUnlocked(entry, `idle ${idleSec}s, no heartbeat`);
  }),
  reportError: (entry, error) => console.error('auto-close failed', entry.roomCode, error),
});

const dashboardSelection: DashboardSelectionState = {
  get activeProvider() { return activeProvider; },
  set activeProvider(value: string) { activeProvider = value; },
  get activeChatProvider() { return activeChatProvider; },
  set activeChatProvider(value: string | null) { activeChatProvider = value; },
};

registerDashboardRoutes(app, {
  state: dashboardSelection, providerRegistry, chatProviderRegistry,
  chatRoomDirectory, roomDirectory,
  dashboardFilePath: path.join(__dirname, 'public', 'index.html'),
  mediaConnectionsEnabled: MEDIA_CONNECTIONS_ENABLED,
  isVercel: IS_VERCEL, contractVersion: CONTRACT_VERSION,
  controlRegion: CONTROL_REGION, mediaRegion: MEDIA_REGION,
  startedAt: STARTED_AT,
  adminPassword: MEDIA_ADMIN_PASSWORD,
  adminSessionTtlSeconds: ADMIN_SESSION_TTL_SECONDS,
  currentConfigured: () => dashboardSelection.activeProvider === AWS_VENDOR_ID
    ? chimeProvider.isConfigured() || ivsProvider.isConfigured()
    : providerRegistry.require(dashboardSelection.activeProvider).isConfigured(),
  providerMetadataForDashboard, persistActiveProviders,
  setAdminCookie, clearAdminCookie, contractError,
  sendProviderError, logEvent, summarizeRoom, isRoomPartiallyClosed,
  events, requireSameOrigin, requireAdmin,
});

registerInteractionRoutes(app, {
  resolveRoom,
  withRoomOperation,
  assertRoomOpen,
  isRoomPartiallyClosed,
  pruneStaleAttendees,
  sendProviderError,
  classroomDirectory,
  sharedContentDirectory,
  liveInteractionDirectory,
  providerRegistry,
});

registerRoomRoutes(app, {
  roomDirectory, providerRegistry, chatProviderRegistry, chatRoomDirectory,
  classroomDirectory, currentProvider: () => activeProvider,
  currentChatProvider: () => activeChatProvider, contractVersion: CONTRACT_VERSION,
  resolveRoom, withRoomOperation, assertRoomOpen, isRoomPartiallyClosed,
  pruneStaleAttendees, bindLogicalIdentity, normalizeRoomCode, normalizeDeviceId,
  normalizeDisplayName, normalizeUserId, parseRole, parseRoomMode,
  creatorRoleForMode, joinRoleForRoom, generateRoomCode, engineProviderForSelection,
  publicProviderId, exposeVendorResponse, registerRoom, assertRole,
  closeRoom, closeRoomUnlocked, contractError, sendProviderError,
  mediaManagementCapabilities, chatManagementCapabilities, logEvent,
  requireSameOrigin, requireAdmin,
});

registerRecordingRoutes(app, {
  resolveRoom,
  withRoomOperation,
  recorders: new Map<string, CloudRecordingExecutor>([
    ['livekit', new LiveKitCloudRecording(env)],
    ['trtc', trtcCloudRecorder],
    ['agora', agoraCloudRecorder],
    ['artc', env.ARTC_RECORDING_STORAGE === 'oss'
      ? new ArtcCloudRecording(env) : new ArtcVodRecording(env)],
    ['chime', new ChimeCloudRecording(env)],
    ['ivs', new IvsCloudRecording(env)],
  ]),
  contractError,
});

let server: ReturnType<typeof app.listen> | null = null;
let stopping: Promise<void> | null = null;
function start(port = Number(env.PORT ?? 3000)) {
  if (stopping) throw new Error('Demo application is stopping');
  if (server) return server;
  server = app.listen(port, '0.0.0.0', () => {
    const address = server?.address();
    const listeningPort = address && typeof address === 'object' ? address.port : port;
    console.log(`media-demo-server on :${listeningPort} (control=${CONTROL_REGION} media=${MEDIA_REGION})`);
    console.log(`active provider: ${activeProvider}`);
    for (const provider of providerRegistry.metadata()) {
      console.log(`${provider.displayName} configured: ${provider.configured ? 'yes' : 'no'}`);
    }
    console.log(`connections enabled: ${MEDIA_CONNECTIONS_ENABLED ? 'yes' : 'no'}`);
    console.log(`dashboard: http://127.0.0.1:${listeningPort}/`);
  });
  if (!IS_VERCEL) sweeper.start();
  return server;
}
function stop(): Promise<void> {
  return stopping ??= (async () => {
    await sweeper.stop();
    const listener = server;
    server = null;
    if (listener) await new Promise<void>((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));
  })();
}
return { app, providerRegistry, roomDirectory, start, stop };
}
