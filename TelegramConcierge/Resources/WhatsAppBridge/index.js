// WhatsApp bridge for Briglia.
//
// Speaks the WhatsApp Web multi-device protocol via Baileys and exposes a
// JSON-lines protocol over stdio to the Swift host (WhatsAppChannelService):
//
//   stdout (bridge → host), one JSON object per line:
//     {type:"status", state:"connecting"|"qr"|"connected"|"disconnected"|"logged_out", qr?, me?, detail?}
//     {type:"message", from, fromPhone, timestamp, text?, caption?, quoted?,
//      media?: {kind:"image"|"video"|"document"|"voice"|"audio", path, filename, mimeType, sizeBytes}}
//     (a recorded voice note — ptt — is "voice" and is transcribed; any other
//     audio file is "audio" and is handled as a file, never transcribed)
//     {type:"result", id, ok, error?}
//     {type:"log", level, msg}
//
//   stdin (host → bridge), one JSON object per line:
//     {type:"send_text", id, to, text}
//     {type:"send_image", id, to, path, caption?, mimeType?}
//     {type:"send_document", id, to, path, filename?, caption?, mimeType?}
//     {type:"logout", id}
//
// Environment:
//   WA_AUTH_DIR    — directory for Baileys multi-file auth state (session credentials)
//   WA_MEDIA_DIR   — spool directory for downloaded inbound media
//   WA_OWNER_PHONE — owner phone number; ONLY this number may prompt the agent.
//                    All other inbound traffic is dropped (and never surfaced).
//
// Security note: this bridge is deliberately single-user. Until multi-party
// conversations get a proper prompt-injection threat model, anything not from
// the owner is ignored at the lowest layer.

import * as baileysModule from 'baileys'
import pino from 'pino'
import fs from 'fs'
import path from 'path'
import readline from 'readline'

const baileys = baileysModule.default?.makeWASocket ? baileysModule.default : baileysModule
const makeWASocket = baileys.makeWASocket ?? baileys.default
const { useMultiFileAuthState, fetchLatestBaileysVersion, downloadMediaMessage, DisconnectReason } = baileys

const AUTH_DIR = process.env.WA_AUTH_DIR
const MEDIA_DIR = process.env.WA_MEDIA_DIR
const OWNER_PHONE = process.env.WA_OWNER_PHONE || ''

if (!AUTH_DIR || !MEDIA_DIR) {
  process.stderr.write('WA_AUTH_DIR and WA_MEDIA_DIR are required\n')
  process.exit(2)
}
const ownerDigits = OWNER_PHONE.replace(/\D/g, '')
if (!ownerDigits) {
  process.stderr.write('WA_OWNER_PHONE is required (digits of the owner phone number)\n')
  process.exit(2)
}

fs.mkdirSync(AUTH_DIR, { recursive: true })
fs.mkdirSync(MEDIA_DIR, { recursive: true })

// Keep Baileys' logger off stdout — stdout is reserved for the JSON protocol.
const logger = pino({ level: process.env.WA_LOG_LEVEL || 'silent' }, pino.destination(2))

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n')
}
function log(level, msg) {
  emit({ type: 'log', level, msg: String(msg).slice(0, 2000) })
}

// Purge spooled media older than 7 days — the Swift host copies what it keeps.
try {
  const cutoff = Date.now() - 7 * 24 * 3600 * 1000
  for (const f of fs.readdirSync(MEDIA_DIR)) {
    const p = path.join(MEDIA_DIR, f)
    try { if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p) } catch {}
  }
} catch {}

// ---- Owner allowlist -------------------------------------------------------

function jidDigits(jid) {
  if (!jid || typeof jid !== 'string') return ''
  return jid.split('@')[0].split(':')[0].replace(/\D/g, '')
}

/// True only for direct (non-group) messages from the owner's number.
/// Checks every JID field Baileys may populate across versions — with the
/// LID migration, key.remoteJid can be "...@lid" while the phone-number JID
/// rides in remoteJidAlt / senderPn.
function isFromOwner(key) {
  const remote = key.remoteJid || ''
  if (remote.endsWith('@g.us') || remote === 'status@broadcast' || remote.endsWith('@broadcast')) return false
  const candidates = [key.remoteJid, key.remoteJidAlt, key.senderPn, key.participant, key.participantAlt]
  return candidates.some(j => jidDigits(j) === ownerDigits)
}

