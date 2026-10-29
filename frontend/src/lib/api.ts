import { signOut } from 'aws-amplify/auth'
import { format } from 'date-fns'

import { getIdToken } from '@/lib/auth'

export type Participant = {
  id: string
  name: string
  email: string
}

export type AgendaItem = { topic: string; owner: string | null; minutes: number | null }
export type ActionItem = { task: string; owner: string | null; due: string | null }
export type Agenda = { title: string | null; items: AgendaItem[]; action_items: ActionItem[] }

/** What the parser returns: an agenda, plus what only a pasted text can say about the meeting. */
export type ParsedAgenda = Agenda & {
  starts_at: string | null
  duration_minutes: number | null
  language: string
}
export type AiSuggestion = { agenda: ParsedAgenda; model: string; prompt_version: string }
export type AgendaSave = Agenda & { ai_suggestion: AiSuggestion | null }

export type Meeting = {
  id: string
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participants: Participant[]
  agenda: Agenda | null
  created_at: string
}

export type MeetingCreate = {
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participant_ids: string[]
}

export type ParticipantCreate = {
  name: string
  email: string
}

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

// Backend origin, set at build time for AWS (the Lambda function URL). Empty locally,
// where the Vite dev server or nginx proxies /api to the backend.
const API_URL = (import.meta.env.VITE_API_URL ?? '').replace(/\/+$/, '')

type ValidationIssue = { loc?: (string | number)[]; msg: string }

function errorMessage(detail: unknown, fallback: string): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return (detail as ValidationIssue[])
      .map((issue) => {
        const field = issue.loc?.filter((part) => part !== 'body').join('.')
        const msg = issue.msg.replace(/^Value error, /, '')
        return field ? `${field}: ${msg}` : msg
      })
      .join('; ')
  }
  return fallback
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = await getIdToken()
  const response = await fetch(`${API_URL}/api${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
      ...init?.headers,
    },
  })

  // The session is gone (revoked, or the refresh token expired): sign out, which sends the
  // user back to the login page (see AuthProvider).
  if (response.status === 401) await signOut().catch(() => undefined)

  if (!response.ok) {
    let detail: unknown
    try {
      detail = (await response.json()).detail
    } catch {
      // body was not JSON
    }
    throw new ApiError(response.status, errorMessage(detail, response.statusText))
  }

  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export const api = {
  listMeetings: () => request<Meeting[]>('/meetings'),
  createMeeting: (data: MeetingCreate) =>
    request<Meeting>('/meetings', { method: 'POST', body: JSON.stringify(data) }),
  updateMeeting: ({ id, ...data }: MeetingCreate & { id: string }) =>
    request<Meeting>(`/meetings/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  saveAgenda: ({ id, ...data }: AgendaSave & { id: string }) =>
    request<Meeting>(`/meetings/${id}/agenda`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteMeeting: (id: string) => request<void>(`/meetings/${id}`, { method: 'DELETE' }),
  listParticipants: () => request<Participant[]>('/participants'),
  createParticipant: (data: ParticipantCreate) =>
    request<Participant>('/participants', { method: 'POST', body: JSON.stringify(data) }),
}

// The agenda parser is its own Lambda function with its own URL (make deploy-ai). It only
// suggests: nothing it returns is saved until the user presses Save, which goes through the API.
const PARSER_URL = (import.meta.env.VITE_AGENDA_PARSER_URL ?? '').replace(/\/+$/, '')
export const agendaParserConfigured = PARSER_URL !== ''
export const MAX_PASTE_CHARS = 10_000

export async function parseAgenda(text: string, signal: AbortSignal): Promise<AiSuggestion> {
  const token = await getIdToken()
  const response = await fetch(`${PARSER_URL}/api/parse-agenda`, {
    method: 'POST',
    signal,
    headers: {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
    },
    // The user's "Monday" is in the user's time zone; the function runs in UTC.
    body: JSON.stringify({
      text,
      today: format(new Date(), 'yyyy-MM-dd'),
      tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
    }),
  })
  if (!response.ok) {
    let detail: unknown
    try {
      detail = (await response.json()).detail
    } catch {
      // body was not JSON
    }
    throw new ApiError(response.status, errorMessage(detail, response.statusText))
  }
  const body = await response.json()
  return { agenda: body.agenda, model: body.model, prompt_version: body.prompt_version }
}
