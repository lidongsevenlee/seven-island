// Seven Island plugin for OpenCode
// Bridges OpenCode events to the Seven Island notch app via Unix socket
// at ~/.seven-island/agent.sock + JSONL log at ~/.seven-island/hooks-log.jsonl.
// Installed by Seven Island at ~/.config/opencode/plugins/seven-island-opencode.js.

import { connect } from "net";
import { appendFileSync, mkdirSync, existsSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { dirname, join } from "path";

const PLUGIN_VERSION = "1.0.0";
const SOCKET_PATH = process.env.SEVEN_ISLAND_SOCKET || `${process.env.HOME || homedir()}/.seven-island/agent.sock`;
const LOG_PATH    = process.env.SEVEN_ISLAND_LOG    || `${process.env.HOME || homedir()}/.seven-island/hooks-log.jsonl`;
const PLATFORM    = "opencode";

function debugLog(msg) {
  try {
    appendFileSync("/tmp/seven-island-opencode-debug.log", `[${new Date().toISOString()}] ${msg}\n`);
  } catch {}
}

// ── JSONL writer (mirrors seven-island-hook.sh) ────────────────────────────
function writeJSONL(record) {
  try {
    const dir = dirname(LOG_PATH);
    mkdirSync(dir, { recursive: true });
    let lines = [];
    if (existsSync(LOG_PATH)) {
      const existing = readFileSync(LOG_PATH, "utf8").split("\n").filter(Boolean);
      if (existing.length > 3000) lines = existing.slice(-2000);
      else lines = existing;
    }
    lines.push(JSON.stringify(record));
    writeFileSync(LOG_PATH + ".tmp", lines.join("\n") + "\n");
    // Atomic move
    try { require("fs").renameSync(LOG_PATH + ".tmp", LOG_PATH); } catch {
      // Fallback: write directly
      appendFileSync(LOG_PATH, JSON.stringify(record) + "\n");
    }
  } catch (e) { debugLog(`writeJSONL error: ${e.message}`); }
}

function summarize(ev, p) {
  switch (ev) {
    case "SessionStart":      return p.model || "";
    case "UserPromptSubmit":  return (p.prompt || "").slice(0, 80);
    case "Stop":              return (p.last_assistant_message || "").slice(0, 80);
    case "StopFailure":       return p.error || "";
    case "Notification":      return p.message || "";
    case "PermissionRequest": return p.tool_name || "";
    case "SessionEnd":        return "";
    default:                  return "";
  }
}

function emitHook(event_name, payload) {
  const record = {
    ts: Date.now() / 1000,
    event: event_name,
    session_id: payload.session_id || "",
    cwd: payload.cwd || "",
    tool_name: payload.tool_name || null,
    summary: summarize(event_name, payload) || null,
    model: payload.model || null,
    parent_session_id: payload.parent_session_id || null,
    platform: PLATFORM,
  };
  // 1) Persist to JSONL
  writeJSONL(record);
  // 2) Fire-and-forget nudge to socket (if socket exists)
  try {
    if (!existsSync(SOCKET_PATH)) return;
    const message = JSON.stringify({ action: "hook", payload: record }) + "\n";
    const sock = connect({ path: SOCKET_PATH }, () => {
      try { sock.end(message); } catch {}
    });
    sock.on("error", () => {});
    sock.setTimeout(2000, () => { try { sock.destroy(); } catch {} });
  } catch {}
}

// Blocking call for permission requests — wait for allow/deny reply from app.
function askPermission(payload) {
  // Persist immediately so the notch knows a permission request is pending.
  const record = {
    ts: Date.now() / 1000,
    event: "PermissionRequest",
    session_id: payload.session_id || "",
    cwd: payload.cwd || "",
    tool_name: payload.tool_name || null,
    summary: payload.tool_name || null,
    model: null,
    parent_session_id: null,
    platform: PLATFORM,
  };
  writeJSONL(record);
  // Send blocking request to socket.
  return new Promise((resolve) => {
    try {
      if (!existsSync(SOCKET_PATH)) {
        // No socket — allow by default so OpenCode doesn't hang.
        resolve({ behavior: "allow" });
        return;
      }
      const message = JSON.stringify({
        action: "permission",
        payload: {
          session_id: payload.session_id || "",
          cwd: payload.cwd || "",
          tool_name: payload.tool_name || "",
          tool_input: payload.tool_input || {},
          description: payload.description || "",
          platform: PLATFORM,
        },
      }) + "\n";
      const sock = connect({ path: SOCKET_PATH }, () => {
        try { sock.write(message); sock.shutdown?.("write"); } catch {}
      });
      let buf = "";
      sock.on("data", (chunk) => {
        buf += chunk.toString();
        if (buf.includes("\n")) {
          const line = buf.split("\n").filter(Boolean)[0];
          try { sock.destroy(); } catch {}
          if (line.includes("allow")) resolve({ behavior: "allow" });
          else if (line.startsWith("deny:")) resolve({ behavior: "deny", message: line.slice(5) });
          else if (line.includes("deny")) resolve({ behavior: "deny", message: "用户在灵动岛拒绝了权限请求" });
          else resolve({ behavior: "deny", message: "未收到有效授权回复" });
        }
      });
      sock.on("end", () => {
        if (!buf.includes("\n")) resolve({ behavior: "allow" });
      });
      sock.on("error", () => resolve({ behavior: "allow" }));
      sock.setTimeout(295000, () => { try { sock.destroy(); } catch {}; resolve({ behavior: "allow" }); });
    } catch {
      resolve({ behavior: "allow" });
    }
  });
}

// ── Session/CWD tracking ─────────────────────────────────────────────────────
const sessionCwd = new Map();
const sessions   = new Map();
const msgRoles   = new Map();
function getSession(sid) {
  if (!sessions.has(sid)) sessions.set(sid, { lastAssistantText: "" });
  return sessions.get(sid);
}

function makeID(sid) { return sid ? `opencode-${sid}` : ""; }

// ── Main plugin entry ─────────────────────────────────────────────────────────
export default async ({ client, serverUrl }) => {
  const serverPort = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
  const internalFetch = client?._client?.getConfig?.()?.fetch || null;

  function mapEvent(ev) {
    const t = ev.type;
    const p = ev.properties || {};

    // session.created
    if (t === "session.created" && p.info) {
      const cwd = p.info.directory || "";
      sessionCwd.set(p.info.id, cwd);
      return { hook_event_name: "SessionStart", session_id: makeID(p.info.id), cwd,
               model: p.info.model };
    }

    // session.deleted
    if (t === "session.deleted" && p.info) {
      sessions.delete(p.info.id);
      const cwd = sessionCwd.get(p.info.id) || "";
      sessionCwd.delete(p.info.id);
      return { hook_event_name: "SessionEnd", session_id: makeID(p.info.id), cwd };
    }

    // session.updated (archived)
    if (t === "session.updated" && p.info) {
      if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
      if (p.info.time?.archived) {
        sessions.delete(p.info.id);
        const cwd = sessionCwd.get(p.info.id) || "";
        sessionCwd.delete(p.info.id);
        return { hook_event_name: "SessionEnd", session_id: makeID(p.info.id), cwd };
      }
      return null;
    }

    // session.status → idle = Stop
    if (t === "session.status" && p.sessionID) {
      if (p.status?.type === "idle") {
        const s = getSession(p.sessionID);
        const cwd = sessionCwd.get(p.sessionID) || "";
        return { hook_event_name: "Stop", session_id: makeID(p.sessionID), cwd,
                 last_assistant_message: s.lastAssistantText || undefined };
      }
      return null;
    }

    // message.updated — track role
    if (t === "message.updated" && p.info?.id && p.info?.sessionID) {
      msgRoles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID });
      if (msgRoles.size > 200) msgRoles.delete(msgRoles.keys().next().value);
      return null;
    }

    // message.part.updated — text
    if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
      const meta = msgRoles.get(p.part.messageID);
      if (!meta) return null;
      const text = p.part.text || "";
      if (meta.role === "user" && text) {
        const cwd = sessionCwd.get(meta.sessionID) || "";
        return { hook_event_name: "UserPromptSubmit", session_id: makeID(meta.sessionID), cwd,
                 prompt: text };
      }
      if (meta.role === "assistant" && text) {
        getSession(meta.sessionID).lastAssistantText = text;
      }
      return null;
    }

    // message.part.updated — tool
    if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
      const st = p.part.state?.status;
      const cwd = sessionCwd.get(p.part.sessionID) || "";
      const toolName = (p.part.tool || "").charAt(0).toUpperCase() + (p.part.tool || "").slice(1);
      if (st === "running" || st === "pending") {
        return { hook_event_name: "PreToolUse", session_id: makeID(p.part.sessionID), cwd,
                 tool_name: toolName,
                 tool_input: typeof p.part.state?.input === "string"
                   ? p.part.state.input
                   : JSON.stringify(p.part.state?.input || {}).slice(0, 200) };
      }
      if (st === "completed" || st === "error") {
        return { hook_event_name: "PostToolUse", session_id: makeID(p.part.sessionID), cwd,
                 tool_name: toolName };
      }
      return null;
    }

    // permission.asked
    if (t === "permission.asked" && p.id && p.sessionID) {
      const toolName = (p.permission || "").charAt(0).toUpperCase() + (p.permission || "").slice(1);
      const patterns = p.patterns || [];
      const cwd = sessionCwd.get(p.sessionID) || "";
      let toolInput = { patterns, metadata: p.metadata };
      if (p.permission === "bash" && patterns.length > 0) {
        toolInput.command = patterns.join(" && ");
      }
      if ((p.permission === "edit" || p.permission === "write") && patterns.length > 0) {
        toolInput.file_path = patterns[0];
      }
      return { hook_event_name: "PermissionRequest", session_id: makeID(p.sessionID), cwd,
               tool_name: toolName,
               tool_input: toolInput,
               description: patterns.length > 0 ? `${toolName}: ${patterns[0]}` : toolName,
               permission_id: p.id };
    }

    // permission.replied / question.replied / question.rejected
    if (t === "permission.replied" && p.sessionID) {
      return { hook_event_name: "PostToolUse", session_id: makeID(p.sessionID),
               cwd: sessionCwd.get(p.sessionID) || "" };
    }
    if ((t === "question.replied" || t === "question.rejected") && p.sessionID) {
      return { hook_event_name: "PostToolUse", session_id: makeID(p.sessionID),
               cwd: sessionCwd.get(p.sessionID) || "" };
    }

    return null;
  }

  return {
    "event": async ({ event }) => {
      try {
        const mapped = mapEvent(event);
        if (!mapped) return;
        const h = mapped.hook_event_name;
        const payload = {
          session_id: mapped.session_id,
          cwd: mapped.cwd,
          tool_name: mapped.tool_name,
          tool_input: mapped.tool_input,
          description: mapped.description,
          // for summarize():
          prompt: mapped.prompt,
          last_assistant_message: mapped.last_assistant_message,
          model: mapped.model,
        };

        // Permission request — blocking call to app
        if (h === "PermissionRequest" && mapped.permission_id && internalFetch) {
          const decision = await askPermission(payload);
          const reply = decision.behavior === "allow" ? "once" : "reject";
          const message = decision.behavior === "deny" ? decision.message : undefined;
          try {
            await internalFetch(new Request(`http://localhost:${serverPort}/permission/${mapped.permission_id}/reply`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ reply, message }),
            }));
          } catch (e) { debugLog(`permission reply error: ${e.message}`); }
          return;
        }

        // All other events — fire-and-forget
        emitHook(h, payload);
      } catch (e) {
        debugLog(`event handler error: ${e.message}`);
      }
    },
  };
};