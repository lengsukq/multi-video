import type { RoomEntry } from '../types.ts';
import type { ProviderRegistry } from '../providers/provider-registry.ts';
import type { ChatProviderRegistry } from '../chat/chat-provider-registry.ts';
import type { RoomDirectory } from '../providers/room-directory.ts';
import type { ClassroomStateDirectory } from '../classroom/classroom-state.ts';
import type { SharedContentDirectory } from '../classroom/shared-content-directory.ts';
import type { LiveInteractionDirectory } from '../live/live-interactions.ts';

export interface RoomClosureDependencies {
  providerRegistry: ProviderRegistry;
  chatProviderRegistry: ChatProviderRegistry;
  roomDirectory: RoomDirectory;
  classroomDirectory: ClassroomStateDirectory;
  sharedContentDirectory?: SharedContentDirectory;
  liveInteractionDirectory: LiveInteractionDirectory;
  /** Stop billable vendor capture before removing room lookup and credentials. */
  stopActiveRecording?(entry: RoomEntry): Promise<void>;
  logEvent(type: string, message: string): void;
}

/**
 * Closes chat and media independently, preserving partially closed state for
 * a safe retry. Caller must hold the room operation queue lock.
 */
export function createRoomClosure(deps: RoomClosureDependencies) {
  const { providerRegistry, chatProviderRegistry, roomDirectory,
    classroomDirectory, sharedContentDirectory, liveInteractionDirectory, logEvent } = deps;
return async function closeRoomUnlocked(entry: RoomEntry, reason: string): Promise<void> {
  const provider = providerRegistry.require(entry.provider);
  // If the recorder fails to stop, preserve the room and its owner credential
  // so the host or idle sweeper can retry. Never silently drop the stop route.
  await deps.stopActiveRecording?.(entry);
  entry.closePending = true;
  let chatError: unknown;
  if (entry.chatProvider && !entry.chatClosed) {
    try {
      await chatProviderRegistry.require(entry.chatProvider).closeRoom(entry);
      entry.chatClosed = true;
    } catch (error) {
      chatError = error;
    }
  }
  let mediaError: unknown;
  if (!entry.mediaClosed) {
    try {
      await provider.closeRoom({ entry, reason });
      entry.mediaClosed = true;
    } catch (error) {
      mediaError = error;
    }
  }
  if (mediaError || chatError) {
    logEvent(
      'error',
      `room ${entry.roomCode} close incomplete (${reason}); retry remains possible`,
    );
    if (mediaError) throw mediaError;
    throw chatError;
  }
  roomDirectory.remove(entry);
  classroomDirectory.forget(entry);
  sharedContentDirectory?.forget(entry);
  liveInteractionDirectory.forget(entry);
  const suffix = entry.provider === 'chime' ? ' — billing for future joins stops' : '';
  logEvent('delete', `room ${entry.roomCode} closed (${reason})${suffix}`);
}

}
