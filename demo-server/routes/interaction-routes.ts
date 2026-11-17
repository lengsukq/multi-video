import type { Express, Response } from 'express';
import type { InteractionApplicationDependencies } from '../services/interaction/interaction-operations.ts';
import { applicationHandler } from './application-handler.ts';
import {
  postClassroomAction,
  postClassroomSnapshot,
  postContentAction,
  postContentSnapshot,
  postLiveCohostCancel,
  postLiveCohostRequest,
  postLiveCohostRespond,
  postLiveGift,
  postLiveLike,
  postLiveSnapshot,
} from '../services/interaction/interaction-operations.ts';

export interface InteractionRouteDependencies extends InteractionApplicationDependencies {
  sendProviderError(res: Response, error: unknown): Response | false;
}

/** Provider-neutral classroom, shared content, and live interaction endpoints. */
export function registerInteractionRoutes(app: Express, dependencies: InteractionRouteDependencies): void {
  const applicationDependencies = dependencies;
  app.post('/rooms/:code/classroom/snapshot', applicationHandler(postClassroomSnapshot, applicationDependencies));
  app.post('/rooms/:code/classroom/action', applicationHandler(postClassroomAction, applicationDependencies));
  app.post('/rooms/:code/content/snapshot', applicationHandler(postContentSnapshot, applicationDependencies));
  app.post('/rooms/:code/content/action', applicationHandler(postContentAction, applicationDependencies));
  app.post('/rooms/:code/live/snapshot', applicationHandler(postLiveSnapshot, applicationDependencies));
  app.post('/rooms/:code/live/gift', applicationHandler(postLiveGift, applicationDependencies));
  app.post('/rooms/:code/live/like', applicationHandler(postLiveLike, applicationDependencies));
  app.post('/rooms/:code/live/cohost/request', applicationHandler(postLiveCohostRequest, applicationDependencies));
  app.post('/rooms/:code/live/cohost/cancel', applicationHandler(postLiveCohostCancel, applicationDependencies));
  app.post('/rooms/:code/live/cohost/respond', applicationHandler(postLiveCohostRespond, applicationDependencies));
}