// ---- Message unwrapping ----------------------------------------------------

function unwrap(message) {
  if (!message) return null
  if (message.ephemeralMessage) return unwrap(message.ephemeralMessage.message)
  if (message.viewOnceMessage) return unwrap(message.viewOnceMessage.message)
  if (message.viewOnceMessageV2) return unwrap(message.viewOnceMessageV2.message)
  if (message.documentWithCaptionMessage) return unwrap(message.documentWithCaptionMessage.message)
  return message
}

function extFor(mimeType, fallback) {
  const map = {
    'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif',
    'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/webm': 'webm',
    'audio/ogg; codecs=opus': 'ogg', 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a',
    'application/pdf': 'pdf'
  }
  return map[mimeType] || fallback
}

function quotedSummary(msg) {
  const ctx = msg?.contextInfo
  const q = unwrap(ctx?.quotedMessage)
  if (!q) return null
  const text = q.conversation || q.extendedTextMessage?.text || q.imageMessage?.caption
    || q.videoMessage?.caption || q.documentMessage?.caption
    || (q.imageMessage ? '[image]' : q.videoMessage ? '[video]' : q.documentMessage ? `[document: ${q.documentMessage.fileName || 'file'}]` : q.audioMessage ? (q.audioMessage.ptt === true ? '[voice message]' : '[audio file]') : null)
  if (!text) return null
  const fromMe = jidDigits(ctx?.participant) !== ownerDigits
  return { text: String(text).slice(0, 1000), fromMe }
}

// ---- Socket lifecycle ------------------------------------------------------

let sock = null
let stopping = false

async function startSocket() {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR)
  let version
  try {
    ({ version } = await fetchLatestBaileysVersion())
  } catch {
    version = undefined // fall back to the library's baked-in version when offline
  }

  emit({ type: 'status', state: 'connecting' })

  sock = makeWASocket({
    version,
    auth: state,
    logger,
    printQRInTerminal: false,
    syncFullHistory: false,
    markOnlineOnConnect: false
  })

  sock.ev.on('creds.update', saveCreds)

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update
    if (qr) {
      emit({ type: 'status', state: 'qr', qr })
    }
    if (connection === 'open') {
      emit({ type: 'status', state: 'connected', me: sock.user?.id || null })
    }
    if (connection === 'close') {
      const statusCode = lastDisconnect?.error?.output?.statusCode
      if (statusCode === DisconnectReason.loggedOut) {
        emit({ type: 'status', state: 'logged_out' })
        // Session is dead — clear credentials so the next start shows a fresh QR.
        try { fs.rmSync(AUTH_DIR, { recursive: true, force: true }); fs.mkdirSync(AUTH_DIR, { recursive: true }) } catch {}
        if (!stopping) setTimeout(() => startSocket().catch(e => log('error', e)), 2000)
      } else {
        emit({ type: 'status', state: 'disconnected', detail: String(lastDisconnect?.error?.message || statusCode || 'unknown') })
        if (!stopping) setTimeout(() => startSocket().catch(e => log('error', e)), 3000)
      }
    }
  })

  sock.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify') return
    for (const m of messages) {
      try {
        await handleInbound(m)
      } catch (e) {
        log('error', `inbound handling failed: ${e?.message || e}`)
      }
    }
  })
}

