import type { Express, RequestHandler, Response } from 'express';
import type { RoomApplicationDependencies } from '../services/room/dependencies.ts';
import { applicationHandler } from './application-handler.ts';
import { postRooms } from '../services/room/post-rooms.ts';
import { postRoomsByCodeJoin } from '../services/room/post-rooms-by-code-join.ts';
import { postRoomsByCodeChatToken } from '../services/room/post-rooms-by-code-chat-token.ts';
import { postRoomsByCodeCredentialsRefresh } from '../services/room/post-rooms-by-code-credentials-refresh.ts';
import { postRoomsByCodeAuxiliaryToken } from '../services/room/post-rooms-by-code-auxiliary-token.ts';
import { postRoomsByCodeHeartbeat } from '../services/room/post-rooms-by-code-heartbeat.ts';
import { postRoomsByCodeLeave } from '../services/room/post-rooms-by-code-leave.ts';
import { postRoomsByCodeParticipants } from '../services/room/post-rooms-by-code-participants.ts';
import { postRoomsByCodeParticipantsRemove } from '../services/room/post-rooms-by-code-participants-remove.ts';
import { postRoomsByCodeClose } from '../services/room/post-rooms-by-code-close.ts';
import { deleteRoomsByCode } from '../services/room/delete-rooms-by-code.ts';
export interface RoomRouteDependencies extends RoomApplicationDependencies {
  contractError(res: Response, status: number, code: string, message: string, details?: unknown): Response;
  sendProviderError(res: Response, error: unknown): Response | false;
  requireSameOrigin: RequestHandler;
  requireAdmin: RequestHandler;
}
export function registerRoomRoutes(app: Express, dependencies: RoomRouteDependencies): void {
const { requireSameOrigin, requireAdmin } = dependencies;
app.post('/rooms', applicationHandler(postRooms, dependencies));
app.post('/rooms/:code/join', applicationHandler(postRoomsByCodeJoin, dependencies));
app.post('/rooms/:code/chat/token', applicationHandler(postRoomsByCodeChatToken, dependencies));
app.post('/rooms/:code/credentials/refresh', applicationHandler(postRoomsByCodeCredentialsRefresh, dependencies));
app.post('/rooms/:code/media/auxiliary-token', applicationHandler(postRoomsByCodeAuxiliaryToken, dependencies));
app.post('/rooms/:code/heartbeat', applicationHandler(postRoomsByCodeHeartbeat, dependencies));
app.post('/rooms/:code/leave', applicationHandler(postRoomsByCodeLeave, dependencies));
app.post('/rooms/:code/participants', applicationHandler(postRoomsByCodeParticipants, dependencies));
app.post('/rooms/:code/participants/remove', applicationHandler(postRoomsByCodeParticipantsRemove, dependencies));
app.post('/rooms/:code/close', applicationHandler(postRoomsByCodeClose, dependencies));
app.delete('/rooms/:code', requireSameOrigin, requireAdmin, applicationHandler(deleteRoomsByCode, dependencies));
}
