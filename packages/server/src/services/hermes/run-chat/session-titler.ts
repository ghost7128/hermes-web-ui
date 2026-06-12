/**
 * Session Auto-Titler — generates concise AI titles for chat sessions.
 * Calls the external gateway to produce a short (≤40 char) title.
 */

import { getSessionDetail, renameSession } from '../../../db/hermes/session-store'
import { config } from '../../../config'
import { logger } from '../../logger'
import type { HermesMessageRow } from '../../../db/hermes/session-store'

const TITLE_PROMPT = `Based on this conversation, generate a very short title (max 40 characters, single line, no quotes, no punctuation) that captures the main topic or intent. Return ONLY the title text, nothing else.

User:`

export async function autoGenerateSessionTitle(
  sessionId: string,
  profile: string,
  emit?: (event: string, payload: any) => void,
): Promise<void> {
  try {
    const detail = getSessionDetail(sessionId)
    if (!detail || !detail.messages || detail.messages.length < 2) return
    if (detail.title && !looksLikePreviewTitle(detail.title, detail.messages)) return

    const firstUser = detail.messages.find(m => m.role === 'user')
    const firstAssistant = detail.messages.find(m => m.role === 'assistant')
    if (!firstUser) return

    const upstream = config.gatewayHost ? `http://${config.gatewayHost}` : ''
    if (!upstream) {
      logger.debug('[session-titler] No gateway host configured')
      return
    }

    const apiKey = config.apiServerKey || ''
    const userText = firstUser.content?.slice(0, 400) || ''
    const assistantText = firstAssistant?.content?.slice(0, 400) || ''
    const prompt = `${TITLE_PROMPT} ${userText}\n\nAssistant: ${assistantText}\n\nTitle:`
    const headers: Record<string, string> = { 'Content-Type': 'application/json' }
    if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`

    const res = await fetch(`${upstream}/v1/chat/completions`, {
      method: 'POST', headers,
      body: JSON.stringify({ model: '', messages: [{ role: 'user', content: prompt }], max_tokens: 30, temperature: 0.3 }),
      signal: AbortSignal.timeout(15000),
    })
    if (!res.ok) { logger.warn('[session-titler] Gateway returned %d for %s', res.status, sessionId); return }

    const rawTitle = ((await res.json()) as any)?.choices?.[0]?.message?.content?.trim() || ''
    let title = rawTitle.replace(/^['"`]+|['"`]+$/g, '').replace(/^Title[:\s]*/i, '').replace(/[^\x20-\x7E\u4e00-\u9fff\w\s-]/g, '').trim()
    if (!title || title.length > 60 || title.length < 2) return
    if (title.length > 40) title = title.slice(0, 39) + '…'

    renameSession(sessionId, title)
    logger.info('[session-titler] Generated title for %s: "%s"', sessionId, title)
    if (emit) emit('session.title_updated', { session_id: sessionId, title })
  } catch (err: any) {
    if (err?.name !== 'AbortError') logger.warn({ err }, '[session-titler] Failed for %s', sessionId)
  }
}

function looksLikePreviewTitle(title: string, messages: HermesMessageRow[]): boolean {
  const firstUser = messages.find(m => m.role === 'user')
  if (!firstUser?.content) return false
  const preview = firstUser.content.replace(/[\r\n]/g, ' ').substring(0, 100)
  return title === preview || title === preview.substring(0, 40) + (firstUser.content.length > 40 ? '...' : '')
}
