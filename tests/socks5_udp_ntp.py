#!/usr/bin/env python3
import argparse
import ipaddress
import socket
import struct


def recv_exact(sock, length):
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("SOCKS5 control connection closed")
        data += chunk
    return data


def udp_relay(args):
    control = socket.create_connection((args.proxy_host, args.proxy_port), timeout=10)
    control.sendall(b"\x05\x01\x02")
    if recv_exact(control, 2) != b"\x05\x02":
        raise RuntimeError("SOCKS5 username authentication was not selected")

    username = args.username.encode()
    password = args.password.encode()
    control.sendall(b"\x01" + bytes([len(username)]) + username + bytes([len(password)]) + password)
    if recv_exact(control, 2) != b"\x01\x00":
        raise RuntimeError("SOCKS5 authentication failed")

    control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
    version, reply, _, address_type = recv_exact(control, 4)
    if version != 5 or reply != 0:
        raise RuntimeError(f"SOCKS5 UDP ASSOCIATE failed with reply {reply}")

    if address_type == 1:
        relay_host = socket.inet_ntop(socket.AF_INET, recv_exact(control, 4))
    elif address_type == 4:
        relay_host = socket.inet_ntop(socket.AF_INET6, recv_exact(control, 16))
    else:
        size = recv_exact(control, 1)[0]
        relay_host = recv_exact(control, size).decode()
    relay_port = struct.unpack("!H", recv_exact(control, 2))[0]
    if relay_host in ("0.0.0.0", "::"):
        relay_host = args.proxy_host
    return control, relay_host, relay_port


def response_payload(packet):
    if len(packet) < 10 or packet[:3] != b"\x00\x00\x00":
        raise RuntimeError("invalid SOCKS5 UDP response")
    address_type = packet[3]
    offset = 4
    if address_type == 1:
        offset += 4
    elif address_type == 4:
        offset += 16
    elif address_type == 3:
        offset += 1 + packet[offset]
    else:
        raise RuntimeError("invalid SOCKS5 response address type")
    return packet[offset + 2 :]


def main():
    parser = argparse.ArgumentParser(description="Test SOCKS5 UDP ASSOCIATE with an IPv6 NTP request")
    parser.add_argument("--proxy-host", default="127.0.0.1")
    parser.add_argument("--proxy-port", type=int, default=11080)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--ntp-server", default="2606:4700:f1::123")
    args = parser.parse_args()

    control, relay_host, relay_port = udp_relay(args)
    destination = ipaddress.IPv6Address(args.ntp_server).packed
    request = b"\x1b" + (b"\x00" * 47)
    packet = b"\x00\x00\x00\x04" + destination + struct.pack("!H", 123) + request

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.settimeout(10)
    udp.sendto(packet, (relay_host, relay_port))
    payload = response_payload(udp.recvfrom(65535)[0])
    control.close()

    if len(payload) < 48 or (payload[0] & 0x07) != 4:
        raise RuntimeError("invalid NTP server response")
    print(f"SOCKS5 UDP IPv6 NTP passed: server={args.ntp_server}")


if __name__ == "__main__":
    main()