async function handleInbound(m) {
  if (!m.message || !m.key) return
  if (m.key.fromMe) return                 // agent's own outbound (or phone-app sends)
  if (!isFromOwner(m.key)) return          // single-user policy: silently drop

  const msg = unwrap(m.message)
  if (!msg) return
  // Pure protocol/reaction events carry no user content.
  if (msg.protocolMessage || msg.reactionMessage || msg.pollUpdateMessage) return

  const out = {
    type: 'message',
    from: m.key.remoteJid,
    fromPhone: ownerDigits,
    timestamp: Number(m.messageTimestamp) || Math.floor(Date.now() / 1000)
  }

  let mediaSource = null
  if (msg.conversation) {
    out.text = msg.conversation
  } else if (msg.extendedTextMessage?.text) {
    out.text = msg.extendedTextMessage.text
    out.quoted = quotedSummary(msg.extendedTextMessage)
  } else if (msg.imageMessage) {
    mediaSource = { kind: 'image', node: msg.imageMessage, defaultExt: 'jpg' }
  } else if (msg.videoMessage) {
    mediaSource = { kind: 'video', node: msg.videoMessage, defaultExt: 'mp4' }
  } else if (msg.documentMessage) {
    mediaSource = { kind: 'document', node: msg.documentMessage, defaultExt: 'bin' }
  } else if (msg.audioMessage) {
    // Recorded voice notes (ptt) keep the voice path; ordinary audio files
    // arrive as files (owner rule, plan v2 §3.4).
    const ptt = msg.audioMessage.ptt === true
    mediaSource = { kind: ptt ? 'voice' : 'audio', node: msg.audioMessage, defaultExt: ptt ? 'ogg' : 'm4a' }
  } else {
    return // unsupported message type (location, contact, poll, sticker...)
  }

  if (mediaSource) {
    const { kind, node, defaultExt } = mediaSource
    const mimeType = node.mimetype || ''
    const declaredName = node.fileName || null
    try {
      const buffer = await downloadMediaMessage(m, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage })
      const ext = declaredName ? (path.extname(declaredName).slice(1) || extFor(mimeType, defaultExt)) : extFor(mimeType, defaultExt)
      const fileName = `wa_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`
      const filePath = path.join(MEDIA_DIR, fileName)
      fs.writeFileSync(filePath, buffer)
      out.media = {
        kind,
        path: filePath,
        filename: declaredName || fileName,
        mimeType,
        sizeBytes: buffer.length
      }
    } catch (e) {
      out.mediaError = `download failed: ${e?.message || e}`
    }
    if (node.caption) out.caption = node.caption
    if (msg.extendedTextMessage === undefined && node.contextInfo) {
      out.quoted = quotedSummary(node)
    }
  }

  emit(out)
}

// ---- Outbound commands -----------------------------------------------------

async function handleCommand(cmd) {
  const id = cmd.id ?? null
  const ack = (ok, error) => emit({ type: 'result', id, ok, error: error ? String(error).slice(0, 500) : undefined })

  if (!sock) return ack(false, 'socket not started')

  try {
    switch (cmd.type) {
      case 'send_text': {
        if (!cmd.to || typeof cmd.text !== 'string') return ack(false, 'missing to/text')
        await sock.sendMessage(cmd.to, { text: cmd.text })
        return ack(true)
      }
      case 'send_image': {
        const data = fs.readFileSync(cmd.path)
        await sock.sendMessage(cmd.to, { image: data, caption: cmd.caption || undefined })
        return ack(true)
      }
      case 'send_document': {
        const data = fs.readFileSync(cmd.path)
        await sock.sendMessage(cmd.to, {
          document: data,
          fileName: cmd.filename || path.basename(cmd.path),
          mimetype: cmd.mimeType || 'application/octet-stream',
          caption: cmd.caption || undefined
        })
        return ack(true)
      }
      case 'logout': {
        stopping = true
        try { await sock.logout() } catch {}
        try { fs.rmSync(AUTH_DIR, { recursive: true, force: true }) } catch {}
        ack(true)
        process.exit(0)
      }
      default:
        return ack(false, `unknown command: ${cmd.type}`)
    }
  } catch (e) {
    return ack(false, e?.message || e)
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false })
rl.on('line', (line) => {
  const trimmed = line.trim()
  if (!trimmed) return
  let cmd
  try { cmd = JSON.parse(trimmed) } catch { return log('error', 'unparseable command line') }
  handleCommand(cmd).catch(e => log('error', `command failed: ${e?.message || e}`))
})
rl.on('close', () => { stopping = true; process.exit(0) })

process.on('SIGTERM', () => { stopping = true; process.exit(0) })
process.on('SIGINT', () => { stopping = true; process.exit(0) })

startSocket().catch(e => {
  log('error', `fatal: ${e?.message || e}`)
  process.exit(1)
})
