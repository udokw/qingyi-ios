import json, socket, sys, time

MODE = sys.argv[1]
PORT = 41235

if MODE == "query":
    target = sys.argv[2]
    room = sys.argv[3] if len(sys.argv) > 3 else ""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(1.0)
    for i in range(5):
        body = json.dumps({"t": "room_query", "room": room, "v": 1}).encode()
        s.sendto(body, (target, PORT))
        print("query ->", target, PORT, "room=", room, flush=True)
        deadline = time.time() + 1.0
        while time.time() < deadline:
            try:
                data, addr = s.recvfrom(2048)
            except socket.timeout:
                break
            print("reply from", addr, data.decode(errors="replace")[:220], flush=True)
        time.sleep(0.4)
else:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("", PORT))
    s.settimeout(0.5)
    print("响器监听", PORT, flush=True)
    end = time.time() + 45
    while time.time() < end:
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            continue
        try:
            obj = json.loads(data.decode(errors="replace"))
        except Exception:
            continue
        print("收到", addr, obj.get("t"), "room=", obj.get("room"), flush=True)
        if obj.get("t") == "room_query":
            reply = {"t": "room_reply", "room": "7777", "game": "go", "port": 41234,
                     "addr": "192.168.5.1", "iid": "pcevidence", "size": "19",
                     "name": "PC-EVIDENCE", "v": 1}
            s.sendto(json.dumps(reply).encode(), addr)
            print("已回应答", addr, flush=True)
