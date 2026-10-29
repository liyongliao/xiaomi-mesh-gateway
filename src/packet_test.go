package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func fixture(opts []byte) []byte {
	p := make([]byte, 20+8+240)
	p[0] = 0x45
	p[9] = 17
	binary.BigEndian.PutUint16(p[20:22], 68)
	binary.BigEndian.PutUint16(p[22:24], 67)
	b := p[28:]
	b[0] = 1
	b[1] = 1
	b[2] = 6
	copy(b[28:34], []byte{2, 3, 4, 5, 6, 7})
	copy(b[236:240], []byte{99, 130, 83, 99})
	p = append(p, opts...)
	binary.BigEndian.PutUint16(p[2:4], uint16(len(p)))
	binary.BigEndian.PutUint16(p[24:26], uint16(len(p)-20))
	return p
}
func TestTagPacket(t *testing.T) {
	p := fixture([]byte{53, 1, 3, 55, 3, 1, 3, 6, 82, 5, 1, 3, 'b', 'a', 'd', 255})
	q, e := tagPacket(p, "wl0")
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.Contains(q, []byte("meshgw_wl0")) || bytes.Contains(q, []byte("bad")) {
		t.Fatal("invalid circuit ID")
	}
	if !bytes.Contains(q, []byte{55, 3, 1, 3, 6}) {
		t.Fatal("client options lost")
	}
	if int(binary.BigEndian.Uint16(q[2:4])) != len(q) || int(binary.BigEndian.Uint16(q[24:26])) != len(q)-20 {
		t.Fatal("invalid lengths")
	}
	var sum uint32
	for i := 0; i < 20; i += 2 {
		sum += uint32(binary.BigEndian.Uint16(q[i : i+2]))
	}
	for sum>>16 != 0 {
		sum = (sum & 65535) + (sum >> 16)
	}
	if sum != 65535 {
		t.Fatal("bad IP checksum")
	}
	if _, _, ok := packetMAC(q); !ok {
		t.Fatal("rewritten packet invalid")
	}
	if bytes.Equal(p, q) {
		t.Fatal("no modification")
	}
}
func TestRejectMalformed(t *testing.T) {
	for _, opts := range [][]byte{{53, 1, 3}, {53, 6, 3, 255}, {55}} {
		if _, e := tagPacket(fixture(opts), "wl0"); e == nil {
			t.Fatal("accepted malformed options")
		}
	}
	p := fixture([]byte{255})
	p[6] = 0x20
	if _, _, ok := packetMAC(p); ok {
		t.Fatal("accepted fragments")
	}
	if _, e := tagPacket(fixture([]byte{255}), "eth1"); e == nil {
		t.Fatal("unmanaged port")
	}
}

func TestVerifiedMeshMapping(t *testing.T) {
	c := Config{MeshNodes: map[string]map[string]string{"02:00:00:00:00:01": {"wl0": "wl0", "wl1": "wl1"}}}
	for _, tc := range []struct{ raw, want string }{
		{`{"parent":"02:00:00:00:00:01","ifname":"wl0","assoc":1}`, "wl0"},
		{`{"parent":"02:00:00:00:00:01","ifname":"wl1","assoc":1}`, "wl1"},
		{`{"parent":"unknown","ifname":"wl0","assoc":1}`, ""},
		{`{"parent":"02:00:00:00:00:01","ifname":"wl0","assoc":0}`, ""},
		{`{"parent":"02:00:00:00:00:01","ifname":"eth1","assoc":1}`, ""},
		{`not json`, ""},
	} {
		got, _ := meshInterface([]byte(tc.raw), c)
		if got != tc.want {
			t.Fatalf("%s: got %q, want %q", tc.raw, got, tc.want)
		}
	}
}
