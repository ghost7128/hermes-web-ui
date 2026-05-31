/**
 * Session Auto-Titler — generates concise AI titles for chat sessions.
 *
 * After the first assistant response completes, this service makes a lightweight
 * LLM call through the Hermes gateway to produce a short (≤40 char) title.
 * Runs asynchronously — never blocks the chat flow.
 */

import { getSessionDetail, renameSession } from '../../../db/hermes/session-store'
import { getGatewayManagerInstance } from '../../gateway-bootstrap'
import { logger } from '../../logger'
import type { HermesMessageRow } from '../../../db/hermes/session-store'

const TITLE_PROMPT = `Based on this conversation, generate a very short title (max 40 characters, single line, no quotes, no punctuation) that captures the main topic or intent. Return ONLY the title text, nothing else.

User:`

/**
 * Attempt to auto-generate a title for a session after the first exchange.
 * Fire-and-forget — errors are logged and silently swallowed.
 */
export async function autoGenerateSessionTitle(
  sessionId: string,
  profile: string,
  emit?: (event: string, payload: any) => void,
): Promise<void> {
  try {
    const detail = getSessionDetail(sessionId)
    if (!detail || !detail.messages || detail.messages.length < 2) return

    // Don't overwrite a title the user already set manually
    if (detail.title && !looksLikePreviewTitle(detail.title, detail.messages)) return

    const firstUser = detail.messages.find(m => m.role === 'user')
    const firstAssistant = detail.messages.find(m => m.role === 'assistant')
    if (!firstUser) return

    // Get gateway credentials
    const mgr = getGatewayManagerInstance()
    if (!mgr) {
      logger.debug('[session-titler] Gateway manager not available for %s', sessionId)
      return
    }

    const upstream = String(mgr.getUpstream(profile) || '').replace(/\/+$/, '')
    const apiKey = typeof mgr.getApiKey === 'function'
      ? await Promise.resolve(mgr.getApiKey(profile)) || ''
      : ''

    if (!upstream) {
      logger.debug('[session-titler] No gateway upstream for profile %s', profile)
      return
    }

    // Build a compact prompt from the first exchange
    const userText = firstUser.content?.slice(0, 400) || ''
    const assistantText = firstAssistant?.content?.slice(0, 400) || ''
    const prompt = `${TITLE_PROMPT} ${userText}\n\nAssistant: ${assistantText}\n\nTitle:`

    const chatUrl = `${upstream}/v1/chat/completions`
    const headers: Record<string, string> = { 'Content-Type': 'application/json' }
    if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`

    const res = await fetch(chatUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        model: '', // gateway picks the default model
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 30,
        temperature: 0.3,
      }),
      signal: AbortSignal.timeout(15000),
    })

    if (!res.ok) {
      logger.warn(
        '[session-titler] Gateway returned %d for %s',
        res.status,
        sessionId,
      )
      return
    }

    const data = await res.json() as any
    const rawTitle = data?.choices?.[0]?.message?.content?.trim() || ''

    // Clean up the title
    let title = rawTitle
      .replace(/^['"`]+|['"`]+$/g, '')   // strip surrounding quotes
      .replace(/^Title[:\s]*/i, '')        // strip "Title:" prefix
      .replace(/[^\x20-\x7E\u4e00-\u9fff\w\s-]/g, '') // keep ASCII printable + CJK
      .trim()

    if (!title || title.length > 60 || title.length < 2) {
      logger.debug('[session-titler] Invalid title for %s: "%s"', sessionId, title || '(empty)')
      return
    }

    // Truncate to 40 chars with ellipsis
    if (title.length > 40) title = title.slice(0, 39) + '…'

    // Update the session
    renameSession(sessionId, title)
    logger.info('[session-titler] Generated title for %s: "%s"', sessionId, title)

    // Notify connected clients
    if (emit) {
      emit('session.title_updated', { session_id: sessionId, title })
    }
  } catch (err: any) {
    if (err?.name === 'AbortError') {
      logger.debug('[session-titler] Timeout generating title for %s', sessionId)
    } else {
      logger.warn({ err }, '[session-titler] Failed to generate title for %s', sessionId)
    }
  }
}

/**
 * Check if a title looks like the auto-generated preview (first message truncated).
 */
function looksLikePreviewTitle(title: string, messages: HermesMessageRow[]): boolean {
  const firstUser = messages.find(m => m.role === 'user')
  if (!firstUser?.content) return false
  const preview = firstUser.content.replace(/[\r\n]/g, ' ').substring(0, 100)
  return title === preview || title === preview.substring(0, 40) + (firstUser.content.length > 40 ? '...' : '')
}
