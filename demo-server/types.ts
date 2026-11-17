export type MediaRole = 'participant' | 'host' | 'viewer';
export type RoomMode = 'meeting' | 'broadcast';
export type MediaVendorId = 'aws' | string;
export type ProviderCapabilitySupport =
  | 'supported'
  | 'conditional'
  | 'unsupported';

export interface ProviderCapability {
  key: string;
  label: string;
  support: ProviderCapabilitySupport;
  note?: string;
}

export interface ChatRoomEntry {
  chatProvider?: string;
  chatRoomArn?: string;
  roomCode: string;
  createdAt: string;
  attendees: RoomAttendee[];
  lastHeartbeatMs: number;
  roomOwnerCredentialHash?: string;
}

export interface RoomAttendee {
  attendeeId: string;
  providerParticipantId?: string;
  auxiliaryParticipantId?: string;
  participantCredentialHash?: string;
  externalUserId: string;
  userId?: string;
  displayName?: string;
  avatarUrl?: string;
  joinedAt: string;
  lastHeartbeatMs?: number;
  role?: MediaRole;
  deviceId?: string;
  chatRemoved?: boolean;
}

export interface ChatProviderMetadata {
  id: string;
  displayName: string;
  label: string;
  description: string;
  themeKey: string;
  enabled: boolean;
  configured: boolean;
  capabilities?: ProviderCapability[];
  engines?: Record<string, string>;
  [key: string]: unknown;
}

export interface ChatRoomBinding {
  chatProvider: string;
  chatRoomArn: string;
}

export interface ChatProviderCloudRoom {
  providerRoomId: string;
  name: string;
  type?: string;
  memberCount?: number;
  createdAt?: string;
  inferredRoomCode?: string;
}

export interface IssueChatTokenInput {
  entry: ChatRoomEntry;
  attendee: RoomAttendee;
}

export interface ChatProviderTokenResponse {
  contractVersion: number;
  chatProvider: string;
  roomCode: string;
  participantId: string;
  userId: string;
  displayName: string;
  role: MediaRole;
  chat: Record<string, unknown>;
}

export interface ChatProviderAdapter {
  id: string;
  displayName: string;
  label?: string;
  description?: string;
  themeKey?: string;
  enabled?: boolean;
  configurationError?: string;
  capabilityMatrix?: ProviderCapability[];

  isConfigured(): boolean;
  metadata?(): Record<string, unknown>;
  createRoom(roomCode: string): Promise<ChatRoomBinding>;
  issueToken(input: IssueChatTokenInput): Promise<ChatProviderTokenResponse>;
  closeRoom(entry: ChatRoomEntry): Promise<void>;
  removeMember?(entry: ChatRoomEntry, attendee: RoomAttendee): Promise<void>;
  listCloudRooms?(): Promise<ChatProviderCloudRoom[]>;
  deleteCloudRoom?(providerRoomId: string): Promise<void>;
}

export interface ChimeMeeting {
  MeetingId: string;
  ExternalMeetingId?: string;
  MediaRegion?: string;
  MediaPlacement?: unknown;
  MeetingArn?: string;
  TenantIds: string[];
}

export interface ChimeAttendee {
  AttendeeId: string;
  ExternalUserId: string;
  JoinToken?: string;
  Capabilities?: unknown;
}

export interface RoomEntry extends Partial<ChatRoomEntry> {
  classroomSpeakEnforcement?: 'provider' | 'advisory';
  /** Stable classroom teacher identity, distinct from the RTC media role. */
  classroomTeacherUserId?: string;
  provider: string;
  /** Public vendor identity. provider remains the concrete engine id. */
  vendor?: MediaVendorId;
  /** Concrete media implementation used for this room. */
  engine?: string;
  chatProvider?: string;
  chatRoomArn?: string;
  mediaClosed?: boolean;
  chatClosed?: boolean;
  closePending?: boolean;
  roomCode: string;
  roomMode?: RoomMode;
  meetingMode?: 'standard' | 'classroom';
  roomOwnerCredentialHash?: string;
  createdAt: string;
  attendees: RoomAttendee[];
  lastHeartbeatMs: number;
  providerRoomName?: string;
  scene?: 'meeting' | 'live';
  meeting?: ChimeMeeting;
}

export interface IvsRoomEntry extends RoomEntry {
  provider: 'ivs';
  stageArn: string;
}

export interface NamedRoomEntry extends RoomEntry {
  providerRoomName: string;
}

export interface TrtcRoomAttendee extends RoomAttendee {
  role: MediaRole;
}

