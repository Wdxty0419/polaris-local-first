type FingertipsOptions = {
 pauseMs?: number;
 abandonAfterMs?: number;
 maxAbandonedDrafts?: number;
 now?: () => number;
};

type InputSegment = {
 startedAt: number;
 lastInputAt: number;
 pings: number[];
};

type DraftSession = {
 startedAt: number;
 updatedAt: number;
 inputSegments: InputSegment[];
};

type FingertipsState = {
 draftSession: DraftSession | null;
 abandonedDrafts: DraftSession[];
};

type SessionSummary = {
 durationMs: number;
 pauses: number;
};

const DEFAULTS = {
 pauseMs: 2000,
 abandonAfterMs: 60_000,
 maxAbandonedDrafts: 8,
 now: () => Date.now()
};

function createEmptyState(): FingertipsState {
 return {
 draftSession: null,
 abandonedDrafts: []
 };
}

function cloneSession(session: DraftSession): DraftSession {
 return {
 startedAt: session.startedAt,
 updatedAt: session.updatedAt,
 inputSegments: session.inputSegments.map((segment) => ({
 startedAt: segment.startedAt,
 lastInputAt: segment.lastInputAt,
 pings: [...segment.pings]
 }))
 };
}

function cloneState(state: FingertipsState): FingertipsState {
 return {
 draftSession: state.draftSession ? cloneSession(state.draftSession) : null,
 abandonedDrafts: state.abandonedDrafts.map(cloneSession)
 };
}

function assertTimestamp(timestamp: number): void {
 if (!Number.isFinite(timestamp)) {
 throw new TypeError('timestamp must be finite');
 }
}

function flattenPings(session: DraftSession): number[] {
 return session.inputSegments.flatMap((segment) => segment.pings);
}

export function summarizeSession(
 session: DraftSession,
 pauseMs = DEFAULTS.pauseMs
): SessionSummary {
 const pings = flattenPings(session);

 if (pings.length === 0) {
 return {
 durationMs: 0,
 pauses: 0
 };
 }

 let pauses = 0;

 for (let index = 1; index < pings.length; index += 1) {
 if (pings[index] - pings[index - 1] > pauseMs) {
 pauses += 1;
 }
 }

 return {
 durationMs: Math.max(0, pings[pings.length - 1] - pings[0]),
 pauses
 };
}

function roundedSeconds(durationMs: number): number {
 return Math.max(0, Math.round(durationMs / 1000));
}

function minutesAgo(timestamp: number, now: number): number {
 return Math.max(1, Math.round((now - timestamp) / 60_000));
}

function formatSummary(
 summary: SessionSummary,
 subject: string
): string {
 const pauseText = summary.pauses === 0
 ? '中途没有明显停顿'
 : `中途停下来想了${summary.pauses}次`;

 return `这条消息${subject}输入了约${roundedSeconds(summary.durationMs)}秒，${pauseText}。`;
}

export type Fingertips = ReturnType<typeof createFingertips>;

export default function createFingertips(options: FingertipsOptions = {}) {
 const config = {
 ...DEFAULTS,
 ...options
 };

 const state = createEmptyState();
 let abandonTimer: ReturnType<typeof setTimeout> | null = null;

 const clearAbandonTimer = () => {
 if (abandonTimer !== null) {
 clearTimeout(abandonTimer);
 abandonTimer = null;
 }
 };

 const scheduleAbandonment = () => {
 clearAbandonTimer();

 if (!state.draftSession) {
 return;
 }

 const scheduledFor =
 state.draftSession.updatedAt + config.abandonAfterMs;

 abandonTimer = setTimeout(() => {
 const now = config.now();

 if (
 state.draftSession
 && now - state.draftSession.updatedAt >= config.abandonAfterMs
 ) {
 abandonCurrentDraft(now);
 } else {
 scheduleAbandonment();
 }
 }, Math.max(0, scheduledFor - config.now()));
 };

 const startSession = (timestamp: number) => {
 assertTimestamp(timestamp);

 state.draftSession = {
 startedAt: timestamp,
 updatedAt: timestamp,
 inputSegments: [
 {
 startedAt: timestamp,
 lastInputAt: timestamp,
 pings: [timestamp]
 }
 ]
 };

 scheduleAbandonment();
 };

 const abandonCurrentDraft = (timestamp = config.now()): boolean => {
 if (!state.draftSession) {
 return false;
 }

 assertTimestamp(timestamp);

 state.abandonedDrafts.push(state.draftSession);

 if (state.abandonedDrafts.length > config.maxAbandonedDrafts) {
 state.abandonedDrafts.splice(
 0,
 state.abandonedDrafts.length - config.maxAbandonedDrafts
 );
 }

 state.draftSession = null;
 clearAbandonTimer();

 return true;
 };

 const recordPing = (timestamp = config.now()): boolean => {
 assertTimestamp(timestamp);

 if (!state.draftSession) {
 startSession(timestamp);
 return true;
 }

 const session = state.draftSession;
 const segment = session.inputSegments[session.inputSegments.length - 1];

 if (timestamp < segment.lastInputAt) {
 return false;
 }

 segment.pings.push(timestamp);
 segment.lastInputAt = timestamp;
 session.updatedAt = timestamp;

 scheduleAbandonment();

 return true;
 };

 return {
 recordInput(timestamp = config.now()): boolean {
 return recordPing(timestamp);
 },

 clearInput(timestamp = config.now()): boolean {
 return abandonCurrentDraft(timestamp);
 },

 abandon(timestamp = config.now()): boolean {
 return abandonCurrentDraft(timestamp);
 },

 consumeAttachment(
 subject = '汤圆',
 timestamp = config.now()
 ): string {
 assertTimestamp(timestamp);

 const current = state.draftSession;
 const abandoned = state.abandonedDrafts;

 if (!current && abandoned.length === 0) {
 return '';
 }

 const lines = [
 '[Fingertips 指尖语气]',
 `以下是${subject}输入这条消息时留下的节奏，仅供感受。`
 ];

 for (const draft of abandoned) {
 const summary = summarizeSession(draft, config.pauseMs);

 lines.push(
 `${subject} ${minutesAgo(draft.updatedAt, timestamp)}分钟前输入了约${roundedSeconds(summary.durationMs)}秒，那条没有发出来。`
 );
 }

 if (current) {
 lines.push(
 formatSummary(
 summarizeSession(current, config.pauseMs),
 subject
 )
 );
 }

 state.draftSession = null;
 state.abandonedDrafts.length = 0;
 clearAbandonTimer();

 return lines.join('\n');
 },

 getState(): FingertipsState {
 return cloneState(state);
 },

 reset(): void {
 state.draftSession = null;
 state.abandonedDrafts.length = 0;
 clearAbandonTimer();
 }
 };
}
