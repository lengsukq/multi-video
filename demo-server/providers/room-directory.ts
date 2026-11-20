import crypto from 'node:crypto';
import {readFileSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import type { RoomEntry } from '../types.ts';

export class RoomDirectory {
  private readonly statePath: string | undefined;
  private readonly byCode: Map<string, RoomEntry>;
  private readonly aliasToCode: Map<string, string>;

  constructor(statePath?: string) {
    this.statePath = statePath;
    this.byCode = new Map<string, RoomEntry>();
    this.aliasToCode = new Map<string, string>();
    if (statePath) {
      let contents: string | undefined;
      try {
        contents = readFileSync(statePath, 'utf8');
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      }
      if (contents) {
        const snapshot: unknown = JSON.parse(contents);
        if (!snapshot || typeof snapshot !== 'object' ||
            !('version' in snapshot) || snapshot.version !== 1 ||
            !('rooms' in snapshot) || !Array.isArray(snapshot.rooms)) {
          throw new Error('Invalid persisted Demo room snapshot.');
        }
        for (const raw of snapshot.rooms) {
          if (!raw || typeof raw !== 'object' ||
              !['chime', 'ivs'].includes(raw.provider) ||
              typeof raw.roomCode !== 'string' ||
              typeof raw.createdAt !== 'string' ||
              !Array.isArray(raw.attendees)) continue;
          const entry = raw as RoomEntry & {stageArn?: string};
          this.byCode.set(entry.roomCode, entry);
          if (entry.meeting?.MeetingId) {
            this.aliasToCode.set(entry.meeting.MeetingId, entry.roomCode);
          }
          if (entry.stageArn) this.aliasToCode.set(entry.stageArn, entry.roomCode);
        }
      }
    }
  }

  /** A local Demo-only checkpoint. Persist only the AWS room identity and
   * credential *hashes*, never SDK tokens or raw recording credentials. */
  flush(): void {
    if (!this.statePath) return;
    const rooms = [...this.byCode.values()]
      .filter((e) => e.provider === 'chime' || e.provider === 'ivs')
      .map((e) => {
        const ivs = e as RoomEntry & {stageArn?: string};
        return {
          provider: e.provider, roomCode: e.roomCode,
          createdAt: e.createdAt, lastHeartbeatMs: e.lastHeartbeatMs,
          vendor: e.vendor, engine: e.engine, roomMode: e.roomMode, meetingMode: e.meetingMode,
          ...(e.preventScreenCapture ? {preventScreenCapture: true} : {}),
          providerRoomName: e.providerRoomName, scene: e.scene,
          classroomTeacherUserId: e.classroomTeacherUserId,
          classroomSpeakEnforcement: e.classroomSpeakEnforcement,
          roomOwnerCredentialHash: e.roomOwnerCredentialHash,
          ...(e.provider === 'chime' ? {meeting: e.meeting} : {stageArn: ivs.stageArn}),
          attendees: e.attendees.map((a) => ({
            attendeeId: a.attendeeId, externalUserId: a.externalUserId,
            providerParticipantId: a.providerParticipantId,
            participantCredentialHash: a.participantCredentialHash,
            userId: a.userId, displayName: a.displayName,
            avatarUrl: a.avatarUrl,
            role: a.role, joinedAt: a.joinedAt,
            lastHeartbeatMs: a.lastHeartbeatMs, deviceId: a.deviceId,
          })),
        };
      });
    const tmp = this.statePath + '.' + crypto.randomUUID() + '.tmp';
    try {
      writeFileSync(tmp, JSON.stringify({version: 1, rooms}),
        {mode: 0o600, flag: 'wx'});
      renameSync(tmp, this.statePath);
    } finally {
      rmSync(tmp, {force: true});
    }
  }

  has(roomCode: unknown): boolean {
    return this.byCode.has(String(roomCode ?? '').trim());
  }

  get(ref: unknown): RoomEntry | null {
    const key = String(ref ?? '').trim();
    if (!key) return null;
    const direct = this.byCode.get(key);
    if (direct) return direct;
    const code = this.aliasToCode.get(key);
    return code ? this.byCode.get(code) ?? null : null;
  }

  register(entry: RoomEntry, aliases: string[] = []): RoomEntry {
    if (!entry?.roomCode || !entry?.provider) {
      throw new TypeError('Room entry requires roomCode and provider.');
    }
    this.byCode.set(entry.roomCode, entry);
    for (const alias of aliases) {
      const value = String(alias ?? '').trim();
      if (value) this.aliasToCode.set(value, entry.roomCode);
    }
    this.flush();
    return entry;
  }

  addAlias(entry: RoomEntry, alias: unknown): void {
    const value = String(alias ?? '').trim();
    if (entry?.roomCode && value) this.aliasToCode.set(value, entry.roomCode);
  }

  remove(entryOrCode: RoomEntry | string): boolean {
    const entry = typeof entryOrCode === 'string' ? this.get(entryOrCode) : entryOrCode;
    if (!entry) return false;
    this.byCode.delete(entry.roomCode);
    for (const [alias, code] of this.aliasToCode.entries()) {
      if (code === entry.roomCode) this.aliasToCode.delete(alias);
    }
    this.flush();
    return true;
  }

  entries(): RoomEntry[] {
    return [...this.byCode.values()];
  }

  get size(): number {
    return this.byCode.size;
  }
}
