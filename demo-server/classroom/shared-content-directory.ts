import type { RoomAttendee, RoomEntry } from '../types.ts';
import { ProviderOperationError } from '../providers/provider-registry.ts';
import type { ClassroomStateDirectory } from './classroom-state.ts';
import {
  applyClassroomTool,
  classroomToolsSnapshot,
  createClassroomTools,
  type ClassroomTools,
} from './classroom-tools.ts';

type ContentState = {
  revision: number;
  tools: ClassroomTools;
  handledIds: Map<string, string>;
};

function fail(message: string, code = 'invalid-argument', status = 400): never {
  throw new ProviderOperationError(status, code, message);
}

/**
 * Shared content (whiteboard & screen canvas) control plane across both
 * meeting and broadcast rooms without unlocking classroom-only actions.
 */
export class SharedContentDirectory {
  private readonly classroomDirectory: ClassroomStateDirectory;

  constructor(classroomDirectory: ClassroomStateDirectory) {
    this.classroomDirectory = classroomDirectory;
  }

  private readonly broadcastRooms = new WeakMap<RoomEntry, ContentState>();

  private getBroadcastState(entry: RoomEntry): ContentState {
    let state = this.broadcastRooms.get(entry);
    if (!state) {
      state = {
        revision: 0,
        tools: createClassroomTools(),
        handledIds: new Map(),
      };
      this.broadcastRooms.set(entry, state);
    }
    return state;
  }

  snapshot(entry: RoomEntry, requester: RoomAttendee, isManager: boolean) {
    if (entry.roomMode === 'meeting') {
      const classroom = this.classroomDirectory.snapshot(
        entry,
        isManager,
        requester.userId ?? requester.externalUserId,
      );
      return {
        contractVersion: 1,
        roomCode: entry.roomCode,
        revision: classroom.revision,
        content: classroom.tools.content,
      };
    }
    const state = this.getBroadcastState(entry);
    const tools = classroomToolsSnapshot(
      state.tools,
      isManager,
      requester.userId ?? requester.externalUserId,
    );
    return {
      contractVersion: 1,
      roomCode: entry.roomCode,
      revision: state.revision,
      content: {
        ...tools.content,
        canManage: isManager,
        canShareScreen: isManager,
        canAnnotateScreen: isManager,
      },
    };
  }

  act(
    entry: RoomEntry,
    requester: RoomAttendee,
    isManager: boolean,
    raw: Record<string, unknown>,
  ) {
    if (entry.roomMode === 'meeting') {
      const classroom = this.classroomDirectory.act(
        entry,
        requester,
        isManager,
        raw,
      );
      return {
        contractVersion: 1,
        roomCode: entry.roomCode,
        revision: classroom.revision,
        content: classroom.tools.content,
      };
    }
    const action = String(raw.action ?? '');
    if (
      !action.startsWith('tool.content.') &&
      !action.startsWith('tool.annotation.') &&
      !action.startsWith('tool.whiteboard.')
    ) {
      fail('Only content and whiteboard actions are supported in broadcast rooms', 'unsupported-feature', 400);
    }
    const idempotency = String(raw.eventId ?? '').trim();
    if (idempotency && !/^[a-zA-Z0-9_-]{8,128}$/.test(idempotency)) {
      fail('Invalid content eventId');
    }
    const state = this.getBroadcastState(entry);
    const userId = requester.userId ?? requester.externalUserId;
    const operationKey = JSON.stringify([userId, action, raw.payload ?? '']);
    if (idempotency) {
      const previous = state.handledIds.get(idempotency);
      if (previous && previous !== operationKey) {
        fail('Reused eventId with different payload', 'idempotency-conflict', 409);
      }
      if (previous) return this.snapshot(entry, requester, isManager);
    }
    const changed = applyClassroomTool(
      state.tools,
      action,
      raw,
      requester,
      isManager,
    );
    if (changed) state.revision++;
    if (idempotency) {
      state.handledIds.set(idempotency, operationKey);
      if (state.handledIds.size > 1000) {
        state.handledIds.delete(state.handledIds.keys().next().value!);
      }
    }
    return this.snapshot(entry, requester, isManager);
  }

  forget(entry: RoomEntry): void {
    this.broadcastRooms.delete(entry);
  }
}
