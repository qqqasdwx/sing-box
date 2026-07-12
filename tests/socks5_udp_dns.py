#!/usr/bin/env python3
import argparse
import ipaddress
import os
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


def dns_query(name):
    transaction_id = int.from_bytes(os.urandom(2), "big")
    labels = b"".join(bytes([len(label)]) + label.encode() for label in name.split("."))
    header = struct.pack("!HHHHHH", transaction_id, 0x0100, 1, 0, 0, 0)
    return transaction_id, header + labels + b"\x00" + struct.pack("!HH", 28, 1)


def main():
    parser = argparse.ArgumentParser(description="Test SOCKS5 UDP ASSOCIATE with an IPv6 DNS query")
    parser.add_argument("--proxy-host", default="127.0.0.1")
    parser.add_argument("--proxy-port", type=int, default=11080)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--dns-server", default="2606:4700:4700::1111")
    parser.add_argument("--name", default="example.com")
    args = parser.parse_args()

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

    transaction_id, query = dns_query(args.name)
    destination = ipaddress.IPv6Address(args.dns_server).packed
    packet = b"\x00\x00\x00\x04" + destination + struct.pack("!H", 53) + query

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.settimeout(10)
    udp.sendto(packet, (relay_host, relay_port))
    response, _ = udp.recvfrom(65535)
    if len(response) < 22 or response[:3] != b"\x00\x00\x00":
        raise RuntimeError("invalid SOCKS5 UDP response")

    dns_offset = 4
    response_type = response[3]
    if response_type == 1:
        dns_offset += 4
    elif response_type == 4:
        dns_offset += 16
    elif response_type == 3:
        dns_offset += 1 + response[4]
    else:
        raise RuntimeError("invalid SOCKS5 response address type")
    dns_offset += 2

    dns_response = response[dns_offset:]
    if len(dns_response) < 12 or struct.unpack("!H", dns_response[:2])[0] != transaction_id:
        raise RuntimeError("DNS transaction ID mismatch")
    flags, _, answers, _, _ = struct.unpack("!HHHHH", dns_response[2:12])
    if flags & 0x000F:
        raise RuntimeError(f"DNS query failed with rcode {flags & 0x000F}")
    print(f"SOCKS5 UDP IPv6 DNS passed: {args.name}, answers={answers}")


if __name__ == "__main__":
    main()
