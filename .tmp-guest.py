import json, socket, struct, sys, threading, time

HOST = "192.168.5.72"
PORT = int(sys.argv[1])
ROOM = sys.argv[2]

s = socket.create_connection((HOST, PORT), timeout=5)
s.settimeout(None)
print("connected", HOST, PORT, flush=True)


def send(t, payload):
    body = json.dumps({
        "v": 1, "t": t, "sid": "pcevidence01", "ts": int(time.time() * 1000),
        "seq": 0, "room": ROOM, "from": "guest", "p": payload
    }).encode()
    s.sendall(struct.pack(">I", len(body)) + body)
    print(">>", t, flush=True)


def recv_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


send("hello", {"protocolVersion": 1, "roomCode": ROOM,
               "deviceName": "PC-Evidence", "game": "go"})

while True:
    head = recv_exact(4)
    if head is None:
        print("closed", flush=True)
        break
    n = struct.unpack(">I", head)[0]
    obj = json.loads(recv_exact(n).decode())
    print("<<", obj.get("t"), json.dumps(obj.get("p", {}), ensure_ascii=False)[:160], flush=True)
    if obj.get("t") == "hello_ack":
        send("ready", {})
    elif obj.get("t") == "ping":
        send("pong", {})
