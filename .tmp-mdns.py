import socket, struct, sys, time

MCAST = "224.0.0.251"
PORT = 5353

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except Exception:
    pass
s.bind(("", PORT))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
             socket.inet_aton(MCAST) + socket.inet_aton("0.0.0.0"))
s.settimeout(1.0)
print("mDNS 监听", MCAST, PORT, flush=True)

end = time.time() + 40
hits = 0
while time.time() < end:
    try:
        data, addr = s.recvfrom(9000)
    except socket.timeout:
        continue
    if b"qingyi" not in data.lower() and b"QY-" not in data:
        continue
    hits += 1
    print("命中", hits, "来自", addr, "长度", len(data), flush=True)
    if hits <= 4:
        print(repr(data[:400]), flush=True)

print("结束，共命中", hits, flush=True)
