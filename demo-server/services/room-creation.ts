import type {
  MediaRole,
  RoomMode,
  ProviderAdapter,
  CreateRoomResult,
} from '../types.ts';
import type { ChatProviderRegistry } from '../chat/chat-provider-registry.ts';
import { issueRoomOwnerCredential } from '../room-owner-credential.ts';

export interface RoomCreationInput {
  roomCode: string;
  roomMode: RoomMode;
  meetingMode?: 'standard' | 'classroom';
  preventScreenCapture?: boolean;
  role: MediaRole;
  provider: ProviderAdapter;
  selectedChatProvider: string | null;
}

export interface RoomCreationDependencies {
  chatProviderRegistry: ChatProviderRegistry;
  publicProviderId(engineId: string): string;
  mediaManagementCapabilities(provider: ProviderAdapter): {
    listParticipants: boolean;
    removeParticipant: boolean;
    closeRoom: boolean;
    muteParticipant: boolean;
    stopParticipantVideo: boolean;
    changeParticipantRole: boolean;
  };
  registerRoom(provider: ProviderAdapter, entry: CreateRoomResult['entry']): void;
  logEvent(type: string, message: string): void;
}

/**
 * Creates the media and optional chat room as one recoverable operation.
 * If Chat provisioning fails, the provider media room is closed before
 * reporting the original error. No HTTP request/response is handled here.
 */
export function createRoomProvisioner(deps: RoomCreationDependencies) {
  return async function provisionRoom({
    roomCode,
    roomMode,
    meetingMode,
    preventScreenCapture,
    role,
    provider,
    selectedChatProvider,
  }: RoomCreationInput) {
    const created = await provider.createRoom({ roomCode, role });
    created.entry.vendor = deps.publicProviderId(provider.id);
    created.entry.engine = provider.id;
    created.response.vendor = deps.publicProviderId(provider.id);
    created.response.engine = provider.id;

    if (selectedChatProvider) {
      try {
        const chat = await deps.chatProviderRegistry
          .requireConfigured(selectedChatProvider)
          .createRoom(roomCode);
        created.entry.chatProvider = chat.chatProvider;
        created.entry.chatRoomArn = chat.chatRoomArn;
        created.response.chatProvider = chat.chatProvider;
      } catch (error) {
        try {
          await provider.closeRoom({
            entry: created.entry,
            reason: 'chat room create rollback',
          });
        } catch (cleanupError) {
          console.error('media rollback after chat create failure failed', cleanupError);
        }
        throw error;
      }
    }

    created.entry.roomMode = roomMode;
    if (roomMode === 'meeting' && meetingMode) {
      created.entry.meetingMode = meetingMode;
      created.response.meetingMode = meetingMode;
    }
    if (preventScreenCapture === true) {
      created.entry.preventScreenCapture = true;
      created.response.preventScreenCapture = true;
    }
    if (roomMode === 'meeting' && meetingMode !== 'standard') {
      created.entry.classroomSpeakEnforcement =
        provider.setClassroomMicrophonePermission ? 'provider' : 'advisory';
    }
    created.response.roomMode = roomMode;
    if (roomMode === 'broadcast') created.response.liveInteractions = true;
    created.response.management = deps.mediaManagementCapabilities(provider);
    const roomOwnerCredential = issueRoomOwnerCredential(created.entry);
    if (roomOwnerCredential) {
      created.response.roomOwnerCredential = roomOwnerCredential;
    }
    deps.registerRoom(provider, created.entry);
    created.entry.lastHeartbeatMs = Date.now();
    deps.logEvent('create', `room ${roomCode} created with ${provider.displayName}`);
    return { created, roomOwnerCredential };
  };
}