export interface TrtcRoomEntry extends NamedRoomEntry {
  provider: 'trtc';
  scene: 'meeting' | 'live';
  attendees: TrtcRoomAttendee[];
}

export interface ArtcRoomAttendee extends RoomAttendee {
  role: MediaRole;
}

export interface ArtcRoomEntry extends NamedRoomEntry {
  provider: 'artc';
  scene: 'meeting' | 'live';
  attendees: ArtcRoomAttendee[];
}

export interface ChimeRoomEntry extends RoomEntry {
  provider: 'chime';
  meeting: ChimeMeeting;
}

export interface ProviderBaseResponse {
  /** Enables the optional provider-neutral Live interaction SDK. */
  liveInteractions?: boolean;
  contractVersion: number;
  provider: string;
  vendor?: MediaVendorId;
  engine?: string;
  role: MediaRole;
  roomCode: string;
  [key: string]: unknown;
}

export interface ProviderJoinResponse extends ProviderBaseResponse {
  participantId: string;
  displayName: string;
}

export interface RoomSummary {
  provider: string;
  vendor?: MediaVendorId;
  engine?: string;
  chatProvider?: string;
  roomCode: string;
  roomMode?: RoomMode;
  meetingMode?: 'standard' | 'classroom';
  meetingId?: string;
  externalMeetingId?: string;
  mediaRegion?: string;
  scene?: string;
  createdAt: string;
  lastHeartbeat: string;
  idleSec: number;
  attendeeCount: number;
  attendees: RoomAttendee[];
  shareText: string;
  shareLink: string;
}

export interface ProviderMetadata {
  id: string;
  displayName: string;
  label: string;
  description: string;
  themeKey: string;
  enabled: boolean;
  configured: boolean;
  capabilities?: ProviderCapability[];
  [key: string]: unknown;
}

export interface CreateRoomInput {
  roomCode: string;
  role: MediaRole;
  externalMeetingId?: string | null;
}

export interface CreateRoomResult {
  entry: RoomEntry;
  response: ProviderBaseResponse;
}

export interface JoinRoomInput {
  entry: RoomEntry;
  rawName: unknown;
  role: MediaRole;
  userId?: string;
  deviceId?: string | null;
  /** Provider-neutral classroom microphone permission at initial join. */
  classroomMicrophoneAllowed?: boolean;
}

export interface CloseRoomInput {
  entry: RoomEntry;
  reason: string;
}

export interface RefreshCredentialsInput {
  entry: RoomEntry;
  participantId: string;
  role: MediaRole;
}

export interface RemoveAttendeeResult {
  removed: boolean;
  closeWhenEmpty: boolean;
}

export interface ProviderAdapter {
  id: string;
  displayName: string;
  label?: string;
  description?: string;
  themeKey?: string;
  enabled?: boolean;
  configurationError?: string;
  capabilityMatrix?: ProviderCapability[];

  isConfigured(): boolean;
  metadata?(): Record<string, unknown>;
  supportsRole(role: MediaRole, entry?: RoomEntry | null): boolean;
  roleError?(entry: RoomEntry | null, role: MediaRole): string;
  aliases?(entry: RoomEntry): string[];

  createRoom(input: CreateRoomInput): Promise<CreateRoomResult>;
  joinRoom(input: JoinRoomInput): Promise<ProviderJoinResponse>;
  closeRoom(input: CloseRoomInput): Promise<void>;
  summarizeRoom(entry: RoomEntry, context: { host: string }): RoomSummary;

  removeAttendee?(entry: RoomEntry, who: unknown): RemoveAttendeeResult;
  moderateRemoveParticipant?(entry: RoomEntry, participantId: string): Promise<boolean>;
  /** Optional server-enforced classroom microphone source publishing. */
  setClassroomMicrophonePermission?(
    entry: RoomEntry, participantId: string, allowed: boolean,
  ): Promise<void>;
  refreshCredentials?(input: RefreshCredentialsInput): Promise<ProviderJoinResponse>;
  issueAuxiliaryMediaToken?(input: {
    entry: RoomEntry;
    participantId: string;
    purpose: 'screen_share';
    action: 'acquire' | 'revoke';
  }): Promise<Record<string, unknown>>;
  resolveExternalRoom?(
    ref: string,
    context: { allocateRoomCode: () => string },
  ): Promise<RoomEntry | null>;
}

export interface ProviderFactoryContext {
  env?: NodeJS.ProcessEnv;
  contractVersion: number;
}

export type NormalizeName = (raw: unknown) => string;
