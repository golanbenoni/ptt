import { DurableObject } from "cloudflare:workers";

type CallEventSocket = { aci: string; deviceId: number };

/** Hibernation-safe, per-account call signaling fan-out. Authentication happens
 * in the Worker before a socket is handed to this object. Event bodies contain
 * random call identifiers and state only; names are resolved on each device. */
export class CallEventCoordinator extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", { status: 426 });
    }
    const aci = request.headers.get("X-PTT-Aci") ?? "";
    const deviceId = Number(request.headers.get("X-PTT-Device") ?? "0");
    if (!aci || !Number.isSafeInteger(deviceId) || deviceId < 1 || deviceId > 2) {
      return new Response("Invalid call event principal", { status: 403 });
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.serializeAttachment({ aci, deviceId } satisfies CallEventSocket);
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async publish(event: string): Promise<void> {
    if (event.length > 4_096) throw new Error("Call event exceeds safe limit");
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send(event);
      } catch {
        socket.close(1011, "SIGNAL_DELIVERY_FAILED");
      }
    }
  }

  override async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (message === "ping") return;
    socket.close(1008, "CLIENT_MESSAGES_NOT_ACCEPTED");
  }
}
