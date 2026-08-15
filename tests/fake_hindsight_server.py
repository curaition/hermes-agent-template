#!/usr/bin/env python3
"""Minimal fake of Hindsight's MCP surface for bootstrap tests. Usage: fake_hindsight_server.py PORT"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"banks": {}}
ALL_TOOLS = ["create_bank","get_bank","update_bank","list_directives","create_directive","delete_directive",
             "list_mental_models","create_mental_model","delete_mental_model","retain","recall","reflect",
             "list_memories","get_memory","get_mental_model","list_tags","list_documents","get_document",
             "list_operations","get_operation","sync_retain","clear_memories","delete_bank","delete_document"]

def bank_from_path(path):
    parts = [p for p in path.split("/") if p]
    return parts[1] if len(parts) >= 2 and parts[0] == "mcp" else None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/__state": return self._send(200, STATE)
        self._send(404, {})
    def do_POST(self):
        # Controller ruling R2: any path not under /mcp is a routing 404, checked BEFORE auth,
        # so an auth gate probe against a wrong base URL (e.g. HINDSIGHT_URL=.../nope) sees a
        # non-401 status and the bootstrap script's auth gate correctly aborts.
        if not (self.path == "/mcp" or self.path.startswith("/mcp/")):
            return self._send(404, {"detail": "not found"})
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "): return self._send(401, {"detail": "unauthorized"})
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        bank_id = bank_from_path(self.path)
        bank = STATE["banks"].get(bank_id) if bank_id else None
        allowed = (bank or {}).get("config", {}).get("mcp_enabled_tools") if bank else None
        tools = allowed if allowed else ALL_TOOLS
        rid = req.get("id", 1)
        if req.get("method") == "tools/list":
            return self._send(200, {"jsonrpc":"2.0","id":rid,"result":{"tools":[{"name":t} for t in tools]}})
        if req.get("method") != "tools/call": return self._send(400, {"error":"bad method"})
        name = req["params"]["name"]; args = req["params"].get("arguments", {})
        if name not in tools:
            return self._send(200, {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":f"tool {name} not enabled"}})
        def ok(obj): return self._send(200, {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":json.dumps(obj)}]}})
        if name == "create_bank":
            b = STATE["banks"].setdefault(args["bank_id"], {"bank_id":args["bank_id"],"config":{},"directives":[],"mental_models":[]})
            b["mission"] = args.get("mission", b.get("mission")); return ok({"bank_id": args["bank_id"]})
        if bank is None: return ok({"error": "no such bank"})
        if name == "get_bank": return ok(bank)
        if name == "update_bank": bank["config"].update(args.get("config_updates", {})); return ok(bank["config"])
        if name == "list_directives": return ok({"directives": bank["directives"]})
        if name == "create_directive": bank["directives"].append({"name":args["name"],"content":args["content"],"priority":args.get("priority",0)}); return ok({"ok":True})
        if name == "list_mental_models": return ok({"mental_models": bank["mental_models"]})
        if name == "create_mental_model": bank["mental_models"].append({"mental_model_id":args["mental_model_id"],"tags_match":args.get("tags_match")}); return ok({"ok":True})
        return ok({"ok": True})

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
