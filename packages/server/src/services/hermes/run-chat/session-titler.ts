/**
 * Session Auto-Titler — generates concise AI titles for chat sessions.
 *
 * After the first assistant response completes, this service makes a lightweight
 * LLM call through the Hermes gateway to produce a short (≤40 char) title.
 * Runs asynchronously — never blocks the chat flow.
 */

import { getSessionDetail, renameSession } from '../../../db/hermes/session-store'
import { logger } from '../../logger'
import { safeReadFile } from '../../config-helpers'
import { getProfileDir } from '../hermes-profile'
import { join } from 'path'
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

    // Build gateway URL from env vars (external gateway convention)
    const port = process.env.HERMES_WEB_UI_GATEWAY_PORT || '8080'
    const host = process.env.HERMES_WEB_UI_GATEWAY_HOST || '127.0.0.1'
    const upstream = `http://${host}:${port}`

    // Read API key from profile .env
    let apiKey = ''
    try {
      const envPath = join(getProfileDir(profile), '.env')
      const envContent = await safeReadFile(envPath) || ''
      const match = envContent.match(/^API_SERVER_KEY\s*=\s*"?([^"\n]+)"?\s*$/m)
      if (match) apiKey = match[1].trim()
    } catch {
      // Silently fall back to no API key
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
        model: '',
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 30,
        temperature: 0.3,
      }),
      signal: AbortSignal.timeout(15000),
    })

    if (!res.ok) {
      logger.warn('[session-titler] Gateway returned %d for %s', res.status, sessionId)
      return
    }

    const data = await res.json() as any
    const rawTitle = data?.choices?.[0]?.message?.content?.trim() || ''

    // Clean up the title
    let title = rawTitle
      .replace(/^['"`]+|['"`]+$/g, '')
      .replace(/^Title[:\s]*/i, '')
      .replace(/[^\x20-\x7E\u4e00-\u9fff\w\s-]/g, '')
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
